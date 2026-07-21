import 'package:flutter_test/flutter_test.dart';
import 'package:theology_app/src/services/database_service.dart';

void main() {
  final db = DatabaseService();

  group('extractTags', () {
    test('every produced slug exists in the tag vocabulary', () {
      // The original mapping pointed at slugs like `soteriology` and
      // `ecclesiology` that the database has never contained, so tag-boosted
      // retrieval silently returned nothing. Guard against a repeat.
      const queries = [
        'What is the Trinity?',
        'Compare views on baptism',
        'What did Augustine say about grace?',
        'Explain the atonement',
        'Who is the Holy Spirit?',
        'What happens at the last judgment?',
        'Tell me about predestination and free will',
        'What is soteriology?',
        'Explain ecclesiology',
        'What is pneumatology?',
        'What do the fathers say about the resurrection?',
        'Describe the eucharist and the lord\'s supper',
        'What is sanctification and holiness?',
        'Angels, heaven, and hell',
        'The second coming',
        'Liturgy and worship',
      ];

      for (final query in queries) {
        for (final slug in db.extractTags(query)) {
          expect(
            DatabaseService.tagSlugs,
            contains(slug),
            reason: 'query "$query" produced unknown slug "$slug"',
          );
        }
      }
    });

    test('maps technical names onto the plainer slug the database uses', () {
      expect(db.extractTags('what is soteriology'), contains('salvation'));
      expect(db.extractTags('explain ecclesiology'), contains('church'));
      expect(db.extractTags('define pneumatology'), contains('holy-spirit'));
    });

    test('is case insensitive', () {
      expect(db.extractTags('THE TRINITY'), contains('trinity'));
      expect(db.extractTags('the trinity'), contains('trinity'));
    });

    test('deduplicates slugs reached by more than one phrase', () {
      // 'eucharist' and 'communion' both map to the eucharist slug.
      final tags = db.extractTags('is communion the same as the eucharist');
      expect(tags.where((t) => t == 'eucharist').length, 1);
    });

    test('returns nothing for a query with no doctrinal terms', () {
      expect(db.extractTags('what should I read next'), isEmpty);
    });

    test('matches whole words only', () {
      // Substring matching used to fire on any of these.
      expect(db.extractTags('hello there'), isEmpty);
      expect(db.extractTags('a sincere question'), isEmpty);
      expect(db.extractTags('evangelical theology'), isEmpty);
      expect(db.extractTags('that was a massive council'), isEmpty);
      expect(db.extractTags('it fell into disgrace'), isEmpty);
    });

    test('still matches simple plurals', () {
      expect(db.extractTags('what are the sacraments'), contains('sacraments'));
      expect(db.extractTags('do angels exist'), contains('angels'));
      expect(db.extractTags('our sins'), contains('sin'));
    });
  });
}
