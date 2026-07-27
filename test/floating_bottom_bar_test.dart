import 'package:council/src/theme/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The contract every screen with a bottom bar depends on.
///
/// A floating bar takes no layout space, so content passes behind it — which is
/// the look, and also the hazard: without an inset the last lines of a scroll
/// view can never be brought out from under the bar and simply read as cut off.
/// [floatingBottomInset] closes that gap by reading the bar's *measured* height
/// out of the `MediaQuery` a `Scaffold` with `extendBody: true` installs around
/// its body.
///
/// These tests exist because that mechanism is invisible at the call site. A
/// screen that loses `extendBody: true`, or reads the inset from a context
/// outside the body, still compiles and still looks almost right — it just
/// silently goes back to clipping its own content.
void main() {
  /// Builds a scaffold whose bar is [barHeight] tall and reports the inset the
  /// body would use, along with what the body's `MediaQuery` claims.
  Future<({double inset, double padding})> measure(
    WidgetTester tester, {
    required double barHeight,
    required bool extendBody,
    double safeBottom = 34,
  }) async {
    late double inset;
    late double padding;

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: safeBottom)),
        child: MaterialApp(
          home: Scaffold(
            extendBody: extendBody,
            bottomNavigationBar: SizedBox(height: barHeight),
            body: Builder(
              builder: (context) {
                inset = floatingBottomInset(context, extra: 0);
                padding = MediaQuery.of(context).padding.bottom;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    return (inset: inset, padding: padding);
  }

  testWidgets('the inset covers the whole bar, not just the safe area',
      (tester) async {
    final result = await measure(tester, barHeight: 96, extendBody: true);

    // 96, not the 34pt home-indicator inset: a scroll view padded by the safe
    // area alone would still lose everything under the bar itself.
    expect(result.padding, 96);
    expect(result.inset, 96);
  });

  testWidgets('the extra is added on top of the measured height',
      (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
        child: MaterialApp(
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: const SizedBox(height: 96),
            body: Builder(
              builder: (context) {
                expect(floatingBottomInset(context, extra: 12), 108);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('a taller bar moves the inset with it', (tester) async {
    // What happens when the composer grows to five lines. Nothing is pinned to
    // a constant, so the content follows.
    final short = await measure(tester, barHeight: 60, extendBody: true);
    final tall = await measure(tester, barHeight: 180, extendBody: true);

    expect(short.inset, 60);
    expect(tall.inset, 180);
  });

  testWidgets('without extendBody the bar is invisible to the body',
      (tester) async {
    // The failure this guards against: drop `extendBody: true` and the body is
    // laid out above the bar instead of behind it. It is then told nothing about
    // the bar *or* the safe area — both are the bar's business now — so the
    // inset collapses to zero and the content stops at the bar's top edge.
    final result = await measure(tester, barHeight: 96, extendBody: false);

    expect(result.inset, 0);
  });

  testWidgets('the safe area still wins when there is no bar', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
        child: MaterialApp(
          home: Scaffold(
            extendBody: true,
            body: _InsetProbe(expected: 34),
          ),
        ),
      ),
    );
  });
}

class _InsetProbe extends StatelessWidget {
  final double expected;

  const _InsetProbe({required this.expected});

  @override
  Widget build(BuildContext context) {
    expect(floatingBottomInset(context, extra: 0), expected);
    return const SizedBox.expand();
  }
}
