import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/highlight_colours.dart';

/// What the reader picked in the highlight sheet.
///
/// The sheet answers with one of these rather than a bare colour because
/// "erase" is a choice the palette can return too, and a null result has to
/// stay free to mean "dismissed without choosing".
class HighlightChoice {
  /// The colour to paint, or null when the reader chose the eraser.
  final HighlightColour? colour;

  const HighlightChoice.paint(HighlightColour this.colour);
  const HighlightChoice.erase() : colour = null;

  bool get isErase => colour == null;
}

/// The toolbar that appears once the reader has tapped a verse.
///
/// A floating pill rather than a bar bolted to the bottom of the screen: it
/// belongs to the selection, not to the screen, and it has to be obvious that
/// dismissing it puts the reader back where they were. It is drawn on the
/// inverse surface so it reads as a layer above the page in either brightness
/// without competing with the highlight colours it is used to choose.
class PassageActionBar extends StatelessWidget {
  /// How many pieces are selected, and what to call them ("3 verses").
  final int count;
  final String noun;

  final VoidCallback onDismiss;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onNote;
  final VoidCallback onAsk;

  /// Opens the colour sheet. The bar does not present it itself: the bar lives
  /// in the overlay above every route, so whoever owns it has to be able to
  /// stand it down while the sheet is up.
  final VoidCallback onHighlight;

  const PassageActionBar({
    super.key,
    required this.count,
    required this.noun,
    required this.onDismiss,
    required this.onCopy,
    required this.onShare,
    required this.onNote,
    required this.onAsk,
    required this.onHighlight,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onBar = scheme.onInverseSurface;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: ShapeDecoration(
          color: scheme.inverseSurface,
          shape: const StadiumBorder(),
          shadows: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Action(
              icon: Icons.close,
              tooltip: 'Clear selection',
              colour: onBar,
              onTap: onDismiss,
            ),
            // The count, said in words to assistive technology because "3" on
            // its own does not tell anyone what has been picked.
            Semantics(
              label: '$count $noun selected',
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            _Separator(colour: onBar),
            _Action(
              icon: isApplePlatform ? Icons.copy_rounded : Icons.content_copy,
              tooltip: 'Copy',
              colour: onBar,
              onTap: onCopy,
            ),
            _Action(
              icon: Icons.ios_share,
              tooltip: 'Share',
              colour: onBar,
              onTap: onShare,
            ),
            _Action(
              icon: Icons.palette_outlined,
              tooltip: 'Highlight',
              colour: onBar,
              onTap: onHighlight,
            ),
            _Action(
              icon: Icons.sticky_note_2_outlined,
              tooltip: 'Save to a note',
              colour: onBar,
              onTap: onNote,
            ),
            _Separator(colour: onBar),
            _Action(
              icon: Icons.auto_awesome,
              tooltip: 'Ask about this passage',
              // The one action that is not a filing operation, and the reason
              // this app exists rather than a notes app — so it is the only
              // glyph in the bar that carries colour.
              colour: scheme.primary,
              onTap: onAsk,
            ),
          ],
        ),
      ),
    );
  }
}

/// The palette, as a sheet. Returns what the reader picked, or null if they
/// dismissed it without picking anything.
///
/// [hasHighlight] is true when at least one selected piece is already
/// highlighted, which turns the colour row into an eraser as well as a palette.
Future<HighlightChoice?> showHighlightSheet(
  BuildContext context, {
  required int count,
  required String noun,
  required bool hasHighlight,
}) {
  final scheme = Theme.of(context).colorScheme;
  final brightness = Theme.of(context).brightness;

  return showModalBottomSheet<HighlightChoice>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Highlight $count $noun',
                style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final colour in HighlightColour.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Semantics(
                      button: true,
                      label: colour.label,
                      child: GestureDetector(
                        key: ValueKey('highlight-swatch-${colour.id}'),
                        onTap: () => Navigator.pop(
                          sheetContext,
                          HighlightChoice.paint(colour),
                        ),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: colour.resolve(brightness),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: scheme.outlineVariant,
                              width: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (hasHighlight) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pop(
                  sheetContext,
                  const HighlightChoice.erase(),
                ),
                icon: const Icon(Icons.format_color_reset_outlined),
                label: const Text('Remove highlight'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color colour;
  final VoidCallback onTap;

  const _Action({
    required this.icon,
    required this.tooltip,
    required this.colour,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 40,
          child: Icon(icon, size: 21, color: colour),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  final Color colour;

  const _Separator({required this.colour});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: colour.withValues(alpha: 0.3),
    );
  }
}
