import CouncilCore
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

extension NSAttributedString.Key {
    /// The index of the `PassageSegment` a run of passage text belongs to.
    /// Carried on the verse number and the words, not on the separators, so a
    /// tap between two verses selects neither.
    static let councilSegment = NSAttributedString.Key("CouncilPassageSegment")
}

/// Everything that decides how a passage is drawn, as one value, so the text
/// view can tell what changed since it last drew and redo only that: new text
/// or type means a new attributed string and a new layout; a new selection or
/// new highlights only repaint backgrounds.
struct PassageRendering: Equatable {
    var passage: SegmentedPassage
    var highlights: [Highlight]
    var selected: Set<Int>
    var typography: ReaderTypography
    var dynamicType: DynamicTypeSize
    var dark: Bool
    var textColor: PlatformColor
    var accent: PlatformColor
    /// Words a search matched (`SearchHits`), as offsets into the unit's
    /// content, marked so the reader lands on what they searched for.
    var found: [Range<Int>] = []

    /// The parts that change the text's layout. Selection and highlights are
    /// left out: they are painted, never laid out.
    struct Metrics: Equatable {
        var passage: SegmentedPassage
        var typography: ReaderTypography
        var dynamicType: DynamicTypeSize
        var textColor: PlatformColor
        var accent: PlatformColor
    }

    var metrics: Metrics {
        Metrics(passage: passage, typography: typography, dynamicType: dynamicType,
                textColor: textColor, accent: accent)
    }

    /// The selection wash: the accent at 20% (32% in dark), as Flutter's
    /// `selectionWash`. Distinct from every highlight colour, so a pick that
    /// hasn't been committed can't be mistaken for a mark already made.
    var wash: PlatformColor {
        accent.withAlphaComponent(dark ? 0.32 : 0.20)
    }

    /// The mark on a search's words: the system yellow, as Safari's and
    /// Books' find marks are, stronger than the yellow highlight so the two
    /// can't be confused, and dimmer in dark so light text stays readable.
    var findColour: PlatformColor {
        PlatformColor.systemYellow.withAlphaComponent(dark ? 0.5 : 0.75)
    }

    /// The background each segment should have: the wash when selected,
    /// otherwise the highlight covering it, the last one winning so a mark
    /// made later paints over an earlier one (Flutter's `_highlightOn`; the
    /// store returns them by start, then oldest first).
    func background(for segment: PassageSegment) -> PlatformColor? {
        if selected.contains(segment.index) { return wash }
        var found: Highlight?
        for highlight in highlights where segment.overlaps(highlight.charStart, highlight.charEnd) {
            found = highlight
        }
        guard let found else { return nil }
        let rgba = HighlightColour.fromID(found.colour).resolve(dark: dark)
        return PlatformColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

/// A passage set as text: the attributed string and where each segment
/// landed in it.
///
/// Built the way Flutter's `PassageReader.build` builds its spans: verses run
/// together with a space and prose keeps a blank line between paragraphs;
/// a verse's number goes in front of it, small, bold and in the accent colour,
/// and belongs to the segment, so tapping the number picks the verse and a
/// highlight colours it too.
struct PassageLayout {
    let string: NSAttributedString
    /// Each segment's range in `string`, number included, in UTF-16 units
    /// (the units `NSString` and TextKit count in).
    let ranges: [NSRange]

    init(_ metrics: PassageRendering.Metrics) {
        let typography = metrics.typography
        let body = typography.bodyFont(metrics.dynamicType)
        let numberFont = ReaderTypography.platformFont(typography.font, size: body.pointSize * 0.72, bold: true)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = typography.lineSpacing
        paragraph.alignment = typography.justified ? .justified : .natural
        // Justified text without hyphenation opens rivers in a narrow
        // column; with it the spacing stays even, as in Books.
        paragraph.usesDefaultHyphenation = typography.justified

        let base: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: metrics.textColor,
            .paragraphStyle: paragraph,
        ]
        let separator = metrics.passage.kind == .verse ? " " : "\n\n"

        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for segment in metrics.passage.segments {
            if segment.index > 0 {
                out.append(NSAttributedString(string: separator, attributes: base))
            }
            let start = out.length
            if let number = segment.number {
                var attributes = base
                attributes[.font] = numberFont
                attributes[.foregroundColor] = metrics.accent
                attributes[.councilSegment] = segment.index
                out.append(NSAttributedString(string: "\(number) ", attributes: attributes))
            }
            var attributes = base
            attributes[.councilSegment] = segment.index
            out.append(NSAttributedString(string: segment.text, attributes: attributes))
            ranges.append(NSRange(location: start, length: out.length - start))
        }
        string = out
        self.ranges = ranges
    }

    /// Where `range` of the unit's content shows in the laid-out string,
    /// clipped to the segment text it falls in; nil when it falls in none
    /// (between segments, or in a verse's number marker, which is drawn
    /// rather than copied).
    ///
    /// A segment's text is its content run trimmed, ending at `end`, and the
    /// laid-out string carries that text unchanged at the end of the
    /// segment's range (after the drawn number), so the two line up from
    /// there.
    static func displayRange(ofContent range: Range<Int>, passage: SegmentedPassage,
                             ranges: [NSRange]) -> NSRange? {
        for segment in passage.segments where ranges.indices.contains(segment.index) {
            let length = segment.text.utf16.count
            let contentStart = segment.end - length
            let start = max(range.lowerBound, contentStart)
            let end = min(range.upperBound, segment.end)
            guard start < end else { continue }
            let displayStart = NSMaxRange(ranges[segment.index]) - length
            return NSRange(location: displayStart + start - contentStart, length: end - start)
        }
        return nil
    }

    /// What VoiceOver says for a segment: "verse 4. In the beginning…" for a
    /// numbered one, as Flutter's `semanticsLabel`, and the words alone for
    /// prose, where a segment has no name.
    static func accessibilityLabel(_ segment: PassageSegment, in passage: SegmentedPassage) -> String {
        guard let number = segment.number else { return segment.text }
        return "\(passage.noun(1)) \(number). \(segment.text)"
    }
}

// MARK: - TextKit 2 geometry

/// Hit-testing and segment geometry on a TextKit 2 layout, shared by the
/// UIKit and AppKit text views. Points are in the text container's
/// coordinates.
enum PassageGeometry {
    /// The character under `point`, or nil when the point is between lines,
    /// past the end of a line, or outside the text.
    static func characterIndex(at point: CGPoint, in layoutManager: NSTextLayoutManager) -> Int? {
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(local) })
        else { return nil }
        let inLine = CGPoint(x: local.x - line.typographicBounds.minX, y: local.y - line.typographicBounds.minY)

        // `characterIndex(for:)` answers with the nearest caret position, which
        // past a glyph's midpoint is the *next* character; step back so the
        // character actually under the point is the one picked.
        var index = line.characterIndex(for: inLine)
        let range = line.characterRange
        if index > range.lowerBound, line.locationForCharacter(at: index).x > inLine.x {
            index -= 1
        }
        index = min(max(index, range.lowerBound), max(range.lowerBound, range.upperBound - 1))

        // The line's string is its paragraph's, so the index is relative to
        // where the paragraph starts in the document.
        let paragraphStart = layoutManager.offset(from: layoutManager.documentRange.location,
                                                  to: fragment.rangeInElement.location)
        return paragraphStart + index
    }

    /// The segment index carried at `index`, if any.
    static func segment(at index: Int, in string: NSAttributedString) -> Int? {
        guard index >= 0, index < string.length else { return nil }
        return string.attribute(.councilSegment, at: index, effectiveRange: nil) as? Int
    }

    static func textRange(_ range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        let document = layoutManager.documentRange.location
        guard let start = layoutManager.location(document, offsetBy: range.location),
              let end = layoutManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The rectangles `range` occupies, one per line it touches, each the
    /// height of its line.
    ///
    /// Built from the line fragments rather than `enumerateTextSegments`,
    /// whose frames (either type) sit a part-line above the glyphs once the
    /// paragraph has a line-height multiple: a context-menu preview cut from
    /// them showed the bottom of the line above and clipped the last line.
    static func rects(for range: NSRange, in layoutManager: NSTextLayoutManager) -> [CGRect] {
        guard let textRange = textRange(range, in: layoutManager) else { return [] }
        let document = layoutManager.documentRange.location
        var rects: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(from: textRange.location, options: [.ensuresLayout]) { fragment in
            let paragraphStart = layoutManager.offset(from: document, to: fragment.rangeInElement.location)
            guard paragraphStart < NSMaxRange(range) else { return false }
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let lineRange = NSRange(location: paragraphStart + line.characterRange.location,
                                        length: line.characterRange.length)
                let overlap = NSIntersectionRange(lineRange, range)
                guard overlap.length > 0 else { continue }
                let startX = line.locationForCharacter(at: overlap.location - paragraphStart).x
                let endX = line.locationForCharacter(at: NSMaxRange(overlap) - paragraphStart).x
                // From the baseline, by the face's ascender and descender:
                // the glyphs' own band, without the line's extra leading.
                let bounds = line.typographicBounds
                let baseline = origin.y + bounds.minY + line.glyphOrigin.y
                // The words' face, at the run's end: its start may be a verse
                // number, set smaller.
                let fontIndex = min(max(NSMaxRange(overlap) - 1 - paragraphStart, 0),
                                    max(line.attributedString.length - 1, 0))
                let font = line.attributedString.length > 0
                    ? line.attributedString.attribute(.font, at: fontIndex, effectiveRange: nil) as? ReaderTypography.PlatformFont
                    : nil
                let ascent = font?.ascender ?? bounds.height * 0.8
                let descent = abs(font?.descender ?? bounds.height * 0.2)
                rects.append(CGRect(x: origin.x + bounds.minX + startX, y: baseline - ascent,
                                    width: max(0, endX - startX), height: ascent + descent))
            }
            return true
        }
        return rects
    }

    /// Paints `rendering`'s backgrounds (selection wash, highlights, then
    /// search marks over them) into
    /// `storage`, in place, replacing any painted before.
    ///
    /// Background attributes in the text storage rather than TextKit 2
    /// rendering attributes: on iOS 26 a `UITextView` doesn't redraw for a
    /// change of rendering attributes alone (tried: the wash never showed), and
    /// an attribute-only edit relays out just the edited paragraphs.
    static func paintBackgrounds(_ storage: NSMutableAttributedString, ranges: [NSRange],
                                 rendering: PassageRendering) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        for segment in rendering.passage.segments where ranges.indices.contains(segment.index) {
            let range = ranges[segment.index]
            guard let colour = rendering.background(for: segment), NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: colour, range: range)
        }
        for hit in rendering.found {
            guard let range = PassageLayout.displayRange(ofContent: hit, passage: rendering.passage, ranges: ranges),
                  NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: rendering.findColour, range: range)
        }
        storage.endEditing()
    }
}
