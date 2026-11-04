import CouncilCore
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The passage a selection can be made in: what the actions need to cite it
/// and mark it.
struct PassageSource: Equatable {
    let unitID: Int
    let unitTitle: String?
    let sourceTitle: String?
    let passage: SegmentedPassage
}

/// The segments the reader has picked, and everything that can be done with
/// them: the state half of Flutter's `_PassageReaderState` (`_selected`,
/// `_selectedRange`, `_reference`, `_quote`, `_shareableText` and the
/// actions), lifted out of the text so the reader's one selection can span
/// whichever section it is in and the toolbar and the context menu share it.
///
/// One selection per screen, and in one passage at a time: picking a verse in
/// another section starts over there, because a citation, a quote and a
/// highlight are each about one passage.
@Observable @MainActor
final class PassageSelection {
    private(set) var source: PassageSource?
    private(set) var indices: Set<Int> = []
    /// The selected passage's highlights, for "Remove Highlight". Kept current
    /// by the screen as highlights reload (`update(highlights:forUnit:)`).
    private(set) var highlights: [Highlight] = []

    /// The note just made from the selection, which the screen presents in
    /// the editor. Set by `note`, cleared when the sheet goes.
    var editingNote: EditingNote?

    struct EditingNote: Identifiable {
        let id: Int
    }

    var isEmpty: Bool { indices.isEmpty }

    /// The selection within one unit: empty unless the selection is in it.
    func indices(inUnit id: Int) -> Set<Int> {
        source?.unitID == id ? indices : []
    }

    /// Tap: add the segment, or take it away again (Flutter's `_toggle`).
    func toggle(_ index: Int, in source: PassageSource, highlights: [Highlight]) {
        adopt(source, highlights: highlights)
        if indices.contains(index) {
            indices.remove(index)
        } else {
            indices.insert(index)
        }
        if indices.isEmpty { self.source = nil }
    }

    /// Long-press or right-click: the menu acts on the segment under the
    /// pointer, so it joins the selection if it isn't in it already, and an
    /// existing selection that includes it is left as it is.
    func include(_ index: Int, in source: PassageSource, highlights: [Highlight]) {
        adopt(source, highlights: highlights)
        indices.insert(index)
    }

    func clear() {
        indices = []
        source = nil
        highlights = []
    }

    /// Keeps "Remove Highlight" honest when the passage's highlights change
    /// under a live selection (another screen marked it, say).
    func update(highlights: [Highlight], forUnit id: Int) {
        guard source?.unitID == id else { return }
        self.highlights = highlights
    }

    private func adopt(_ source: PassageSource, highlights: [Highlight]) {
        if self.source != source {
            indices = []
        }
        self.source = source
        self.highlights = highlights
    }

    // MARK: - What the selection says

    /// The selected segments in passage order.
    var segments: [PassageSegment] {
        guard let passage = source?.passage else { return [] }
        return indices.sorted().compactMap { passage.segments.indices.contains($0) ? passage.segments[$0] : nil }
    }

    /// "3 verses", "1 paragraph".
    var countLabel: String {
        guard let passage = source?.passage else { return "" }
        return "\(indices.count) \(passage.noun(indices.count))"
    }

    /// What the navigation subtitle says while the selection lasts (see
    /// `passageActions`), or `otherwise` when nothing is selected.
    func subtitle(otherwise: String) -> String {
        isEmpty ? otherwise : "\(countLabel) selected"
    }

    /// The span the selection covers, first piece to last.
    ///
    /// A gap in the middle is swallowed deliberately, as in Flutter's
    /// `_selectedRange`: a highlight is a mark on the page, and a reader who
    /// picks verses 4 and 6 and colours them expects one stripe, not two. The
    /// quotation, unlike the mark, does show the gap.
    var range: (start: Int, end: Int)? {
        let segments = segments
        guard let first = segments.first, let last = segments.last else { return nil }
        return (first.start, last.end)
    }

    var reference: String {
        PassageCitation.reference(unitTitle: source?.unitTitle, selected: segments)
    }

    var quote: String {
        guard let passage = source?.passage else { return "" }
        return PassageCitation.quote(passage, selected: indices)
    }

    /// The passage as it should leave the app: the words, then where they
    /// came from (Flutter's `_shareableText`). A quotation without its
    /// reference is the thing this whole app exists to stop happening.
    var shareText: String {
        let attribution = [reference, source?.sourceTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return attribution.isEmpty ? quote : "\(quote)\n\n— \(attribution)"
    }

    /// Whether any selected piece is already marked, which offers the eraser.
    var hasHighlight: Bool {
        guard let range else { return false }
        return highlights.contains { $0.overlaps(range.start, range.end) }
    }

    // MARK: - Actions

    func copy() {
        let text = shareText
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        AccessibilityNotification.Announcement("Copied").post()
        clear()
    }

    /// Marks the selection's span, replacing whatever was marked there
    /// (`AnnotationStore.addHighlight`), and ends the selection, as Flutter's
    /// `_highlight` does. The screens reload their highlights when the store
    /// announces the write (`AppModel.annotationsRevision`).
    func highlight(_ colour: HighlightColour, store: AnnotationStore?) {
        guard let store, let source, let range else { return }
        let quote = quote
        let reference = reference
        clear()
        Task {
            try? await store.addHighlight(contentUnitId: source.unitID, charStart: range.start,
                                          charEnd: range.end, colour: colour.id, quote: quote,
                                          sourceTitle: source.sourceTitle, unitTitle: source.unitTitle,
                                          reference: reference)
        }
    }

    func removeHighlight(store: AnnotationStore?) {
        guard let store, let source, let range else { return }
        clear()
        Task {
            try? await store.removeHighlights(inUnit: source.unitID, charStart: range.start, charEnd: range.end)
        }
    }

    /// Creates the note from the selection exactly as Flutter's `_note` does
    /// (span, quote, titles, reference; empty body), ends the selection, and
    /// asks the screen to open it in the editor.
    func note(store: AnnotationStore?) {
        guard let store, let source, let range else { return }
        let quote = quote
        let reference = reference
        clear()
        Task {
            guard let note = try? await store.createNote(
                contentUnitId: source.unitID, charStart: range.start, charEnd: range.end, quote: quote,
                sourceTitle: source.sourceTitle, unitTitle: source.unitTitle, reference: reference)
            else { return }
            editingNote = EditingNote(id: note.id)
        }
    }

    /// The selection as a passage to ask about: the same fields Flutter's
    /// `_ask` pins (lib/src/reader/passage_reader.dart), the quote with its
    /// gaps and the reference, so the Ask tab can show it, lead the prompt
    /// with it and name the thread after it.
    var pinned: PinnedPassage? {
        guard let source, !indices.isEmpty else { return nil }
        return PinnedPassage(contentUnitId: source.unitID, quote: quote, reference: reference,
                             sourceTitle: source.sourceTitle)
    }

    /// Hands the selection to the Ask tab (`AppModel.ask(about:)`) and ends
    /// it, as Flutter's `_ask` clears the selection before opening the chat.
    func ask(_ ask: @MainActor (PinnedPassage) -> Void) {
        guard let pinned else { return }
        clear()
        ask(pinned)
    }

    /// The context menu's view of the selection as it is now, after the
    /// pressed segment has joined it. `ask` receives the passage when Ask is
    /// chosen (the screens pass `AppModel.ask(about:)`).
    func menu(store: AnnotationStore?, ask: @escaping @MainActor (PinnedPassage) -> Void) -> PassageMenu {
        PassageMenu(
            title: reference.isEmpty ? countLabel : reference,
            hasHighlight: hasHighlight,
            canAnnotate: store != nil,
            shareText: shareText,
            copy: { [weak self] in self?.copy() },
            highlight: { [weak self] colour in self?.highlight(colour, store: store) },
            removeHighlight: { [weak self] in self?.removeHighlight(store: store) },
            note: { [weak self] in self?.note(store: store) },
            ask: { [weak self] in self?.ask(ask) }
        )
    }
}

/// The actions a passage's context menu offers, captured for one menu: the
/// same ones as the selection toolbar.
struct PassageMenu {
    let title: String
    let hasHighlight: Bool
    /// False when the user database couldn't be opened: highlighting and
    /// notes are shown but disabled rather than failing silently.
    let canAnnotate: Bool
    let shareText: String
    let copy: @MainActor () -> Void
    let highlight: @MainActor (HighlightColour) -> Void
    let removeHighlight: @MainActor () -> Void
    let note: @MainActor () -> Void
    /// Opens the Ask tab with the selection pinned. Optional so a screen
    /// with nowhere to ask from can show the item disabled.
    let ask: (@MainActor () -> Void)?
}

extension HighlightColour {
    /// The swatch colour for the current appearance.
    func color(dark: Bool) -> Color {
        Color(rgba: resolve(dark: dark))
    }

    func platformColor(dark: Bool) -> PlatformColor {
        let rgba = resolve(dark: dark)
        return PlatformColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
