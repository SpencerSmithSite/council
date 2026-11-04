import Foundation
import SwiftUI

/// An answer's Markdown, laid out block by block: paragraphs, headings,
/// lists (nested, bulleted and numbered), quotations, code and tables.
///
/// Flutter renders answers with `flutter_markdown`'s `MarkdownBody`
/// (`_MessageBubble` in lib/src/screens/chat_screen.dart). There is no
/// system equivalent: `Text(AttributedString(markdown:))` draws inline
/// formatting only and runs every block into one paragraph. Rather than take
/// on a third-party renderer, this asks Foundation's own parser for the full
/// syntax and walks what it records about each block, `presentationIntent`
/// (apple/PLAN.md, Phase 5). Inline formatting (bold, italics, code, links)
/// stays on the runs and SwiftUI's `Text` draws it.
///
/// `citationCount` makes the answer's `[1]`-style markers tappable: each
/// marker for a source that exists becomes a `council-citation://n` link,
/// which the screen handles with an `OpenURLAction` (see `CitationMarkers`).
///
/// Re-parsed when the text changes, which during streaming is each update
/// `Generation` hands over (newest wins, so a fast model doesn't queue them).
/// An answer is a few kilobytes; parsing it is well under a millisecond.
struct MarkdownText: View {
    let markdown: String
    var citationCount = 0

    @Environment(\.councilPalette) private var palette

    var body: some View {
        let blocks = MarkdownBlock.parse(CitationMarkers.linked(markdown, count: citationCount))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
                    .padding(.top, block.id == 0 ? 0 : block.spacingAbove)
            }
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Blocks

/// One block of the document, with the list and quotation it sits in.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph
        case heading(level: Int)
        case code(language: String?)
        case rule
        /// Rows of cells; the first row is the header when `hasHeader`.
        case table(rows: [[AttributedString]], hasHeader: Bool)
    }

    /// A list the block is inside, outermost first.
    struct ListLevel: Equatable {
        let ordered: Bool
        /// The list's own identity, so consecutive items of one list sit
        /// closer together than the blocks around it.
        let listID: Int
        let itemID: Int
        let ordinal: Int
    }

    let id: Int
    let kind: Kind
    let content: AttributedString
    let lists: [ListLevel]
    let quoteDepth: Int
    /// The item marker ("•", "2.") when this is the first block of its list
    /// item; nil for a later paragraph of the same item, which aligns under
    /// the first without repeating the marker.
    let marker: String?
    let spacingAbove: CGFloat

    /// Parses `markdown` with Foundation's full CommonMark (plus tables and
    /// strikethrough) syntax. Text the parser can't read is shown as it is,
    /// one paragraph, rather than not at all.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(markdown), lists: [],
                                  quoteDepth: 0, marker: nil, spacingAbove: 0)]
        }

        var blocks: [MarkdownBlock] = []
        var seenItems = Set<Int>()
        var previousLists: [ListLevel] = []
        // A table arrives as one run per cell; gathered here until the run
        // after its last cell.
        var table: (id: Int, rows: [[AttributedString]], rowIDs: [Int], hasHeader: Bool, lists: [ListLevel],
                    quote: Int)?

        func flushTable() {
            guard let pending = table else { return }
            table = nil
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: pending.rows, hasHeader: pending.hasHeader),
                                        content: AttributedString(), lists: pending.lists,
                                        quoteDepth: pending.quote, marker: nil,
                                        spacingAbove: spacing(after: previousLists, now: pending.lists)))
            previousLists = pending.lists
        }

        for (intent, range) in document.runs[\.presentationIntent] {
            var content = AttributedString(document[range])
            content.presentationIntent = nil
            // Components run innermost first; lists and quotes read outermost
            // first, as they nest on the page.
            let components = intent?.components ?? []
            var lists: [ListLevel] = []
            var quoteDepth = 0
            for component in components.reversed() {
                switch component.kind {
                case .orderedList, .unorderedList:
                    let ordered = if case .orderedList = component.kind { true } else { false }
                    lists.append(ListLevel(ordered: ordered, listID: component.identity, itemID: 0, ordinal: 0))
                case .listItem(let ordinal):
                    if let last = lists.popLast() {
                        lists.append(ListLevel(ordered: last.ordered, listID: last.listID,
                                               itemID: component.identity, ordinal: ordinal))
                    }
                case .blockQuote:
                    quoteDepth += 1
                default:
                    break
                }
            }

            // Tables: one cell per run.
            var tableID: Int?
            var rowID: Int?
            var isHeaderRow = false
            for component in components {
                switch component.kind {
                case .table: tableID = component.identity
                case .tableHeaderRow:
                    rowID = component.identity
                    isHeaderRow = true
                case .tableRow: rowID = component.identity
                default: break
                }
            }
            if let tableID, let rowID {
                if table?.id != tableID {
                    flushTable()
                    table = (tableID, [], [], false, lists, quoteDepth)
                }
                if table?.rowIDs.last != rowID {
                    table?.rows.append([])
                    table?.rowIDs.append(rowID)
                    if isHeaderRow, table?.rows.count == 1 { table?.hasHeader = true }
                }
                if var pending = table {
                    pending.rows[pending.rows.count - 1].append(content)
                    table = pending
                }
                continue
            }
            flushTable()

            let kind: Kind
            switch components.first?.kind {
            case .header(let level)?:
                kind = .heading(level: level)
            case .codeBlock(let language)?:
                kind = .code(language: language)
                // The parser keeps the fence's last newline.
                while content.characters.last?.isNewline == true {
                    content.removeSubrange(content.index(beforeCharacter: content.endIndex)..<content.endIndex)
                }
            case .thematicBreak?:
                kind = .rule
            default:
                kind = .paragraph
            }

            var marker: String?
            if let innermost = lists.last, !seenItems.contains(innermost.itemID) {
                seenItems.insert(innermost.itemID)
                marker = innermost.ordered ? "\(innermost.ordinal)." : bullet(depth: lists.count)
            }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, content: content, lists: lists,
                                        quoteDepth: quoteDepth, marker: marker,
                                        spacingAbove: spacing(after: previousLists, now: lists)))
            previousLists = lists
        }
        flushTable()
        return blocks
    }

    /// Items of one list sit close together; anything else gets a
    /// paragraph's gap.
    private static func spacing(after previous: [ListLevel], now: [ListLevel]) -> CGFloat {
        guard let outer = now.first, let previousOuter = previous.first, outer.listID == previousOuter.listID
        else { return 10 }
        return 4
    }

    private static func bullet(depth: Int) -> String {
        switch depth {
        case 1: "•"
        case 2: "◦"
        default: "▪︎"
        }
    }
}

// MARK: - Drawing

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @Environment(\.councilPalette) private var palette

    var body: some View {
        quoted(listed(blockBody))
    }

    @ViewBuilder
    private var blockBody: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize()
                    .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(palette.surface2, in: .rect(cornerRadius: 10))
        case .rule:
            Divider()
                .overlay(palette.separator)
                .padding(.vertical, 4)
        case .table(let rows, let hasHeader):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { cell in
                                Text(rows[row][cell])
                                    .fontWeight(hasHeader && row == 0 ? .semibold : nil)
                            }
                        }
                        if hasHeader && row == 0 {
                            Divider().overlay(palette.separator)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// A list item's marker hangs in a column of its own, so wrapped lines
    /// and later paragraphs of the item align with its first word.
    @ViewBuilder
    private func listed(_ content: some View) -> some View {
        if block.lists.isEmpty {
            content
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(block.marker ?? "•")
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
                    .opacity(block.marker == nil ? 0 : 1)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityHidden(block.marker == nil)
                content
            }
            .padding(.leading, CGFloat(block.lists.count - 1) * 20)
        }
    }

    /// A quotation gets the accent rule down its side, one per level, as
    /// Mail and Notes draw quoted text.
    @ViewBuilder
    private func quoted(_ content: some View) -> some View {
        if block.quoteDepth == 0 {
            content
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<block.quoteDepth, id: \.self) { _ in
                    Capsule()
                        .fill(palette.accent.opacity(0.6))
                        .frame(width: 3)
                }
                content
                    .foregroundStyle(palette.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

// MARK: - Citation markers

/// Turns an answer's `[1]`, `[2, 3]` and `[1-3]` markers into links the
/// transcript can open.
///
/// Done on the Markdown source rather than on the parsed text so that the
/// parser makes the links and `Text` draws them as it draws any link: in the
/// tint, tappable, announced by VoiceOver as links. Only numbers that name a
/// source the answer has (1 through `count`) are linked; a model inventing a
/// [7] for six sources gets no link to nowhere. Code (fenced blocks and
/// backtick spans) is left alone, and so is a bracket that is already a
/// Markdown link (`[1](…)`) or a reference definition (`[1]: …`).
enum CitationMarkers {
    static let scheme = "council-citation"

    /// The source number a link made by `linked` points at.
    static func sourceNumber(_ url: URL) -> Int? {
        guard url.scheme == scheme, let host = url.host() else { return nil }
        return Int(host)
    }

    static func linked(_ markdown: String, count: Int) -> String {
        guard count > 0, markdown.contains("[") else { return markdown }
        var out: [String] = []
        var fence: String?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                out.append(String(line))
                continue
            }
            if line.prefix(while: { $0 == " " }).count < 4 {
                if trimmed.hasPrefix("```") { fence = "```"; out.append(String(line)); continue }
                if trimmed.hasPrefix("~~~") { fence = "~~~"; out.append(String(line)); continue }
            }
            out.append(linkLine(String(line), count: count))
        }
        return out.joined(separator: "\n")
    }

    /// One line outside a fence: the markers outside backtick spans.
    private static func linkLine(_ line: String, count: Int) -> String {
        guard line.contains("[") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            // A backtick span: copied through to its matching run.
            if chars[i] == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                let opener = String(repeating: "`", count: run)
                if let close = find(opener, in: chars, from: i + run) {
                    out += String(chars[i..<(close + run)])
                    i = close + run
                } else {
                    out += opener
                    i += run
                }
                continue
            }
            if chars[i] == "[", let (replacement, end) = marker(chars, at: i, count: count) {
                out += replacement
                i = end
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// The marker starting at `start`, linked, and the index after it; nil
    /// when the bracket isn't a citation marker.
    private static func marker(_ chars: [Character], at start: Int, count: Int) -> (String, Int)? {
        // Escaped, or an image.
        if start > 0, chars[start - 1] == "\\" || chars[start - 1] == "!" { return nil }
        var end = start + 1
        while end < chars.count, chars[end] != "]" {
            guard chars[end].isASCII, chars[end].isNumber || ", -–".contains(chars[end]) else { return nil }
            end += 1
        }
        guard end < chars.count, end > start + 1 else { return nil }
        // A link's label, or a reference definition. (`[3][4]` is two
        // markers, which is how models write them; a numeric reference
        // link, `[text][4]` with a `[4]: url` definition, isn't something an
        // answer contains.)
        if end + 1 < chars.count, "(:".contains(chars[end + 1]) { return nil }

        let inner = String(chars[(start + 1)..<end])
        var anyLinked = false
        // "2, 3" and "1-3": each number linked on its own, the separators kept.
        var linked = ""
        var digits = ""
        func flushDigits() {
            guard !digits.isEmpty else { return }
            if let n = Int(digits), (1...count).contains(n) {
                linked += "[\(digits)](\(scheme)://\(n))"
                anyLinked = true
            } else {
                linked += digits
            }
            digits = ""
        }
        for c in inner {
            if c.isNumber { digits.append(c) } else { flushDigits(); linked.append(c) }
        }
        flushDigits()
        guard anyLinked else { return nil }
        return ("\\[\(linked)\\]", end + 1)
    }

    private static func find(_ needle: String, in chars: [Character], from: Int) -> Int? {
        let n = Array(needle)
        var i = from
        while i + n.count <= chars.count {
            if Array(chars[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Previews

#Preview("Answer") {
    ScrollView {
        MarkdownText(markdown: """
            ## Grace in Augustine

            Augustine holds that grace **precedes** every good act of the will [1]. \
            Pelagius, by contrast, taught that the will is free to choose the good unaided [2, 3][4].

            Three claims follow:

            1. Grace is *unmerited* [1].
            2. It is effective without compelling the will.
               - Not a reward for faith,
               - but its cause [4].
            3. Perseverance is itself a gift.

            > Give what you command, and command what you will.

            Code is left alone: `[1]` stays as typed.

            ```
            Confessions X.29.40
            ```

            | Writer | View |
            |---|---|
            | Augustine | Monergism |
            | Pelagius | Free will |

            ---

            A [7] that names no source is not linked.
            """, citationCount: 4)
        .padding()
    }
    .environment(\.openURL, OpenURLAction { url in
        print("Opened", url)
        return .handled
    })
}
