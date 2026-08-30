import 'package:council/src/services/read_shelf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the Read tab's sections remember themselves.
///
/// The subtle case is telling "never touched it" apart from "deliberately
/// expanded everything" — both are an empty collapsed set, and they want
/// opposite behaviour the next time the shelf is opened.
void main() {
  late ReadShelfService shelf;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    shelf = ReadShelfService();
  });

  test('a new shelf has not been arranged', () async {
    expect(await shelf.hasArrangedSections(), isFalse);
  });

  test('the default collapse does not count as arranging', () async {
    // Otherwise the app's own default would lock itself in, and a tradition
    // installed later would never be collapsed by default.
    await shelf.applyDefaultCollapse({'Catholic', 'Reformed'});
    expect(await shelf.collapsed(), {'Catholic', 'Reformed'});
    expect(await shelf.hasArrangedSections(), isFalse);
  });

  test('opening a section is arranging', () async {
    await shelf.applyDefaultCollapse({'Catholic', 'Reformed'});
    await shelf.setCollapsed({'Reformed'});

    expect(await shelf.collapsed(), {'Reformed'});
    expect(await shelf.hasArrangedSections(), isTrue);
  });

  test('expanding everything sticks', () async {
    // The case the flag exists for: this leaves an empty collapsed set, which
    // must not be re-collapsed on the next launch.
    await shelf.setCollapsed({});
    expect(await shelf.collapsed(), isEmpty);
    expect(await shelf.hasArrangedSections(), isTrue);
  });

  test('pinning and starring are independent of each other', () async {
    await shelf.setPinned({970});
    await shelf.setStarred({41});

    expect(await shelf.pinned(), {970});
    expect(await shelf.starred(), {41});

    // Unpinning the only pinned work leaves the starred set untouched: they
    // are separate keys, not two flags on one record.
    await shelf.setPinned({});
    expect(await shelf.pinned(), isEmpty);
    expect(await shelf.starred(), {41});
  });
}
