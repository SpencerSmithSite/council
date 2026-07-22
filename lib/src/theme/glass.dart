import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An approximation of Apple's Liquid Glass, for chrome on Apple platforms.
///
/// **It is an approximation, and cannot be more than one.** Flutter draws every
/// pixel through its own engine and never instantiates UIKit or AppKit views,
/// so an app built with it has no system controls for the OS to restyle — the
/// real material is not something it can inherit by linking a new SDK.
///
/// Two differences are worth knowing rather than discovering:
///
/// * `BackdropFilter` samples only what Flutter itself painted behind this
///   widget. The real material samples the window's backdrop, so on a Mac it
///   picks up the desktop and the windows underneath. Ours cannot: over an
///   empty area it blurs nothing and falls back to its tint.
/// * The real material refracts and casts specular highlights that track the
///   pointer and the content moving beneath it. The highlight here is static.
///
/// It is used for chrome only — navigation bars, toolbars, sheet headers —
/// which is also where Apple uses it, and never behind body text, where
/// translucency costs legibility for no gain.
class GlassSurface extends StatelessWidget {
  final Widget child;

  /// Sigma of the backdrop blur. Apple's regular material sits around here;
  /// higher reads as frosted plastic rather than glass.
  final double blur;

  /// Painted over the blur. Carries the surface when there is nothing behind
  /// to sample, which for a Flutter backdrop filter is common.
  final Color? tint;

  final BorderRadius? borderRadius;

  /// Which edge gets the hairline separator. Chrome at the bottom of the
  /// screen is lit from above, and vice versa.
  final bool borderOnTop;

  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 24,
    this.tint,
    this.borderRadius,
    this.borderOnTop = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    if (!glassIsAppropriate(context)) {
      // Opaque fallback. Translucency is the first thing to go when someone
      // has asked the system for less of it, and a solid surface is the
      // correct answer rather than a degraded effect.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: borderRadius,
          border: _hairline(scheme, opaque: true),
        ),
        child: child,
      );
    }

    final base = tint ??
        scheme.surface.withValues(alpha: dark ? 0.62 : 0.72);

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: _hairline(scheme, opaque: false),
            // A faint vertical gradient standing in for the way real glass is
            // brighter where light enters it. Subtle on purpose: pronounced,
            // it reads as a gradient rather than as a material.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  Colors.white.withValues(alpha: dark ? 0.06 : 0.14),
                  base,
                ),
                base,
              ],
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Border? _hairline(ColorScheme scheme, {required bool opaque}) {
    final side = BorderSide(
      color: scheme.outlineVariant.withValues(alpha: opaque ? 1.0 : 0.5),
      width: 0.5,
    );
    return borderOnTop
        ? Border(top: side)
        : Border(bottom: side);
  }
}

/// Whether to draw glass at all.
///
/// Apple platforms only: on Android and the desktop Linux/Windows builds this
/// would be borrowing another platform's visual language, which is worse than
/// having none of your own.
///
/// Also off when the system asks for higher contrast. Flutter does not expose
/// "Reduce Transparency" directly — there is no `MediaQueryData` flag for it —
/// so `highContrast` is the closest available proxy, and it is a partial one:
/// someone who has enabled Reduce Transparency alone will still see glass.
/// Worth revisiting if Flutter surfaces the real setting.
bool glassIsAppropriate(BuildContext context) {
  if (!isApplePlatform) return false;
  final media = MediaQuery.maybeOf(context);
  if (media == null) return false;
  return !media.highContrast && !media.accessibleNavigation;
}

/// Apple platforms, resolved once. `Platform` is unavailable on web, which
/// this app does not target.
final bool isApplePlatform = Platform.isIOS || Platform.isMacOS;
