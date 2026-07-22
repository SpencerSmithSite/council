import 'package:flutter/material.dart';

import 'glass.dart';

/// A grouped list section that reads as an inset-grouped table on Apple and a
/// filled card elsewhere.
///
/// iOS and macOS settings are built from *sections*: several rows joined inside
/// one rounded rectangle, separated by hairlines that begin at the text rather
/// than the edge, under a small grey header. The app's screens were a stack of
/// separate `Card`s with gaps between every row — a Material idiom that is one
/// of the clearest signs, on an iPhone, that an app was drawn for Android.
///
/// This joins the rows. On non-Apple platforms it falls back to a single filled
/// card with plain dividers, which is Material's own correct look, so the same
/// call site serves both.
class InsetGroup extends StatelessWidget {
  /// A small header above the section. Upper-cased on Apple, matching the
  /// platform; left as written elsewhere.
  final String? header;

  /// Explanatory text below the section, in the platform's muted footnote
  /// style. iOS uses these constantly to explain a toggle without cluttering
  /// the row.
  final String? footer;

  final List<Widget> children;

  const InsetGroup({
    super.key,
    this.header,
    this.footer,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final apple = isApplePlatform;

    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i != children.length - 1) {
        separated.add(Divider(
          height: 0.5,
          thickness: 0.5,
          // Inset to the text on Apple, so the line starts under the title and
          // not under the leading icon — the detail that makes a joined section
          // read as one table rather than as stacked rows.
          indent: apple ? 52 : 0,
          color: theme.dividerTheme.color,
        ));
      }
    }

    final section = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(apple ? 10 : 12),
        border: apple
            ? null
            : Border.all(color: theme.dividerTheme.color ?? scheme.outlineVariant,
                width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(apple ? 10 : 12),
        child: Column(children: separated),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null)
          Padding(
            padding: EdgeInsets.fromLTRB(apple ? 16 : 4, 0, 16, 7),
            child: Text(
              apple ? header!.toUpperCase() : header!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: apple ? scheme.onSurfaceVariant : scheme.primary,
                letterSpacing: apple ? 0.5 : null,
                fontWeight: apple ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
        section,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
            child: Text(
              footer!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
