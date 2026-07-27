import 'package:flutter/material.dart';

/// The colours a reader can mark a passage with.
///
/// Stored by [id] rather than by value, so the palette can be re-tuned — or
/// given a proper dark-mode treatment, as it is here — without rewriting every
/// highlight already saved on the device.
///
/// The light values are the muted, paper-like washes a marker leaves on a page;
/// the dark values are much deeper, because a pastel behind light text on a
/// dark background destroys the contrast the text depends on.
enum HighlightColour {
  yellow('yellow', 'Yellow', Color(0xFFFBE7A8), Color(0xFF6B571B)),
  green('green', 'Green', Color(0xFFC8E6C3), Color(0xFF2C4F2A)),
  blue('blue', 'Blue', Color(0xFFC2DDF5), Color(0xFF1F3F5C)),
  pink('pink', 'Pink', Color(0xFFF6CCD8), Color(0xFF5C2434)),
  purple('purple', 'Purple', Color(0xFFDCCDF2), Color(0xFF3E2C5C));

  const HighlightColour(this.id, this.label, this.light, this.dark);

  /// Persisted in the database. Never change these.
  final String id;

  /// Shown to the reader, and read out by assistive technology.
  final String label;

  final Color light;
  final Color dark;

  Color resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The stored id back to a colour, tolerating ids this build does not know —
  /// a highlight saved by a later version should still render as *something*
  /// rather than disappear.
  static HighlightColour fromId(String? id) {
    for (final colour in values) {
      if (colour.id == id) return colour;
    }
    return HighlightColour.yellow;
  }
}

/// The wash used for a selection that has not been committed to a highlight.
///
/// Distinct from every highlight colour on purpose: while the action bar is up,
/// the reader needs to see which segments they have picked, and that has to be
/// legible as *selection* rather than mistaken for a mark they already made.
Color selectionWash(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.primary.withValues(
    alpha: Theme.of(context).brightness == Brightness.dark ? 0.32 : 0.20,
  );
}
