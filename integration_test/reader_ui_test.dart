import 'package:council/main.dart' as app;
import 'package:council/src/reader/passage_action_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The reading and chrome behaviour, driven on a real device.
///
/// These exist because the interesting failures are platform ones no unit test
/// can see. The keyboard is the clearest case: `flutter test` has no keyboard
/// at all, so "it opens and there is no way to close it" — reported on iPhone —
/// is invisible to the unit suite by construction. Here the system keyboard
/// really appears and the platform really reports its height.
///
///     flutter test integration_test/reader_ui_test.dart -d <device>
///
/// Written as **one** test that walks the app, for two reasons. Booting the
/// real app costs the corpus install and the embedding model, which is not
/// worth paying per assertion; and calling `main()` a second time in one run
/// tears down a FocusManager the previous app is still using, which fails the
/// whole file rather than one test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The height the system keyboard is currently occupying, in logical pixels.
  ///
  /// Read from the platform view rather than `tester.view`, which reports the
  /// *test* harness's overrides and is zero however the real keyboard behaves.
  double keyboardInset() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return 0;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  /// Pump until [condition] holds, or fail saying what never happened.
  ///
  /// `pumpAndSettle` cannot be used anywhere in this file: the splash animates
  /// continuously while the corpus installs, so "settled" never arrives and the
  /// call simply hangs until its timeout.
  Future<void> until(
    WidgetTester tester,
    String what,
    bool Function() condition, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $what');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    // One more frame, so anything the condition triggered is laid out.
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> untilPresent(WidgetTester tester, Finder finder,
          {Duration limit = const Duration(seconds: 20)}) =>
      until(tester, '${finder.describeMatch(Plurality.one)} to appear',
          () => finder.evaluate().isNotEmpty,
          limit: limit);

  /// Tap [target] until [condition] holds, giving up after [limit].
  ///
  /// A dismissed drawer leaves its barrier over the screen for the length of
  /// the close animation, and on a real device that outlasts the frame the
  /// content arrives on — so a single tap can land on the barrier instead of
  /// what it was aimed at, and be swallowed. Retrying is the difference
  /// between a test that describes the app and one that describes the timing.
  Future<void> tapUntil(
    WidgetTester tester,
    Finder target,
    String what,
    bool Function() condition, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
      await tester.tap(target, warnIfMissed: false);
      for (var frame = 0; frame < 8 && !condition(); frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the app can be read, marked up, and dismissed from',
      (tester) async {
    app.main();

    // Startup unpacks a 95 MB corpus and loads the embedding model on a cold
    // install, so this waits for a screen rather than for a frame count.
    //
    // Which screen depends on the device: a fresh install lands on onboarding,
    // one that has been used goes straight to the app. Handling both is not
    // defensiveness — a CI machine and a developer's simulator genuinely differ
    // here, and a test that only works on one of them is worse than none.
    await until(
      tester,
      'the app to draw its first screen',
      () =>
          find.text('Skip').evaluate().isNotEmpty ||
          find.byTooltip('Menu').evaluate().isNotEmpty,
      limit: const Duration(seconds: 180),
    );

    if (find.text('Skip').evaluate().isNotEmpty) {
      await tester.tap(find.text('Skip'));
    }
    await untilPresent(tester, find.byTooltip('Menu'),
        limit: const Duration(seconds: 60));

    // ---------------------------------------------------------------- keyboard

    // A fresh thread, so the empty state — and its non-interactive heading — is
    // reliably on screen to tap away onto.
    await tester.tap(find.byTooltip('New conversation'));
    await untilPresent(tester, find.text('Ask a theological question'));

    expect(find.bySemanticsLabel('Hide the keyboard'), findsNothing,
        reason: 'nothing is focused, so the composer should not offer it');

    await tester.tap(find.byType(TextField).first);
    await until(tester, 'the keyboard to open', () => keyboardInset() > 0);

    expect(find.bySemanticsLabel('Hide the keyboard'), findsOneWidget,
        reason: 'a focused composer must offer a way out');

    await tester.tap(find.bySemanticsLabel('Hide the keyboard'));
    await until(tester, 'the keyboard to close', () => keyboardInset() == 0);

    expect(find.bySemanticsLabel('Hide the keyboard'), findsNothing);

    // The other route out: tapping content that is not a control. The heading
    // of the empty state is a plain Text, so this only works if something above
    // it in the tree is listening — which is the fix under test.
    await tester.tap(find.byType(TextField).first);
    await until(tester, 'the keyboard to reopen', () => keyboardInset() > 0);

    await tester.tap(find.text('Ask a theological question'));
    await until(
        tester, 'the keyboard to close on a tap away', () => keyboardInset() == 0);

    // ------------------------------------------------------------------- shelf

    await tester.tap(find.byTooltip('Menu'));
    await untilPresent(tester, find.text('Read'));
    await tester.tap(find.text('Read'));
    await untilPresent(tester, find.text('Pinned'),
        limit: const Duration(seconds: 60));

    expect(find.text('Scripture'), findsOneWidget);

    final pinnedY = tester.getTopLeft(find.text('Pinned')).dy;
    final scriptureY = tester.getTopLeft(find.text('Scripture')).dy;
    expect(scriptureY, greaterThan(pinnedY),
        reason: 'Scripture belongs directly under the Pinned group');

    for (final other in const ['Catholic', 'Early Church', 'Reformed']) {
      final match = find.text(other);
      if (match.evaluate().isEmpty) continue;
      expect(tester.getTopLeft(match).dy, greaterThan(scriptureY),
          reason: 'Scripture should sit above $other');
    }

    // Collapsed by default means the works are not listed until asked for.
    expect(find.textContaining('King James Version'), findsNothing,
        reason: 'sections should start collapsed on a shelf never arranged');

    await tapUntil(tester, find.text('Scripture'), 'the section to open',
        () => find.textContaining('King James Version').evaluate().isNotEmpty);

    // ------------------------------------------------------------- selection

    await tester.tap(find.textContaining('King James Version'));
    // Opening a work resumes its last position and loads a whole chapter.
    await until(tester, 'the reader to open',
        () => find.byType(PassageActionBar).evaluate().isEmpty &&
            find.textContaining('sections').evaluate().isEmpty,
        limit: const Duration(seconds: 60));

    expect(find.byType(PassageActionBar), findsNothing);

    // "the" appears in every chapter of the KJV; the first of them lands on
    // whichever verse holds it, which is all this needs. (Taken as `first`
    // because a whole chapter holds it a hundred times over, and tapping needs
    // one range rather than all of them.)
    await tester.tapOnText(find.textRange.ofSubstring('the').first);
    await untilPresent(tester, find.byType(PassageActionBar));

    // ------------------------------------------------------------- highlighting

    // The action bar is an overlay entry, so it floats above every route the
    // navigator pushes — including the sheet it opens. Reported on iPhone: the
    // pill sat on top of the swatches it had just asked the reader to choose
    // from. It has to be gone for as long as the sheet is up.
    await tester.tap(find.byIcon(Icons.palette_outlined));
    await untilPresent(tester, find.textContaining('Highlight '));

    expect(find.byType(PassageActionBar), findsNothing,
        reason: 'the toolbar would be covering the colours');

    // Backing out leaves the selection standing, so the toolbar comes back.
    await tester.tapAt(const Offset(30, 60));
    await untilPresent(tester, find.byType(PassageActionBar));

    await tester.tap(find.byIcon(Icons.close));
    await until(tester, 'the action bar to go away',
        () => find.byType(PassageActionBar).evaluate().isEmpty);

    // ------------------------------------------------------------ bottom bar

    // The pager floats over the page rather than closing it off. Reported on
    // iPhone: a solid bar bolted across the bottom cut the text off at its top
    // edge. `extendBody` is what lets the passage run behind it, and what tells
    // the scroll view how far to pad so the last lines can still be brought out
    // from under it — drop it and the clipping comes straight back.
    final readerScaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(readerScaffold.extendBody, isTrue,
        reason: 'the passage must run behind the pager, not stop at it');
    expect(readerScaffold.bottomNavigationBar, isNotNull,
        reason: 'the pager is the floating bar being cleared');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
