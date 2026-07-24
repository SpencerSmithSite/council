import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Council mark, animated — a loading indicator built from the app's own
/// logo rather than a generic spinner.
///
/// Three quiet motions layered so it reads as "working" without being busy:
/// a slow breathing scale, a soft glow that swells with it, and a band of light
/// that sweeps across the mark like light catching the page of an open book.
/// One [AnimationController] drives all of it, so it is cheap enough to sit on
/// a cold-start splash on a slow device.
///
/// The logo already carries its own indigo tile, so the widget looks right on
/// any background — the branded splash, or the light/dark "Downloading…" view.
class BrandLoader extends StatefulWidget {
  /// Side length of the (square) mark in logical pixels.
  final double size;

  const BrandLoader({super.key, this.size = 120});

  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final radius = size * 0.225; // matches the app icon's corner rounding

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value; // 0..1, looping

          // Breathing: a gentle in-and-out on a sine so there is no seam at the
          // loop point.
          final breathe = 1 + 0.035 * math.sin(t * 2 * math.pi);
          // The glow swells with the breath.
          final glow = 0.5 + 0.5 * ((math.sin(t * 2 * math.pi) + 1) / 2);

          // The light band sweeps left→right and repeats. A short pause at each
          // end (the clamp) keeps it from feeling frantic.
          final sweep = (t * 1.35).clamp(0.0, 1.0);
          final dx = -1.5 + 3.0 * sweep;

          return Stack(
            alignment: Alignment.center,
            children: [
              // A soft halo in the logo's own indigo, breathing with the mark.
              Container(
                width: size * 0.82,
                height: size * 0.82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B2E6B)
                          .withValues(alpha: 0.35 * glow),
                      blurRadius: size * (0.22 + 0.10 * glow),
                      spreadRadius: size * 0.02,
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: breathe,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: ShaderMask(
                    // srcATop paints the light only where the mark is opaque, so
                    // the highlight rides on the tile rather than spilling past
                    // its rounded corners.
                    blendMode: BlendMode.srcATop,
                    shaderCallback: (rect) {
                      return LinearGradient(
                        begin: Alignment(dx - 0.45, -0.7),
                        end: Alignment(dx + 0.45, 0.7),
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.32),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ).createShader(rect);
                    },
                    child: Image.asset(
                      'assets/icon/icon.png',
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A full-screen branded loading view: the animated mark on the logo's own
/// indigo, with an optional caption. Used as the cold-start splash while the
/// database, model and library load.
class BrandSplash extends StatelessWidget {
  final String? message;

  const BrandSplash({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    // A Scaffold (Material) is what gives the text a real DefaultTextStyle —
    // without one, Flutter paints the debug yellow-underlined fallback. The
    // gradient container fills over the Scaffold's own background.
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF5140A0), Color(0xFF291F4E)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLoader(size: 132),
              const SizedBox(height: 28),
              Text(
                'Council',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.95),
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  decoration: TextDecoration.none,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
