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

  const PackContents({
    required this.name,
    required this.authors,
    required this.titles,
    required this.tags,
  });

  factory PackContents.fromJson(Map<String, dynamic> json) => PackContents(
        name: json['name'] as String? ?? '',
        authors: (json['authors'] as List? ?? []).cast<String>(),
        titles: (json['titles'] as List? ?? []).cast<String>(),
        tags: (json['tags'] as Map? ?? {}).map(
          (key, value) => MapEntry(key as String, value as int),
        ),
      );
}

/// Why a pack is being suggested for a particular question.
enum SuggestionReason {
  /// The question names someone whose writing lives in this pack.
  namesAuthor,

  /// The question names a work in this pack.
  namesWork,

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

  const PackCatalogue(this.packs, this.core);

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
    return PackCatalogue(packs, core);
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
  /// At half, the answer they just received was drawn from a minority of the
  /// available sources.
  static const double _missingShare = 0.5;

  /// Which uninstalled packs would likely have helped with [question].
  ///
  /// [queryTags] comes from the same tag extraction the retriever uses, so a
  /// suggestion is grounded in the question the retrieval actually ran.
  List<PackSuggestion> suggest({
    required String question,
    required List<String> queryTags,
    required Set<String> installed,
  }) {
    final suggestions = <PackSuggestion>[];
    final missing = packs.keys.where((id) => !installed.contains(id)).toSet();

    for (final entry in packs.entries) {
      if (installed.contains(entry.key)) continue;
      final contents = entry.value;

      final author = contents.authors
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
          .where((t) => t.length > 12 && _mentions(question, t))
          .firstOrNull;
      if (title != null) {
        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.namesWork,
          detail: title,
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

        final absent = missing.fold(
          0,
          (sum, id) => sum + (packs[id]!.tags[tag] ?? 0),
        );
        if (absent / everywhere < _missingShare) continue;

        final biggest = missing.reduce((a, b) =>
            (packs[a]!.tags[tag] ?? 0) >= (packs[b]!.tags[tag] ?? 0) ? a : b);
        if (biggest != entry.key) continue;

        suggestions.add(PackSuggestion(
          packId: entry.key,
          reason: SuggestionReason.coversSubject,
          detail: tag.replaceAll('-', ' '),
        ));
        break;
      }
    }

    // A question naming someone should not be buried under generic coverage.
    suggestions.sort((a, b) => a.reason.index.compareTo(b.reason.index));
    return suggestions;
  }

  /// How many tagged passages exist for [tag] across the whole library,
  /// installed or not.
  int _totalFor(String tag) =>
      (core[tag] ?? 0) +
      packs.values.fold(0, (sum, p) => sum + (p.tags[tag] ?? 0));

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
