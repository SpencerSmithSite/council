import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/widgets/tail_follower.dart';

/// The reported bug: while an answer streamed, scrolling up snapped straight
/// back to the bottom, so the app felt like it was fighting you and the start
/// of a long answer could not be read until it had finished.
FixedScrollMetrics _metrics({required double pixels, required double max}) {
  return FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: max,
    pixels: pixels,
    viewportDimension: 600,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 2,
  );
}

/// A drag: the gesture begins, the position moves, the gesture ends.
void _dragTo(TailFollower t, BuildContext ctx,
    {required double pixels, required double max}) {
  final m = _metrics(pixels: pixels, max: max);
  t.handle(UserScrollNotification(
      metrics: m, context: ctx, direction: ScrollDirection.forward));
  t.handle(ScrollUpdateNotification(metrics: m, context: ctx));
  t.handle(ScrollEndNotification(metrics: m, context: ctx));
}

/// A notification needs a real element to hang off, so every case runs inside
/// a pumped widget purely to borrow one.
Future<BuildContext> _ctx(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(Builder(builder: (c) {
    captured = c;
    return const SizedBox();
  }));
  return captured;
}

void main() {
  test('follows the end to begin with', () {
    expect(TailFollower().following, isTrue);
  });

  testWidgets('stops following once the reader scrolls up', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    _dragTo(t, ctx, pixels: 200, max: 2000);
    expect(t.following, isFalse,
        reason: 'this is the bug: the transcript kept yanking them back');
  });

  testWidgets('follows again when they scroll back to the end', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    _dragTo(t, ctx, pixels: 200, max: 2000);
    _dragTo(t, ctx, pixels: 2000, max: 2000);
    expect(t.following, isTrue);
  });

  testWidgets('a little slack still counts as being at the end', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower(slack: 80);
    // Text arriving a few characters at a time moves the end away constantly;
    // a reader who has not moved should not be treated as having left.
    _dragTo(t, ctx, pixels: 1950, max: 2000);
    expect(t.following, isTrue);
    _dragTo(t, ctx, pixels: 1800, max: 2000);
    expect(t.following, isFalse);
  });

  testWidgets('growing content alone never changes the decision', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    // No drag — just the list getting longer under a reader sitting at the end,
    // which is what happens on every streamed chunk. Reading these as "they
    // scrolled up" would be the same bug in reverse: following would switch
    // itself off a moment after being switched on.
    for (var max = 1000.0; max <= 5000; max += 250) {
      t.handle(ScrollUpdateNotification(
          metrics: _metrics(pixels: 900, max: max), context: ctx));
    }
    expect(t.following, isTrue);
  });

  testWidgets('growing content does not resurrect following either', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    _dragTo(t, ctx, pixels: 200, max: 2000);
    // The answer keeps arriving while the reader is up at the start. Their
    // choice has to survive it — this is the half of the bug that made long
    // answers unreadable.
    for (var max = 2000.0; max <= 6000; max += 250) {
      t.handle(ScrollUpdateNotification(
          metrics: _metrics(pixels: 200, max: max), context: ctx));
    }
    expect(t.following, isFalse);
  });

  testWidgets('reattach overrides a reader who had scrolled away', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    _dragTo(t, ctx, pixels: 200, max: 2000);
    t.reattach();
    expect(t.following, isTrue,
        reason: 'asking a question is a statement that you want the answer');
  });

  testWidgets('reports whether the answer changed, so callers rebuild only then', (tester) async {
    final ctx = await _ctx(tester);
    final t = TailFollower();
    final m = _metrics(pixels: 200, max: 2000);
    t.handle(UserScrollNotification(
        metrics: m, context: ctx, direction: ScrollDirection.forward));
    expect(t.handle(ScrollUpdateNotification(metrics: m, context: ctx)), isTrue);
    expect(t.handle(ScrollUpdateNotification(metrics: m, context: ctx)),
        isFalse);
  });
}
