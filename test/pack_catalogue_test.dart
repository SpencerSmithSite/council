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

  List<PackSuggestion> suggest(
    String question, {
    List<String> tags = const [],
    Set<String> installed = nothingInstalled,
  }) =>
      catalogue.suggest(
        question: question,
        queryTags: tags,
        installed: installed,
      );

  test('the catalogue describes the published packs', () {
    expect(catalogue.packs.keys,
        containsAll(['fathers-augustine', 'fathers-chrysostom', 'fathers']));
    expect(catalogue.packs['fathers']!.authors.length, greaterThan(50));
  });

  group('naming an author', () {
    test('a question about Augustine points at the Augustine pack', () {
      final suggestions = suggest('What did Augustine say about grace?');

      expect(suggestions, isNotEmpty);
      expect(suggestions.first.packId, 'fathers-augustine');
      expect(suggestions.first.reason, SuggestionReason.namesAuthor);
      expect(suggestions.first.explanation, contains('Augustine'));
    });

    test('a surname alone is enough', () {
      final suggestions = suggest('Chrysostom on almsgiving');
      expect(suggestions.map((s) => s.packId), contains('fathers-chrysostom'));
    });

    test('nothing is suggested once the pack is installed', () {
      final suggestions = suggest(
        'What did Augustine say about grace?',
        installed: {'fathers-augustine', 'fathers-chrysostom', 'fathers'},
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
      final all = catalogue.packs.keys.toSet();
      expect(
        suggest('the Eucharist', tags: ['eucharist'], installed: all),
        isEmpty,
      );
    });
  });

  group('restraint', () => _restraint(catalogue));

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
      expect(suggestions.first.packId, 'fathers-augustine');
    });
  });
}

/// Whether the notice earns its place, rather than firing on everything
/// forever. This is the difference between a useful signal and one users learn
/// to dismiss without reading.
void _restraint(PackCatalogue catalogue) {
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
      installed: const {},
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
        installed: const {'fathers'},
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
          installed: catalogue.packs.keys.toSet(),
        ),
        isEmpty,
        reason: 'nothing is missing, so nothing should be claimed missing',
      );
    }
  });
}
