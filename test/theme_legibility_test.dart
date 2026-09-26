import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/theme/palette.dart';
import 'package:council/src/theme/themes.dart';

/// Two colours in every palette are load-bearing and easy to get silently
/// wrong: the hairline that divides one list row from the next, and the
/// secondary label that carries a row's trailing value, a citation's source, a
/// caption under a heading.
///
/// Both are transcribed from editor themes, where they do different jobs — an
/// indent guide against the editor's own background, a comment colour that is
/// *meant* to recede behind code. Repurposed as list furniture, several of them
/// stopped being visible: Cobalt2's separator landed at 1.01:1 against the cell
/// it was supposed to divide, which is to say the grouped lists in Settings and
/// Library had no row divisions at all, in a theme nobody had screenshotted.
///
/// Checked for every theme in both brightnesses because the fix derives these
/// arithmetically, and because the failure mode is not a crash — it is a screen
/// that looks merely flat, or a subtitle that is merely hard to read.
void main() {
  final community = <String, AppPalette>{
    for (final t in kNamedThemes) ...{
      '${t.label} (dark)': t.dark,
      '${t.label} (light)': t.light,
    },
  };

  final platform = <String, AppPalette>{
    'Apple (dark)': applePalette(Brightness.dark),
    'Apple (light)': applePalette(Brightness.light),
    'Fluent (dark)': fluentPalette(Brightness.dark),
    'Fluent (light)': fluentPalette(Brightness.light),
    'Material (dark)': materialPalette(Brightness.dark),
    'Material (light)': materialPalette(Brightness.light),
  };

  group('a separator is visible against what it divides', () {
    community.forEach((name, palette) {
      test(name, () {
        // Both backgrounds, because this colour is the hairline between cells
        // (drawn on `surface`) and also `outline` — the border of a card, which
        // sits against the page behind it.
        for (final (where, bg) in [
          ('the cell it divides', palette.scheme.surface),
          ('the page behind the cell', palette.groupedBackground),
        ]) {
          expect(contrastRatio(palette.separator, bg),
              greaterThanOrEqualTo(kMinSeparatorContrast),
              reason: 'against $where this hairline is not drawn at all, so '
                  'grouped rows run together into one block');
        }
      });
    });
  });

  group('a secondary label is readable', () {
    community.forEach((name, palette) {
      test(name, () {
        final text = palette.scheme.onSurface;
        for (final bg in [palette.scheme.surface, palette.groupedBackground]) {
          // Scaled down where the theme's own body text does not clear the bar
          // either: a handful of these palettes are low-contrast by design, and
          // lifting a subtitle past the paragraph above it would read worse,
          // not better.
          final body = contrastRatio(text, bg);
          final headroom = body * 0.8;
          final target = headroom < kMinSecondaryLabelContrast
              ? headroom
              : kMinSecondaryLabelContrast;
          expect(contrastRatio(palette.secondaryLabel, bg),
              greaterThanOrEqualTo(target - 0.001),
              reason: 'subtitles and trailing values are information the '
                  'reader needs, not decoration; this theme manages '
                  '${body.toStringAsFixed(1)}:1 for its own body text');
        }
      });
    });
  });

  group('a secondary label still reads as secondary', () {
    community.forEach((name, palette) {
      test(name, () {
        // The floor lifts a dim subtext toward the text colour, and the failure
        // mode of lifting too far is a subtitle indistinguishable from its own
        // title. It must stay behind the body text it sits under.
        final surface = palette.scheme.surface;
        final body = contrastRatio(palette.scheme.onSurface, surface);
        final secondary = contrastRatio(palette.secondaryLabel, surface);
        expect(secondary, lessThan(body),
            reason: 'a subtitle at or past the contrast of its own title has '
                'stopped being a subtitle');
      });
    });
  });

  group('platform palettes are left as the platform defines them', () {
    // Deliberately exempt from the floors above. Windows draws its own card
    // stroke at 1.19:1; matching what the OS actually draws is the entire
    // objective of these three, and a floor that overrode it would make the app
    // look less native rather than more.
    platform.forEach((name, palette) {
      test(name, () {
        expect(palette.separator, isNotNull);
        expect(contrastRatio(palette.secondaryLabel, palette.scheme.surface),
            greaterThan(1.0),
            reason: 'a sanity check only — these values are transcriptions, '
                'not derivations');
      });
    });
  });
}
