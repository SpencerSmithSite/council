import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/screens/ai_backend_screen.dart';
import 'package:council/src/services/inference/local_model_backend.dart';

/// The tier rows are the one piece of this picker that cannot be reached on a
/// modest device — an emulator with 4 GB is only ever offered one model, so it
/// renders the single-choice branch and never these. Covered here instead.
Widget _row(LocalModelTier tier, LocalModelChoice model, {double width = 354}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: TierTitle(tier: tier, model: model),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('each tier names the trade and the model', (tester) async {
    for (final tier in LocalModelTier.values) {
      await tester.pumpWidget(_row(tier, LocalModelChoice.qwen3_4b));
      expect(find.text(tier.label), findsOneWidget);
      expect(find.textContaining(LocalModelChoice.qwen3_4b.name),
          findsOneWidget);
      expect(find.textContaining(LocalModelChoice.qwen3_4b.approximateSize),
          findsOneWidget);
    }
  });

  testWidgets('the tier leads, because the parameter count is not a decision',
      (tester) async {
    await tester.pumpWidget(
        _row(LocalModelTier.recommended, LocalModelChoice.qwen3_8b));
    final label = tester.getTopLeft(find.text(LocalModelTier.recommended.label));
    final model = tester.getTopLeft(
        find.textContaining(LocalModelChoice.qwen3_8b.name));
    expect(label.dy, lessThan(model.dy));
  });

  testWidgets('no overflow at the width a narrow phone gives it',
      (tester) async {
    // The longest label paired with the longest model name. A Row of these
    // overflowed once already in this screen's history.
    for (final w in [280.0, 354.0]) {
      await tester.pumpWidget(
          _row(LocalModelTier.small, LocalModelChoice.qwen3_4b, width: w));
      expect(tester.takeException(), isNull, reason: 'at ${w}px');
    }
  });

  testWidgets('every tier has a rationale a reader can act on', (tester) async {
    for (final tier in LocalModelTier.values) {
      expect(tier.rationale, isNotEmpty);
      expect(tier.rationale.length, greaterThan(40),
          reason: 'the label alone does not say what the trade is');
    }
  });
}
