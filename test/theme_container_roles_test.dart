import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:council/src/theme/palette.dart';
import 'package:council/src/theme/themes.dart';

/// The status banners on the AI-backend screen paint themselves with the
/// `*Container` colour roles. Every palette in this app is hand-built, and a
/// hand-built `ColorScheme` that omits those roles does not get sensible ones —
/// Flutter falls each back to its base role. That is how the "no API key"
/// banner came to fill its card with full-strength red and the "running on this
/// device" banner with full-strength accent: attention-grabbing by overriding
/// the reader's chosen theme rather than by working within it.
///
/// Checked for every theme in both brightnesses, because the fix derives the
/// containers arithmetically and the failure mode is silent — a banner that is
/// merely ugly, or text that is merely hard to read, in one theme nobody
/// screenshotted.
double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final l1 = _luminance(a), l2 = _luminance(b);
  final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final palettes = <String, AppPalette>{
    for (final t in kNamedThemes) ...{
      '${t.label} (dark)': t.dark,
      '${t.label} (light)': t.light,
    },
    'Apple (dark)': applePalette(Brightness.dark),
    'Apple (light)': applePalette(Brightness.light),
    'Fluent (dark)': fluentPalette(Brightness.dark),
    'Fluent (light)': fluentPalette(Brightness.light),
    'Material (dark)': materialPalette(Brightness.dark),
    'Material (light)': materialPalette(Brightness.light),
  };

  group('container roles are tints, not the raw role', () {
    palettes.forEach((name, palette) {
      test(name, () {
        final s = palette.scheme;
        expect(s.errorContainer, isNot(s.error),
            reason: 'a banner filled with the full error colour overrides the '
                'theme instead of working within it');
        expect(s.secondaryContainer, isNot(s.secondary));
        expect(s.primaryContainer, isNot(s.primary));
      });
    });
  });

  group('banner text stays readable on its container', () {
    palettes.forEach((name, palette) {
      test(name, () {
        final s = palette.scheme;
        // WCAG AA for body text, except where the theme itself does not reach
        // it on its own surface. A handful of these community palettes put
        // their body text below 4.5:1 by design; holding a banner to a bar the
        // rest of the app misses would only mean bleaching the tint out.
        final baseline = _contrast(s.onSurface, s.surface);
        final target = baseline < 4.5 ? baseline * 0.9 : 4.5;

        expect(_contrast(s.onErrorContainer, s.errorContainer),
            greaterThanOrEqualTo(target),
            reason: 'the cloud-key disclosure is a paragraph the reader has to '
                'actually read; this theme manages '
                '${baseline.toStringAsFixed(1)}:1 on its own surface');
        expect(_contrast(s.onSecondaryContainer, s.secondaryContainer),
            greaterThanOrEqualTo(target));
      });
    });
  });

  group('a container still reads as its own surface', () {
    palettes.forEach((name, palette) {
      test(name, () {
        final s = palette.scheme;
        // Distinct from the card it sits on, or the banner disappears into the
        // page and stops being a banner at all.
        expect(s.errorContainer, isNot(s.surface));
        expect(s.secondaryContainer, isNot(s.surface));
      });
    });
  });
}
