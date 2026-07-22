import 'dart:io';

import 'package:council/src/services/packs/pack_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

/// Noticing that a question needs content the user has not installed.
///
/// Run against the *real* generated catalogue rather than a fixture. The
/// judgements here — is "Origen" mentioned, does this pack cover the Eucharist
/// heavily — depend entirely on the actual names and tag distributions in the
/// corpus, so a hand-written fixture would test the thresholds against data
/// chosen to satisfy them.
void main() {
  final catalogue = PackCatalogue.parse(
    File('assets/pack_catalogue.json').readAsStringSync(),
  );

  const nothingInstalled = <String>{};

  /// Every fragment, for the "nothing is missing" cases.
  final everything = catalogue.fragments.keys.toSet();

  /// The fragments a named collection needs — the test speaks in collections
  /// because that is what a reader installs, while the code counts fragments.
  Set<String> fragmentsOf(Iterable<String> collections) => {
        for (final id in collections) ...catalogue.packs[id]!.fragments,
      };

  List<PackSuggestion> suggest(
    String question, {
    List<String> tags = const [],
    Set<String> installed = nothingInstalled,
  }) =>
      catalogue.suggest(
        question: question,
        queryTags: tags,
        installedFragments: installed,
      );

  test('the catalogue describes the published packs', () {
    expect(catalogue.packs.keys,
        containsAll(['creeds-and-confessions', 'church-fathers',
                     'author-augustine', 'tradition-lutheran']));
    expect(catalogue.packs['church-fathers']!.authors.length, greaterThan(50));
  });

  group('naming an author', () {
    test('a question about Augustine points at the Augustine pack', () {
      final suggestions = suggest('What did Augustine say about grace?');

      expect(suggestions, isNotEmpty);
      // The narrowest match, not the largest: "Church Fathers" would also
      // answer it, at ten times the download.
      expect(suggestions.first.packId, 'author-augustine');
      expect(suggestions.first.reason, SuggestionReason.namesAuthor);
      expect(suggestions.first.explanation, contains('Augustine'));
      expect(suggestions, hasLength(1),
          reason: 'overlapping collections must not each produce a notice');
    });

    test('a surname alone is enough', () {
      final suggestions = suggest('Chrysostom on almsgiving');
      expect(suggestions.first.packId, 'author-chrysostom');
    });

    test('an author already on the device is never suggested again', () {
      // The regression this locks in: installing "Augustine of Hippo" leaves
      // the *Catholic* collection incomplete, and that collection also lists
      // Augustine among its authors. Asking about him afterwards therefore
      // kept offering to install him — observed in the running app, right
      // after the download that was supposed to fix it.
      final suggestions = suggest(
        'What did Augustine say about grace?',
        installed: fragmentsOf(const ['author-augustine']),
      );

      expect(
        suggestions.where((s) => s.reason == SuggestionReason.namesAuthor),
        isEmpty,
        reason: 'his writings are installed; only a collection is incomplete',
      );
    });

    test('nothing is suggested once the pack is installed', () {
      final suggestions = suggest(
        'What did Augustine say about grace?',
        installed: everything,
      );
      expect(suggestions, isEmpty);
    });
  });

  group('not crying wolf', () {
    test('"original sin" does not match Origen', () {
      // Substring matching would fire here, and a notice that is wrong once is
      // a notice that gets ignored forever.
      final suggestions = suggest('the doctrine of original sin');
      expect(
        suggestions.where((s) => s.reason == SuggestionReason.namesAuthor),
        isEmpty,
      );
    });

    test('a common first name does not name an author', () {
      // "John" appears in John Chrysostom, John Cassian, John of Damascus —
      // and in any question about the fourth gospel.
      final suggestions = suggest('What does the gospel of John teach?');
      expect(
        suggestions.where((s) => s.reason == SuggestionReason.namesAuthor),
        isEmpty,
      );
    });

    test('a question with no subject and no name suggests nothing', () {
      expect(suggest('hello'), isEmpty);
    });

    test('an installed library is never nagged', () {
      expect(
        suggest('the Eucharist', tags: ['eucharist'], installed: everything),
        isEmpty,
      );
    });
  });

  group('restraint', () => _restraint(catalogue, everything, fragmentsOf));

  group('covering a subject', () {
    test('a subject a pack covers heavily is surfaced', () {
      final suggestions = suggest(
        'What happens in the Lord\'s Supper?',
        tags: ['eucharist', 'sacraments'],
      );

      expect(suggestions, isNotEmpty);
      expect(suggestions.every((s) => s.reason == SuggestionReason.coversSubject),
          isTrue);
      expect(suggestions.first.explanation, contains('not installed'));
    });

    test('a named author outranks generic subject coverage', () {
      final suggestions = suggest(
        'What did Augustine teach about baptism?',
        tags: ['baptism'],
      );

      expect(suggestions.first.reason, SuggestionReason.namesAuthor);
      expect(suggestions.first.packId, 'author-augustine');
    });
  });
}

/// Whether the notice earns its place, rather than firing on everything
/// forever. This is the difference between a useful signal and one users learn
/// to dismiss without reading.
void _restraint(
  PackCatalogue catalogue,
  Set<String> everything,
  Set<String> Function(Iterable<String>) fragmentsOf,
) {
  const everyTag = [
    'baptism', 'eucharist', 'grace', 'justification', 'trinity',
    'salvation', 'sin', 'church', 'scripture', 'prayer',
  ];

  test('with only the core, a subject question does warn', () {
    // It should: the core holds 7 of the 83 passages tagged eucharist. An
    // answer built from those alone is drawn from under a tenth of what exists.
    final suggestions = catalogue.suggest(
      question: 'what happens in communion',
      queryTags: const ['eucharist'],
      installedFragments: const {},
    );
    expect(suggestions, hasLength(1),
        reason: 'one notice per question, not one per missing pack');
  });

  test('installing the main collection quiets most of it', () {
    // The incentive gradient that makes this honest rather than nagging:
    // installing the largest pack removes the warning for most subjects,
    // because it genuinely closes most of the gap.
    var warned = 0;
    for (final tag in everyTag) {
      final suggestions = catalogue.suggest(
        question: 'a question with no names in it',
        queryTags: [tag],
        installedFragments: fragmentsOf(const ['church-fathers']),
      );
      if (suggestions.isNotEmpty) warned++;
    }
    expect(warned, lessThan(3),
        reason: 'after the big pack, only genuinely thin subjects should warn');
  });

  test('a fully installed library never warns about any subject', () {
    for (final tag in everyTag) {
      expect(
        catalogue.suggest(
          question: 'anything at all',
          queryTags: [tag],
          installedFragments: everything,
        ),
        isEmpty,
        reason: 'nothing is missing, so nothing should be claimed missing',
      );
    }
  });
}
