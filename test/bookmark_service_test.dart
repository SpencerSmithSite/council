import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:council/src/services/bookmark_service.dart';

/// One unreadable entry must cost one bookmark.
///
/// getBookmarks used to decode the whole stored list inside a single try and
/// return an empty list if anything in it threw. Every field of an entry is an
/// unguarded cast, so one contentId stored as a double — or one missing addedAt,
/// from any earlier version of the format — emptied the reader's bookmarks. The
/// next tap on a bookmark icon then wrote that empty list back over the key,
/// which turned a display bug into permanent loss.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> store(List<Map<String, Object?>> entries) async {
    SharedPreferences.setMockInitialValues({'bookmarks': jsonEncode(entries)});
  }

  Map<String, Object?> good(int id, String title, String day) => {
        'contentId': id,
        'title': title,
        'source': 'The Confessions',
        'preview': null,
        'addedAt': '2026-09-${day}T12:00:00.000',
      };

  test('a well-formed list is read back newest first', () async {
    await store([good(1, 'Book I', '01'), good(2, 'Book II', '02')]);

    final bookmarks = await BookmarkService().getBookmarks();

    expect(bookmarks.map((b) => b.title), ['Book II', 'Book I']);
  });

  test('one malformed entry costs one bookmark, not all of them', () async {
    await store([
      good(1, 'Book I', '01'),
      {
        // The shape an older build could plausibly have written.
        'contentId': 2.0,
        'title': 'Book II',
        'source': 'The Confessions',
        'addedAt': '2026-09-02T12:00:00.000',
      },
      good(3, 'Book III', '03'),
    ]);

    final bookmarks = await BookmarkService().getBookmarks();

    expect(bookmarks.map((b) => b.title), ['Book III', 'Book I'],
        reason: 'the two readable bookmarks survive the unreadable one');
  });

  test('a missing required field costs only its own entry', () async {
    await store([
      good(1, 'Book I', '01'),
      {'contentId': 2, 'title': 'Book II'},
    ]);

    expect((await BookmarkService().getBookmarks()).map((b) => b.title),
        ['Book I']);
  });

  test('an entry that is not an object at all is skipped', () async {
    await store([good(1, 'Book I', '01')]);
    SharedPreferences.setMockInitialValues({
      'bookmarks': jsonEncode([good(1, 'Book I', '01'), 'not an object', 42]),
    });

    expect(await BookmarkService().getBookmarks(), hasLength(1));
  });

  test('adding a bookmark does not overwrite the ones it could not read',
      () async {
    await store([
      good(1, 'Book I', '01'),
      {'contentId': 2.0, 'title': 'Book II', 'source': 'x', 'addedAt': 'y'},
    ]);

    await BookmarkService().addBookmark(
      contentId: 9,
      title: 'Book IX',
      source: 'The Confessions',
    );

    // The readable one is still there. Before, the save wrote back a list built
    // from nothing, and Book I was gone for good.
    final titles = (await BookmarkService().getBookmarks()).map((b) => b.title);
    expect(titles, containsAll(['Book I', 'Book IX']));
  });

  test('stored JSON that is not a list at all is not a crash', () async {
    SharedPreferences.setMockInitialValues({'bookmarks': '{"not":"a list"}'});
    expect(await BookmarkService().getBookmarks(), isEmpty);
  });

  test('unparsable JSON is not a crash', () async {
    SharedPreferences.setMockInitialValues({'bookmarks': '{{{'});
    expect(await BookmarkService().getBookmarks(), isEmpty);
  });
}
