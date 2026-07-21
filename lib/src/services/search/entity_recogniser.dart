import 'package:sqflite/sqflite.dart';

/// What a question named, resolved to rows in the database.
class RecognisedEntities {
  final Set<int> sourceIds;
  final Set<int> traditionIds;

  /// Human-readable names of what matched, for showing the user what the app
  /// understood — a scoped search that silently narrows is worse than one that
  /// says "searching within Aquinas".
  final List<String> labels;

  const RecognisedEntities({
    this.sourceIds = const {},
    this.traditionIds = const {},
    this.labels = const [],
  });

  bool get isEmpty => sourceIds.isEmpty && traditionIds.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// Recognises authors, works and traditions named in a question.
///
/// Retrieval scores passages on text similarity alone, so a question like
/// "what did Aquinas say about Mary?" treats "Aquinas" as one more word to
/// match rather than as a constraint. The result is passages about Mary from
/// whoever wrote most about her — and, in one observed case, a hit on "the
/// most blessed Thomas", meaning the apostle.
///
/// Matching is on metadata rather than body text, which also disambiguates the
/// opposite failure: "Catholic" in a question means the modern communion,
/// while "Catholic" in Augustine means the universal church against the
/// Donatists. Matching the tradition row cannot confuse the two.
class EntityRecogniser {
  /// Words too common to identify anything on their own.
  static const _stopwords = {
    'the', 'of', 'and', 'on', 'in', 'to', 'a', 'an', 'for', 'from', 'by',
    'with', 'against', 'concerning', 'book', 'books', 'part', 'volume', 'vol',
    'saint', 'st', 'selections', 'fragments', 'epistle', 'epistles', 'letter',
    'letters', 'homily', 'homilies', 'treatise', 'works', 'church', 'holy',
    'christian', 'god', 'first', 'second', 'third', 'new', 'old',
  };

  /// How much of a work's title a question must use before it counts as
  /// naming that work.
  ///
  /// A single rare token is deliberately *not* enough. Tokens like "virgin",
  /// "topics" and "saved" appear in only one or two titles while being
  /// ordinary vocabulary, so treating rarity as identity scoped "how is a
  /// person saved?" to *Who is the Rich Man That Shall Be Saved?* and a
  /// question about the Virgin Mary to *Apocalypse of the Virgin*. Requiring
  /// two matching tokens costs the ability to resolve a bare surname and buys
  /// freedom from that whole class of false positive.
  static const _minTokensNamingWork = 2;
  static const _minTitleFraction = 0.6;

  /// A question naming more works than this is naming a topic, not a work.
  static const _maxNamedWorks = 6;

  final Map<String, Set<int>> _sourceTokens;
  final Map<int, String> _sourceNames;
  final Map<int, int> _sourceTokenCounts;
  final Map<String, int> _traditionTokens;
  final Map<int, String> _traditionNames;

  /// Distinctive token -> author name. Authors are a separate axis from works
  /// because they scope differently: Augustine names 45 works, which is a
  /// meaningful constraint even though no single work is meant.
  final Map<String, String> _authorTokens;
  final Map<String, Set<int>> _authorSources;

  EntityRecogniser._(
    this._sourceTokens,
    this._sourceNames,
    this._sourceTokenCounts,
    this._traditionTokens,
    this._traditionNames,
    this._authorTokens,
    this._authorSources,
  );

  static List<String> _tokenise(String text) => text
      .toLowerCase()
      .split(RegExp(r"[^a-z0-9']+"))
      .where((t) => t.length > 2 && !_stopwords.contains(t))
      .toList();

  static Future<EntityRecogniser> load(Database db) async {
    return build(
      sources: await db.query('sources', columns: ['id', 'title', 'author']),
      traditions: await db.query('traditions', columns: ['id', 'name']),
    );
  }

  /// Build from plain rows, so the matching rules can be tested against
  /// fixtures without a database.
  static EntityRecogniser build({
    required List<Map<String, Object?>> sources,
    required List<Map<String, Object?>> traditions,
  }) {

    final sourceTokens = <String, Set<int>>{};
    final sourceNames = <int, String>{};
    final sourceTokenCounts = <int, int>{};

    for (final row in sources) {
      final id = row['id'] as int;
      final title = row['title'] as String? ?? '';
      final author = row['author'] as String? ?? '';

      sourceNames[id] = title;
      final tokens = {..._tokenise(title), ..._tokenise(author)};
      sourceTokenCounts[id] = tokens.length;
      for (final token in tokens) {
        sourceTokens.putIfAbsent(token, () => <int>{}).add(id);
      }
    }

    // Author index, keyed on tokens distinctive among authors rather than
    // among works: "john" names three authors and identifies none of them,
    // while "chrysostom" names exactly one.
    final authorSources = <String, Set<int>>{};
    for (final row in sources) {
      final author = (row['author'] as String? ?? '').trim();
      if (author.isEmpty || author == 'Miscellaneous' || author == 'Apocrypha') {
        continue;
      }
      authorSources
          .putIfAbsent(author, () => <int>{})
          .add(row['id'] as int);
    }

    final tokenAuthors = <String, Set<String>>{};
    for (final author in authorSources.keys) {
      for (final token in _tokenise(author)) {
        tokenAuthors.putIfAbsent(token, () => <String>{}).add(author);
      }
    }
    final authorTokens = <String, String>{
      for (final entry in tokenAuthors.entries)
        if (entry.value.length == 1) entry.key: entry.value.first,
    };

    final traditionTokens = <String, int>{};
    final traditionNames = <int, String>{};

    for (final row in traditions) {
      final id = row['id'] as int;
      final name = row['name'] as String;
      traditionNames[id] = name;
      for (final token in _tokenise(name)) {
        traditionTokens[token] = id;
      }
      // Traditions are named in questions adjectivally far more often than by
      // their row name: "what do Lutherans believe", not "Lutheran tradition".
      for (final form in _adjectivalForms(name)) {
        traditionTokens[form] = id;
      }
    }

    return EntityRecogniser._(
      sourceTokens,
      sourceNames,
      sourceTokenCounts,
      traditionTokens,
      traditionNames,
      authorTokens,
      authorSources,
    );
  }

  static Iterable<String> _adjectivalForms(String name) sync* {
    final base = name.toLowerCase().split(' ').last;
    yield base;
    yield '${base}s';
    if (base.endsWith('an')) yield '${base}s';
    if (base == 'orthodoxy') yield 'orthodox';
    if (base == 'reformed') yield 'calvinist';
    if (base == 'catholic') yield 'roman';
  }

  /// Resolve whatever [query] names. Returns empty when it names nothing,
  /// which is the common case and must stay cheap.
  RecognisedEntities recognise(String query) {
    final tokens = _tokenise(query).toSet();
    if (tokens.isEmpty) return const RecognisedEntities();

    final traditionIds = <int>{};
    final labels = <String>[];

    for (final token in tokens) {
      final id = _traditionTokens[token];
      if (id != null && traditionIds.add(id)) {
        labels.add(_traditionNames[id]!);
      }
    }

    // Authors first: naming one scopes to everything they wrote.
    final sourceIds = <int>{};
    for (final token in tokens) {
      final author = _authorTokens[token];
      if (author != null && !labels.contains(author)) {
        sourceIds.addAll(_authorSources[author]!);
        labels.add(author);
      }
    }
    final namedAuthor = sourceIds.isNotEmpty;

    // Then individual works. Score each candidate by how much of its identity
    // the question used, so "On the Trinity" does not match every work with
    // "trinity" in the title — except where a token is rare enough to identify
    // its work by itself.
    final hits = <int, int>{};
    for (final token in tokens) {
      final candidates = _sourceTokens[token];
      if (candidates == null) continue;
      for (final id in candidates) {
        hits[id] = (hits[id] ?? 0) + 1;
      }
    }

    final namedWorks = <int>{};
    for (final entry in hits.entries) {
      final total = _sourceTokenCounts[entry.key] ?? 0;
      if (total == 0 || entry.value < _minTokensNamingWork) continue;
      if (entry.value >= total || entry.value >= total * _minTitleFraction) {
        namedWorks.add(entry.key);
      }
    }

    // Naming many works at once is naming a topic. An author scope is exempt:
    // it legitimately covers dozens of works.
    if (namedWorks.length > _maxNamedWorks) {
      return RecognisedEntities(
        sourceIds: namedAuthor ? sourceIds : const {},
        traditionIds: traditionIds,
        labels: labels,
      );
    }

    for (final id in namedWorks) {
      sourceIds.add(id);
      labels.add(_sourceNames[id]!);
    }

    return RecognisedEntities(
      sourceIds: sourceIds,
      traditionIds: traditionIds,
      labels: labels,
    );
  }
}
