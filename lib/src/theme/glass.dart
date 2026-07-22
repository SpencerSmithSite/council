import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

/// How Liquid Glass is drawn.
///
/// The point of naming this is that the app never picks. Every glass surface
/// in Council goes through [GlassSurface], so replacing the implementation —
/// including with Flutter's own, when the standalone Cupertino package ships
/// support in late 2026 — is a change to this file and nowhere else.
enum GlassBackend {
  /// `BackdropFilter` and a gradient. No dependency, works on every engine,
  /// and static: no refraction, no edge lensing, no moving highlight.
  backdropFilter,

  /// Fragment shaders via `liquid_glass_widgets`. Adds the refraction and
  /// specular behaviour a plain blur cannot produce, at the cost of a
  /// dependency that draws critical chrome and of shader work per frame.
  shader,
}

/// The active implementation.
///
/// Chosen deliberately rather than by default. Both are kept working so the
/// comparison can be made on screen rather than argued about, and so a
/// performance problem on weaker hardware is one constant away from being
/// ruled out.
const GlassBackend glassBackend = GlassBackend.shader;

/// An approximation of Apple's Liquid Glass, for chrome on Apple platforms.
///
/// **It is an approximation, and cannot be more than one.** Flutter draws every
/// pixel through its own engine and never instantiates UIKit or AppKit views,
/// so an app built with it has no system controls for the OS to restyle — the
/// real material is not something it can inherit by linking a new SDK. That is
/// true of every package in this space, shader-based or not; the ones that do
/// achieve real fidelity do it by embedding native views, which means
/// per-platform code and hybrid composition, and this app has one codebase on
/// purpose.
///
/// The differences worth knowing rather than discovering:
///
/// * A backdrop filter samples only what Flutter itself painted behind this
///   widget. The real material samples the *window's* backdrop, so on a Mac it
///   picks up the desktop and the windows underneath. Neither backend here can.
/// * Real glass responds to system settings the app never sees. Reduce
///   Transparency is honoured by native views automatically; here it has to be
///   approximated — see [glassIsAppropriate].
///
/// Used for chrome only — navigation bars, toolbars, sheet headers — which is
/// also where Apple uses it, and never behind body text, where translucency
/// costs legibility for no gain.
class GlassSurface extends StatelessWidget {
  final Widget child;

  /// Blur strength. Apple's regular material sits around here; higher reads as
  /// frosted plastic rather than glass.
  final double blur;

  /// Painted over the blur. Carries the surface when there is nothing behind
  /// to sample, which for a Flutter backdrop filter is common.
  final Color? tint;

  /// Corner radius. A single value rather than a [BorderRadius] because the
  /// shader backend's shapes take one, and chrome does not need per-corner
  /// control.
  final double radius;

  /// Which edge gets the hairline separator. Chrome at the bottom of the
  /// screen is lit from above, and vice versa.
  final bool borderOnTop;

  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 24,
    this.tint,
    this.radius = 0,
    this.borderOnTop = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!glassIsAppropriate(context)) {
      // Opaque fallback. Translucency is the first thing to go when someone
      // has asked the system for less of it, and a solid surface is the
      // correct answer rather than a degraded effect.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(radius),
          border: _hairline(scheme, opaque: true),
        ),
        child: child,
      );
    }

    return switch (glassBackend) {
      GlassBackend.shader => _shader(context),
      GlassBackend.backdropFilter => _backdropFilter(context),
    };
  }

  Widget _shader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return lg.GlassContainer(
      shape: lg.LiquidRoundedRectangle(borderRadius: radius),
      settings: lg.LiquidGlassSettings(
        // The package's blur is on a different scale from ImageFilter's sigma
        // — its default is 5 where ours is 24 — so the value is divided rather
        // than passed through, keeping one number meaningful to both backends.
        blur: blur / 4,

        // Chrome, not a hero element. The package's defaults are tuned for
        // buttons and cards that want to be looked at; a navigation bar wants
        // to be looked through, so refraction and specular are restrained.
        thickness: 12,
        lightIntensity: 0.35,
        // The docs call this one "a little ugly still". Barely on.
        chromaticAberration: 0.004,

        // The two settings below are the ones that make this look like glass
        // rather than like a blur, and both default to off.
        //
        // The package has two rendering paths and they honour different
        // knobs. On Impeller — which is every platform we draw glass on — the
        // "Premium" path runs, and it *ignores* `glowIntensity` entirely.
        // Tuning that (the obvious-looking knob) changed nothing on screen,
        // which is what a plain blur with extra steps looks like.
        //
        // `ambientRim` is the full-perimeter Fresnel ring the package
        // documents as the iOS 26 look, and it is what reads as an edge.
        ambientRim: 0.35,
        // Vibrancy: real glass saturates what it transmits.
        saturation: 1.4,
        // Apple's light-mode glass lays an even whitening veil over the
        // refracted content so text stays legible on a bright backdrop.
        // Gated in light mode so dark text stays crisp; ungated in dark mode,
        // where a per-pixel gate over an all-dark backdrop would zero it out.
        whitenStrength: dark ? 0.06 : 0.22,
        whitenGated: !dark,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: _hairline(scheme, opaque: false),
        ),
        child: child,
      ),
    );
  }

  Widget _backdropFilter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base =
        tint ?? scheme.surface.withValues(alpha: dark ? 0.62 : 0.72);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
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
    return borderOnTop ? Border(top: side) : Border(bottom: side);
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
/// Native views get this right for free, which is one real cost of drawing our
/// own. Worth revisiting if Flutter surfaces the setting.
bool glassIsAppropriate(BuildContext context) {
  if (!isApplePlatform) return false;
  final media = MediaQuery.maybeOf(context);
  if (media == null) return false;
  return !media.highContrast && !media.accessibleNavigation;
}

/// Apple platforms, resolved once. `Platform` is unavailable on web, which
/// this app does not target.
final bool isApplePlatform = Platform.isIOS || Platform.isMacOS;
