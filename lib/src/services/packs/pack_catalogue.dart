import 'dart:convert';

import 'package:flutter/services.dart';

/// What an uninstalled pack contains.
///
/// Bundled with the app rather than fetched, because the app has to be able to
/// describe what it is missing while offline — which, for an offline-first
/// library, is the normal case.
class PackContents {
  final String name;
  final List<String> authors;
  final List<String> titles;
  final Map<String, int> tags;

  /// Which traditions have any text at all in here. Kept separately from
  /// [tags] because absence and scarcity are different questions: tags answer
  /// "how much of this subject am I missing", and only this answers "is this
  /// tradition represented on the device at all".
  final List<String> traditions;

  /// Which fragments back this collection. Coverage arithmetic runs over these
  /// rather than over collections, because collections overlap.
  final List<String> fragments;

  const PackContents({
    required this.name,
    required this.authors,
    required this.titles,
    required this.tags,
    this.traditions = const [],
    this.fragments = const [],
  });

  factory PackContents.fromJson(Map<String, dynamic> json) => PackContents(
        name: json['name'] as String? ?? '',
        authors: (json['authors'] as List? ?? []).cast<String>(),
        titles: (json['titles'] as List? ?? []).cast<String>(),
        tags: (json['tags'] as Map? ?? {}).map(
          (key, value) => MapEntry(key as String, value as int),
        ),
        traditions: (json['traditions'] as List? ?? []).cast<String>(),
        fragments: (json['fragments'] as List? ?? []).cast<String>(),
      );
}

/// Why a pack is being suggested for a particular question.
enum SuggestionReason {
  /// The question names someone whose writing lives in this pack.
  namesAuthor,

  /// The question names a work in this pack.
  namesWork,

  /// The question names a tradition with nothing installed from it.
  ///
  /// Ranked above [coversSubject] because it is a stronger claim. Subject
  /// coverage says an answer would be better; this says an answer would be
  /// given *without the tradition that was asked about* — which, for an app
  /// whose purpose is showing what each tradition taught, is not a shortfall
  /// but a wrong answer.
  traditionAbsent,

  /// Nobody is named, but the pack covers this subject heavily.
  coversSubject,
}

class PackSuggestion {
  final String packId;
  final SuggestionReason reason;

  /// The author, work or subject that triggered it, for an explanation the
  /// reader can evaluate rather than take on trust.
  final String detail;

  const PackSuggestion({
    required this.packId,
    required this.reason,
    required this.detail,
  });

  String get explanation => switch (reason) {
        SuggestionReason.namesAuthor =>
          'You asked about $detail, whose writings are not installed.',
        SuggestionReason.namesWork =>
          '$detail is not installed.',
        SuggestionReason.traditionAbsent =>
          'You asked about the $detail tradition, and none of it is '
              'installed.',
        SuggestionReason.coversSubject =>
          'This collection covers $detail extensively and is not installed.',
      };
}

/// Notices when a question would be better answered by content the user does
/// not have.
///
/// The app can only search text it holds, so a library without the fathers
/// answers a question about the Eucharist confidently from confessions alone —
/// well-cited, fluent, and quietly missing most of what was ever written on the
/// subject. For an app whose purpose is showing what each tradition actually
/// taught, silently omitting a tradition is the worst failure available, and
/// splitting the corpus is what made it reachable.
class PackCatalogue {
  static const String _asset = 'assets/pack_catalogue.json';

  final Map<String, PackContents> packs;

  /// Tag counts for the bundled corpus, so "how much am I missing" can be
  /// answered as a proportion of everything rather than in the abstract.
  final Map<String, int> core;

  /// What each fragment holds. The unit that actually contains text exactly
  /// once, and therefore the only level at which "do I have this?" can be
  /// answered — collections overlap, so counting over them double-counts, and
  /// asking whether a *collection* is complete answers a different question
  /// entirely from whether an author's text is present.
  final Map<String, PackContents> fragments;

  const PackCatalogue(this.packs, this.core, {this.fragments = const {}});

  static Future<PackCatalogue> load() async {
    final body = await rootBundle.loadString(_asset);
    return PackCatalogue.parse(body);
  }

  factory PackCatalogue.parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final packs = (json['packs'] as Map<String, dynamic>).map(
      (id, value) => MapEntry(
        id,
        PackContents.fromJson(value as Map<String, dynamic>),
      ),
    );
    final core = (json['core'] as Map? ?? {}).map(
      (key, value) => MapEntry(key as String, value as int),
    );
    final fragments = (json['fragments'] as Map? ?? {}).map(
      (key, value) => MapEntry(
        key as String,
        PackContents.fromJson((value as Map).cast<String, dynamic>()),
      ),
    );
    return PackCatalogue(packs, core, fragments: fragments);
  }

  /// A name is only taken as naming a person or work when it appears as whole
  /// words. Substring matching turns "Origen" into a match for "original sin",
  /// which is exactly the sort of thing that trains people to ignore notices.
  static bool _mentions(String haystack, String needle) {
    if (needle.length < 4) return false;
    final pattern = RegExp(
      r'\b' + RegExp.escape(needle.toLowerCase()) + r'\b',
      caseSensitive: false,
    );
    return pattern.hasMatch(haystack);
  }

  /// How a tradition gets named in a question, as against how it is labelled
  /// in the database.
  ///
  /// Nobody types "Reformed" when they mean Presbyterians, or the database's
  /// "Anglican" when they are American and say Episcopalian. Matching the
  /// stored label alone would make this fire almost never, which is the same
  /// as not building it.
  ///
  /// Deliberately conservative: only words that name a tradition and little
  /// else. "Orthodox" is absent because it is far more often an adjective —
  /// "orthodox Christology" is not a question about the Eastern church — and
  /// a notice that misreads the question is worse than no notice.
  static const Map<String, List<String>> _traditionNames = {
    'Baptist': ['baptist', 'baptists'],
    'Lutheran': ['lutheran', 'lutherans'],
    'Reformed': ['reformed', 'presbyterian', 'presbyterians', 'calvinist',
                 'calvinists', 'calvinism'],
    'Anglican': ['anglican', 'anglicans', 'episcopalian', 'episcopalians'],
    'Methodist': ['methodist', 'methodists', 'wesleyan', 'wesleyans'],
    'Catholic': ['catholic', 'catholics', 'catholicism'],
    'Eastern Orthodox': ['eastern orthodox', 'orthodoxy'],
  };

  /// Which traditions [question] names.
  static Set<String> _traditionsNamedIn(String question) {
    final named = <String>{};
    for (final entry in _traditionNames.entries) {
      if (entry.value.any((alias) => _mentions(question, alias))) {
        named.add(entry.key);
      }
    }
    return named;
  }

  /// Words that carry no identifying weight in a title, and which nobody is
  /// consistent about when naming one.
  static const _filler = {
    'the', 'of', 'a', 'an', 'and', 'on', 'in', 'to', 'for', 'upon',
  };

  static List<String> _significant(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_filler.contains(w))
      .toList();

  /// Whether [question] names [title], allowing for the fact that nobody says
  /// a document's full name.
  ///
  /// Requiring the whole title verbatim looked strict-but-safe and was simply
  /// broken: "the Second London Baptist Confession" does not contain "of
  /// Faith", so the confession was never matched, and the same holds for every
  /// anonymous confession in the corpus — which is most of them. Those are
  /// precisely the works with no author to match on instead, so nothing
  /// caught them.
  ///
  /// Three consecutive significant words is the bar. It is specific enough
  /// that no ordinary question stumbles into it — "the doctrine of original
  /// sin" shares no such run with any title here — and loose enough to catch
  /// the short forms people actually use.
  static bool _namesWork(String question, String title) {
    final wanted = _significant(title);
    if (wanted.length < 3) return false;
    final asked = _significant(question);
    if (asked.length < 3) return false;

    for (var start = 0; start + 3 <= wanted.length; start++) {
      final run = wanted.sublist(start, start + 3);
      for (var at = 0; at + 3 <= asked.length; at++) {
        if (asked[at] == run[0] &&
            asked[at + 1] == run[1] &&
            asked[at + 2] == run[2]) {
          return true;
        }
      }
    }
    return false;
  }

  /// How much of everything written on a subject must be missing before the
  /// reader is told about it.
  ///
  /// The measure that matters is *what fraction of the corpus's material on
  /// this subject is not installed* — not what fraction of a pack is about it.
  /// Those come apart badly: the Eucharist is 0.2% of Augustine, which sounds
  /// negligible, while the packs together hold most of the corpus's writing on
  /// the Eucharist, which is precisely what a reader needs to know before
  /// trusting an answer.
  ///
  /// **Recalibrated 2026-08-30, from 0.5, because the denominator changed and
  /// not the meaning.** The old value was set when only the patristic units
  /// carried topic tags: `tag_units.py` had never been run over the Reformation
  /// ingest, so 60,000 units of Calvin, Owen, Spurgeon and Matthew Henry were
  /// invisible to this arithmetic. The corpus said it held 5,042 units on grace
  /// when it held 28,505. Half of an undercount is not half of the corpus, and
  /// "you have most of it" was quiet because the rest was not being counted.
  ///
  /// With every unit tagged, a reader who has installed one collection — even
  /// the largest — is missing more than half of most subjects, because the
  /// library is large and any one collection is a minority of it. At 0.5 the
  /// notice fired on all ten test subjects after a 108 MB install, which is the
  /// notice-nobody-reads failure this constant exists to prevent.
  ///
  /// At four fifths, the reader holds under a fifth of what has been written on
  /// the subject they just asked about, and the answer they received was drawn
  /// from that fifth.
  static const double _missingShare = 0.8;

  /// Which uninstalled packs would likely have helped with [question].
  ///
  /// [queryTags] comes from the same tag extraction the retriever uses, so a
  /// suggestion is grounded in the question the retrieval actually ran.
  /// [installedFragments] is what is physically present. A collection counts
  /// as available when every fragment it needs is here, which is why this takes
  /// fragments rather than a list of collections the reader tapped: installing
  /// "Church Fathers" makes "Augustine of Hippo" available too, and suggesting
  /// it afterwards would be nonsense.
  List<PackSuggestion> suggest({
    required String question,
    required List<String> queryTags,
    required Set<String> installedFragments,
  }) {
    final suggestions = <PackSuggestion>[];

    bool available(PackContents c) =>
        c.fragments.isNotEmpty &&
        c.fragments.every(installedFragments.contains);

    final missingFragments =
        fragments.keys.where((f) => !installedFragments.contains(f)).toSet();

    // Whose writing is already on the device. Without this, a question about
    // Augustine kept prompting to install him *after he had been installed*,
    // because the Catholic collection also lists him and that collection was
    // still incomplete. Being told to add what you already have is the fastest
    // way to teach someone to ignore a notice.
    final haveAuthors = <String>{};
    final haveTitles = <String>{};
    final haveTraditions = <String>{};
    for (final id in installedFragments) {
      final contents = fragments[id];
      if (contents == null) continue;
      haveAuthors.addAll(contents.authors);
      haveTitles.addAll(contents.titles);
      haveTraditions.addAll(contents.traditions);
    }

    // Which traditions the reader asked about and has nothing from. Computed
    // once, because it depends on the question and the device, not on the pack
    // being considered.
    final absentTraditions = _traditionsNamedIn(question)
        .where((t) => !haveTraditions.contains(t))
        .toSet();

    for (final entry in packs.entries) {
      if (available(entry.value)) continue;
      final contents = entry.value;

      final author = contents.authors
          .where((a) => !haveAuthors.contains(a))
          .where((a) => _namePartsOf(a).any((part) => _mentions(question, part)))
          .firstOrNull;
      if (author != null) {
        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.namesAuthor,
          detail: author,
        ));
        continue;
      }

      final title = contents.titles
          .where((t) => !haveTitles.contains(t))
          .where((t) => _namesWork(question, t))
          .firstOrNull;
      if (title != null) {
        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.namesWork,
          detail: title,
        ));
        continue;
      }

      // A tradition the reader asked about and holds nothing from. Checked
      // before subject coverage, and without any threshold: there is no
      // "enough" here, because the tradition is simply not on the device.
      final tradition = contents.traditions
          .where(absentTraditions.contains)
          .firstOrNull;
      if (tradition != null) {
        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.traditionAbsent,
          detail: tradition,
        ));
        continue;
      }

      // Falling back to subject coverage. Deliberately last and deliberately
      // strict: a notice on every question is a notice nobody reads.
      //
      // Only the pack holding the most of a subject is named, even when
      // several are missing — three notices for one question is nagging, and
      // the largest is the one worth installing first.
      for (final tag in queryTags) {
        final everywhere = _totalFor(tag);
        if (everywhere == 0) continue;

        // Summed over fragments, each of which holds its text once.
        final absent = missingFragments.fold(
          0,
          (sum, id) => sum + (fragments[id]?.tags[tag] ?? 0),
        );
        if (absent / everywhere < _missingShare) continue;

        // Named on the collection that would close most of the gap, so the
        // suggestion is worth acting on rather than technically correct.
        final best = packs.entries
            .where((e) => !available(e.value))
            .reduce((a, b) =>
                (a.value.tags[tag] ?? 0) >= (b.value.tags[tag] ?? 0) ? a : b);
        if (best.key != entry.key) continue;

        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.coversSubject,
          detail: tag.replaceAll('-', ' '),
        ));
        break;
      }
    }

    // Collections overlap by design, so one question routinely matches
    // several: asking about Chrysostom matches "John Chrysostom", "Nicene &
    // Post-Nicene Writers" and "Church Fathers", all of which would answer it.
    // Offering three is worse than offering one.
    //
    // The narrowest wins — measured by how many works it holds — because it is
    // the cheapest way to get an answer, and anyone wanting more can take a
    // broader collection afterwards. Suggesting the largest would be asking
    // someone to download the complete fathers to read one letter.
    // ...except when the reason is that a whole tradition is missing, where
    // narrowest is the wrong answer and so is broadest.
    //
    // Once per-author collections existed, "What do Baptists believe about
    // baptism?" started offering *John Bunyan* — two works, and Baptist, so
    // both the filter and the narrowness rule were satisfied. But the gap
    // being reported is not "you lack a Baptist author", it is "you lack the
    // Baptist tradition", and Bunyan's allegories are not the Baptist
    // confessions. Inverting to breadth alone overshoots the other way, to
    // "Creeds & Confessions" — which does hold Baptist material, among six
    // other traditions, and is not what was asked about either.
    //
    // What actually distinguishes the right answer is that the collection is
    // *about* that tradition and nothing else. So: collections covering one
    // tradition first, and the fullest of those, which is the one that
    // genuinely supplies what is missing.
    suggestions.sort((a, b) {
      final byReason = a.reason.index.compareTo(b.reason.index);
      if (byReason != 0) return byReason;
      if (a.reason == SuggestionReason.traditionAbsent) {
        final byFocus =
            _traditionsIn(a.packId).compareTo(_traditionsIn(b.packId));
        if (byFocus != 0) return byFocus;
        return _worksIn(b.packId).compareTo(_worksIn(a.packId));
      }
      return _worksIn(a.packId).compareTo(_worksIn(b.packId));
    });

    final seen = <String>{};
    return suggestions
        .where((s) => seen.add('${s.reason}|${s.detail}'))
        .toList();
  }

  int _worksIn(String packId) => packs[packId]?.titles.length ?? 0;

  /// How many traditions a collection spans. One means it is *about* a
  /// tradition rather than merely containing some of it.
  int _traditionsIn(String packId) =>
      packs[packId]?.traditions.length ?? 1 << 20;

  /// How many tagged passages exist for [tag] across the whole library,
  /// installed or not.
  int _totalFor(String tag) =>
      (core[tag] ?? 0) +
      fragments.values.fold(0, (sum, f) => sum + (f.tags[tag] ?? 0));

  /// "Augustine of Hippo" should be found by "Augustine", and "John
  /// Chrysostom" by "Chrysostom" — but not by "John", which would match any
  /// question mentioning the gospel.
  static List<String> _namePartsOf(String author) {
    const tooCommon = {'john', 'gregory', 'clement', 'the', 'of', 'saint'};
    final parts = author
        .split(RegExp(r'[\s/]+'))
        .where((p) => p.length > 3 && !tooCommon.contains(p.toLowerCase()))
        .toList();
    return [author, ...parts];
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
