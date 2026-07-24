import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'glass.dart';

/// Icons that resolve to Apple's SF-Symbol set on Apple platforms and stay
/// Material elsewhere.
///
/// Flutter's `Icons.*` are Material icons; on an iPhone a Material glyph is a
/// small but constant sign that the app was drawn for Android. `CupertinoIcons`
/// carries the SF-Symbol shapes, so branching here once lets every screen name
/// an icon by intent and get the platform-correct glyph.
class AppIcons {
  AppIcons._();

  static IconData get menu =>
      isApplePlatform ? CupertinoIcons.sidebar_left : Icons.menu;
  static IconData get settings =>
      isApplePlatform ? CupertinoIcons.gear_alt_fill : Icons.settings;
  static IconData get send =>
      isApplePlatform ? CupertinoIcons.arrow_up_circle_fill : Icons.send;
  static IconData get search =>
      isApplePlatform ? CupertinoIcons.search : Icons.search;
  static IconData get close =>
      isApplePlatform ? CupertinoIcons.xmark : Icons.close;
  static IconData get chevronRight =>
      isApplePlatform ? CupertinoIcons.chevron_right : Icons.chevron_right;
  static IconData get check =>
      isApplePlatform ? CupertinoIcons.checkmark : Icons.check;
  static IconData get back =>
      isApplePlatform ? CupertinoIcons.back : Icons.arrow_back;

  // Navigation destinations.
  static IconData get ask =>
      isApplePlatform ? CupertinoIcons.bubble_left_bubble_right_fill : Icons.forum;
  static IconData get read =>
      isApplePlatform ? CupertinoIcons.book_fill : Icons.menu_book;
  static IconData get library =>
      isApplePlatform ? CupertinoIcons.square_stack_3d_up_fill : Icons.library_books;

  // Content and actions.
  static IconData get bookmark =>
      isApplePlatform ? CupertinoIcons.bookmark : Icons.bookmark_outline;
  static IconData get star =>
      isApplePlatform ? CupertinoIcons.star : Icons.star_border;
  static IconData get starFill =>
      isApplePlatform ? CupertinoIcons.star_fill : Icons.star;
  static IconData get pin =>
      isApplePlatform ? CupertinoIcons.pin_fill : Icons.push_pin;
  static IconData get info =>
      isApplePlatform ? CupertinoIcons.info_circle : Icons.info_outline;
  static IconData get theme =>
      isApplePlatform ? CupertinoIcons.paintbrush_fill : Icons.palette_outlined;
  static IconData get fontSize =>
      isApplePlatform ? CupertinoIcons.textformat_size : Icons.format_size;
  static IconData get manageContent =>
      isApplePlatform ? CupertinoIcons.square_stack_3d_up : Icons.library_books_outlined;
  static IconData get aiBackend =>
      isApplePlatform ? CupertinoIcons.sparkles : Icons.psychology_outlined;
  static IconData get citations =>
      isApplePlatform ? CupertinoIcons.quote_bubble_fill : Icons.format_quote;
  static IconData get emptyChat =>
      isApplePlatform ? CupertinoIcons.bubble_left : Icons.chat_bubble_outline;
}

/// iOS geometry, from Apple's own values.
class AppleMetrics {
  /// The inset a floating control keeps from the screen edge. Apple's tab bar
  /// uses 21pt; the app uses it for every floating bubble so they share a
  /// margin.
  static const double edgeInset = 18;

  /// The minimum tap target Apple specifies.
  static const double tapTarget = 44;

  /// The continuous-corner radius for a card-sized glass surface.
  static const double cardRadius = 20;
}

/// A continuous-corner (squircle) border — the real iOS corner, not a circular
/// arc. Used for cards, fields and sheets so their corners match the platform's.
RoundedSuperellipseBorder squircle(double radius, {BorderSide? side}) {
  return RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side ?? BorderSide.none,
  );
}

/// A translucent floating-glass fill, clipped to [shape].
///
/// This is a `BackdropFilter` rather than the fragment-shader glass: the shader
/// package blurs the *whole* screen backdrop when several of its surfaces float
/// over a full-content screen, frosting everything behind them. `BackdropFilter`
/// clips its blur to its own bounds, which is exactly what a floating bubble
/// needs — it reads as glass over the content directly beneath it and leaves the
/// rest of the screen sharp. The refraction of the true material is lost; a
/// clean translucent blur is the right trade when the alternative is a bug.
///
/// [shape] carries both the clip and the hairline border/tint. A drop shadow is
/// painted outside the clip so the control lifts off the content.
Widget floatingGlass({
  required BuildContext context,
  required ShapeBorder shape,
  required Widget child,
  double blur = 20,
}) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;

  if (!(glassIsAppropriate(context))) {
    // Opaque fallback for reduced-transparency and non-Apple platforms.
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.surface,
        shape: shape,
        shadows: _lift,
      ),
      child: child,
    );
  }

  final tint = scheme.surface.withValues(alpha: dark ? 0.55 : 0.72);
  return DecoratedBox(
    // The shadow lives on an outer box so it falls outside the clip.
    decoration: ShapeDecoration(shape: shape, shadows: _lift),
    child: ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: ShapeDecoration(color: tint, shape: shape),
          child: child,
        ),
      ),
    ),
  );
}

const List<BoxShadow> _lift = [
  BoxShadow(color: Color(0x1F000000), blurRadius: 12, offset: Offset(0, 3)),
];

/// A floating, edge-detached glass control — the iOS 26 pattern where a menu,
/// settings or action button hovers over the content as a translucent bubble
/// rather than sitting in a solid bar bolted to the screen edge.
///
/// Circular by default (a single icon); pass [width] for a capsule holding more.
/// Off Apple platforms it falls back to a plain filled circle, since the glass
/// language is Apple's and borrowing it elsewhere would look borrowed.
class GlassBubble extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  /// Diameter of a circular bubble, or the height of a capsule.
  final double size;

  const GlassBubble({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = AppleMetrics.tapTarget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bubble = floatingGlass(
      context: context,
      shape: CircleBorder(
        side: BorderSide(
          color: (Theme.of(context).dividerTheme.color ?? scheme.outlineVariant)
              .withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      blur: 18,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(child: Icon(icon, size: 22, color: scheme.onSurface)),
      ),
    );

    final tappable = Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: bubble,
      ),
    );

    return tooltip == null
        ? tappable
        : Tooltip(message: tooltip!, child: tappable);
  }
}

/// The big bold heading iOS puts at the top of a scrolling screen.
///
/// Rendered as the first item in a list so it scrolls away with the content,
/// the way a real iOS large title does. It carries the top inset that clears
/// the floating menu and settings bubbles, and an optional trailing action.
class LargeTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const LargeTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, floatingTopInset(context), 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: isApplePlatform ? 0.37 : null,
                  ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The floating text-entry bubble that lives at the bottom of a screen — asking
/// the model a question, or searching the library.
///
/// This is the iOS 26 bottom-entry pattern: a glass capsule inset from the edges
/// rather than a solid bar bolted across the screen, with the content scrolling
/// underneath it. One widget serves both the Ask composer and the Read search
/// field, differing only by leading/trailing glyphs and whether it submits or
/// filters as you type.
class GlassComposer extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool enabled;

  /// A glyph inside the capsule at the start — a magnifier for search, nothing
  /// for the composer.
  final IconData? leadingIcon;

  /// The action glyph at the end; tapping it submits. Null hides it, leaving
  /// submission to the keyboard's return key.
  final IconData? trailingIcon;

  /// Fired by the return key and by tapping [trailingIcon].
  final VoidCallback? onSubmit;

  /// Fired on every keystroke, for a field that filters live.
  final ValueChanged<String>? onChanged;

  /// A button shown at the end when [onClear] is set and the field is non-empty.
  final VoidCallback? onClear;

  const GlassComposer({
    super.key,
    required this.controller,
    required this.hintText,
    this.enabled = true,
    this.leadingIcon,
    this.trailingIcon,
    this.onSubmit,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    final field = Row(
      children: [
        if (leadingIcon != null) ...[
          Icon(leadingIcon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 5,
            textInputAction:
                onChanged != null ? TextInputAction.search : TextInputAction.send,
            style: TextStyle(color: scheme.onSurface, fontSize: 17),
            cursorColor: scheme.primary,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: hintText,
              hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 17),
            ),
            onChanged: onChanged,
            onSubmitted: (_) => onSubmit?.call(),
          ),
        ),
        if (onClear != null)
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    onTap: onClear,
                    child: Icon(AppIcons.close,
                        size: 20, color: scheme.onSurfaceVariant),
                  ),
          ),
        if (trailingIcon != null) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: enabled ? onSubmit : null,
            child: Icon(
              trailingIcon,
              size: 30,
              color: enabled ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    // The capsule: a floating squircle of glass, held off the screen edges and
    // lifted above the home indicator, growing with the keyboard so it rides
    // just above it.
    const radius = 26.0;
    final capsule = floatingGlass(
      context: context,
      shape: squircle(
        radius,
        side: BorderSide(
          color: (Theme.of(context).dividerTheme.color ?? scheme.outlineVariant)
              .withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: field,
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppleMetrics.edgeInset,
        6,
        AppleMetrics.edgeInset,
        // Above the home indicator when idle; above the keyboard when it is up.
        (bottom > 0 ? bottom + 8 : safeBottom + 8),
      ),
      child: capsule,
    );
  }
}
