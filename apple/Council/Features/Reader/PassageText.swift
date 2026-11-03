import CouncilCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A passage that can be marked up: tap a verse (or a paragraph, or a
/// sentence of a long one) to select it, tap more to extend the selection;
/// long-press or right-click for the actions. The native counterpart of
/// Flutter's `PassageReader` (lib/src/reader/passage_reader.dart).
///
/// A platform text view, `UITextView` / `NSTextView` on TextKit 2, wrapped for
/// SwiftUI, rather than SwiftUI `Text`: `Text` can't say which character is
/// under a touch, and making each segment a link brings the link preview on
/// long-press and has VoiceOver call every verse a link (apple/PLAN.md, Phase
/// 3). The view isn't editable and the system's own selection is off: the
/// units a reader wants (this verse, these three verses) are the ones the
/// corpus already knows about, and dragging handles across verses on a phone
/// is fiddly and imprecise.
///
/// It owns no state. The selection lives in the screen's `PassageSelection`
/// and comes back in as `selected`; highlights come in as `highlights`.
struct PassageText: View {
    let passage: SegmentedPassage
    var highlights: [Highlight] = []
    var selected: Set<Int> = []
    /// A tap landed on segment `index`.
    var onTap: (Int) -> Void = { _ in }
    /// A long-press or right-click landed on segment `index`: select it (if
    /// it isn't already) and return the actions, or nil for no menu.
    var menu: ((Int) -> PassageMenu?)?
    /// Words a search matched, as offsets into the unit's content, marked.
    var found: [Range<Int>] = []
    /// Where the first of `found` landed, in this view's coordinates, once
    /// the text is laid out at its width: the reader scrolls it into view.
    var onFoundLayout: ((CGRect) -> Void)?

    @Environment(ReaderStyle.self) private var style
    @Environment(\.councilPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PassageTextView(rendering: rendering, onTap: onTap, menu: menu, onFound: onFoundLayout)
    }

    private var rendering: PassageRendering {
        PassageRendering(passage: passage, highlights: highlights, selected: selected,
                         typography: style.typography, dynamicType: dynamicTypeSize,
                         dark: colorScheme == .dark, textColor: textColor, accent: accent,
                         found: found)
    }

    /// Default draws with the system's own label colour, which follows
    /// light/dark and Increase Contrast by itself; a custom theme with its
    /// palette's text colour.
    private var textColor: PlatformColor {
        #if os(iOS)
        palette.isSystem ? .label : PlatformColor(palette.text)
        #else
        palette.isSystem ? .textColor : PlatformColor(palette.text)
        #endif
    }

    private var accent: PlatformColor {
        PlatformColor(palette.accent)
    }
}

// MARK: - iOS and iPadOS

#if os(iOS)

private struct PassageTextView: UIViewRepresentable {
    let rendering: PassageRendering
    let onTap: (Int) -> Void
    let menu: ((Int) -> PassageMenu?)?
    let onFound: ((CGRect) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PassageUITextView {
        let view = PassageUITextView(usingTextLayoutManager: true)
        view.coordinator = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let coordinator = context.coordinator
        coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        view.addInteraction(UIContextMenuInteraction(delegate: coordinator))
        return view
    }

    func updateUIView(_ view: PassageUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.menu = menu
        coordinator.onFound = onFound
        coordinator.apply(rendering)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PassageUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.height(forWidth: width))
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        weak var view: PassageUITextView?
        var onTap: (Int) -> Void = { _ in }
        var menu: ((Int) -> PassageMenu?)?
        var onFound: ((CGRect) -> Void)?
        private(set) var rendering: PassageRendering?
        private(set) var layout: PassageLayout?
        private var reported: FoundReport?
        /// Measured heights for the current text, by width: SwiftUI asks
        /// several times per layout pass, and measuring lays the text out.
        private var heights: [CGFloat: CGFloat] = [:]

        func apply(_ new: PassageRendering) {
            guard let view else { return }
            let old = rendering
            rendering = new
            if old?.metrics != new.metrics {
                let layout = PassageLayout(new.metrics)
                self.layout = layout
                heights = [:]
                let painted = NSMutableAttributedString(attributedString: layout.string)
                PassageGeometry.paintBackgrounds(painted, ranges: layout.ranges, rendering: new)
                view.attributedText = painted
                view.invalidateAccessibility()
                view.invalidateIntrinsicContentSize()
            } else if old != new, let layout {
                // Only the paint changed: the text and its layout stay.
                PassageGeometry.paintBackgrounds(view.textStorage, ranges: layout.ranges, rendering: new)
                view.updateAccessibilitySelection()
            }
        }

        func height(forWidth width: CGFloat) -> CGFloat {
            if let cached = heights[width] { return cached }
            guard let view else { return 0 }
            let height = ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            heights[width] = height
            return height
        }

        /// The segment under a point in the view's coordinates.
        func segment(at point: CGPoint) -> Int? {
            guard let view, let layoutManager = view.textLayoutManager, let layout else { return nil }
            let inContainer = CGPoint(x: point.x - view.textContainerInset.left,
                                      y: point.y - view.textContainerInset.top)
            guard let index = PassageGeometry.characterIndex(at: inContainer, in: layoutManager) else { return nil }
            return PassageGeometry.segment(at: index, in: layout.string)
        }

        /// A segment's line rectangles in the view's coordinates.
        /// Tells the screen where the first search mark landed, once per
        /// set of marks and width (the view lays out again for every scroll
        /// past, and the screen only needs to know once).
        func reportFound() {
            guard let onFound, let view, let rendering, let first = rendering.found.first, let layout,
                  let layoutManager = view.textLayoutManager, view.bounds.width > 0 else { return }
            let key = FoundReport(found: rendering.found, width: view.bounds.width)
            guard key != reported,
                  let range = PassageLayout.displayRange(ofContent: first, passage: rendering.passage,
                                                         ranges: layout.ranges),
                  let rect = PassageGeometry.rects(for: range, in: layoutManager).first else { return }
            reported = key
            let inView = rect.offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
            // After this layout pass: the callback sets the screen's state.
            Task { @MainActor in onFound(inView) }
        }

        func rects(forSegment index: Int) -> [CGRect] {
            guard let view, let layoutManager = view.textLayoutManager, let layout,
                  layout.ranges.indices.contains(index) else { return [] }
            return PassageGeometry.rects(for: layout.ranges[index], in: layoutManager).map {
                $0.offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
            }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let index = segment(at: recognizer.location(in: view)) else { return }
            onTap(index)
        }

        // MARK: Context menu

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let index = segment(at: location), let actions = menu?(index) else { return nil }
            return UIContextMenuConfiguration(identifier: index as NSNumber, previewProvider: nil) { [weak self] _ in
                self?.makeMenu(actions, segment: index)
            }
        }

        /// Lifts just the pressed segment's lines, as text views lift a link,
        /// rather than the whole passage.
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(for: configuration)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(for: configuration)
        }

        private func preview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let view, let index = (configuration.identifier as? NSNumber)?.intValue else { return nil }
            let rects = rects(forSegment: index).map { $0.insetBy(dx: -4, dy: 0) }
            guard !rects.isEmpty else { return nil }
            let parameters = UIPreviewParameters(textLineRects: rects.map { NSValue(cgRect: $0) })
            return UITargetedPreview(view: view, parameters: parameters)
        }

        private func makeMenu(_ actions: PassageMenu, segment: Int) -> UIMenu {
            let dark = view?.traitCollection.userInterfaceStyle == .dark
            let annotate: UIMenuElement.Attributes = actions.canAnnotate ? [] : .disabled

            var highlightItems: [UIMenuElement] = HighlightColour.allCases.map { colour in
                let swatch = UIImage(systemName: "circle.fill")?
                    .withTintColor(colour.platformColor(dark: dark), renderingMode: .alwaysOriginal)
                return UIAction(title: colour.label, image: swatch, attributes: annotate) { _ in
                    actions.highlight(colour)
                }
            }
            if actions.hasHighlight {
                highlightItems.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "Remove Highlight", image: UIImage(systemName: "eraser"),
                             attributes: annotate.union(.destructive)) { _ in actions.removeHighlight() },
                ]))
            }

            var askAttributes: UIMenuElement.Attributes = []
            if actions.ask == nil { askAttributes.insert(.disabled) }

            return UIMenu(title: actions.title, children: [
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in actions.copy() },
                    UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                        self?.share(actions.shareText, segment: segment)
                    },
                ]),
                UIMenu(options: .displayInline, children: [
                    UIMenu(title: "Highlight", image: UIImage(systemName: "highlighter"), children: highlightItems),
                    UIAction(title: "Note", image: UIImage(systemName: "note.text.badge.plus"),
                             attributes: annotate) { _ in actions.note() },
                ]),
                UIAction(title: "Ask", image: UIImage(systemName: "sparkles"), attributes: askAttributes) { _ in
                    actions.ask?()
                },
            ])
        }

        /// The share sheet, anchored to the segment (iPad presents it as a
        /// popover, which needs a source).
        private func share(_ text: String, segment: Int) {
            guard let view, var presenter = view.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = rects(forSegment: segment)
                .reduce(CGRect.null) { $0.union($1) }
            presenter.present(sheet, animated: true)
        }
    }
}

/// The text view, with one accessibility element per segment in place of the
/// whole text as one static block, so VoiceOver reads and selects a verse at
/// a time, as Flutter's per-span `semanticsLabel` does.
final class PassageUITextView: UITextView {
    fileprivate weak var coordinator: PassageTextView.Coordinator?
    private var segmentElements: [SegmentAccessibilityElement]?

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { elements() }
        set {}
    }

    /// The text changed: elements are rebuilt on next access.
    func invalidateAccessibility() {
        segmentElements = nil
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// The selection changed: same elements (so VoiceOver keeps its place),
    /// new traits.
    func updateAccessibilitySelection() {
        guard let segmentElements, let selected = coordinator?.rendering?.selected else { return }
        for element in segmentElements {
            element.accessibilityTraits = selected.contains(element.index) ? [.staticText, .selected] : .staticText
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.reportFound()
        // Frames depend on the width; recompute them, keeping the objects.
        if let segmentElements, let coordinator {
            for element in segmentElements {
                element.accessibilityFrameInContainerSpace = coordinator.rects(forSegment: element.index)
                    .reduce(CGRect.null) { $0.union($1) }
            }
        }
    }

    private func elements() -> [SegmentAccessibilityElement] {
        if let segmentElements { return segmentElements }
        guard let coordinator, let rendering = coordinator.rendering else { return [] }
        let passage = rendering.passage
        let built = passage.segments.map { segment in
            let element = SegmentAccessibilityElement(accessibilityContainer: self)
            element.index = segment.index
            element.onActivate = { [weak coordinator] in coordinator?.onTap(segment.index) }
            element.accessibilityLabel = PassageLayout.accessibilityLabel(segment, in: passage)
            element.accessibilityHint = rendering.selected.contains(segment.index)
                ? "Double-tap to deselect." : "Double-tap to select."
            element.accessibilityTraits = rendering.selected.contains(segment.index)
                ? [.staticText, .selected] : .staticText
            element.accessibilityFrameInContainerSpace = coordinator.rects(forSegment: segment.index)
                .reduce(CGRect.null) { $0.union($1) }
            return element
        }
        segmentElements = built
        return built
    }
}

private final class SegmentAccessibilityElement: UIAccessibilityElement {
    var index = 0
    var onActivate: () -> Void = {}

    override var accessibilityHint: String? {
        get { accessibilityTraits.contains(.selected) ? "Double-tap to deselect." : "Double-tap to select." }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }
}

// MARK: - macOS

#else

private struct PassageTextView: NSViewRepresentable {
    let rendering: PassageRendering
    let onTap: (Int) -> Void
    let menu: ((Int) -> PassageMenu?)?
    let onFound: ((CGRect) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassageNSTextView {
        let view = PassageNSTextView(usingTextLayoutManager: true)
        view.coordinator = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let coordinator = context.coordinator
        coordinator.view = view
        return view
    }

    func updateNSView(_ view: PassageNSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.menu = menu
        coordinator.onFound = onFound
        coordinator.apply(rendering)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PassageNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.height(forWidth: width))
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PassageNSTextView?
        var onTap: (Int) -> Void = { _ in }
        var menu: ((Int) -> PassageMenu?)?
        var onFound: ((CGRect) -> Void)?
        private(set) var rendering: PassageRendering?
        private(set) var layout: PassageLayout?
        private var reported: FoundReport?
        private var heights: [CGFloat: CGFloat] = [:]

        func apply(_ new: PassageRendering) {
            guard let view else { return }
            let old = rendering
            rendering = new
            if old?.metrics != new.metrics {
                let layout = PassageLayout(new.metrics)
                self.layout = layout
                heights = [:]
                let painted = NSMutableAttributedString(attributedString: layout.string)
                PassageGeometry.paintBackgrounds(painted, ranges: layout.ranges, rendering: new)
                view.textStorage?.setAttributedString(painted)
                view.invalidateAccessibility()
            } else if old != new, let layout, let storage = view.textStorage {
                PassageGeometry.paintBackgrounds(storage, ranges: layout.ranges, rendering: new)
                view.needsDisplay = true
                view.updateAccessibilitySelection()
            }
        }

        /// Lays the text out at `width` and measures it. NSTextView has no
        /// `sizeThatFits`, so this asks TextKit 2 directly.
        func height(forWidth width: CGFloat) -> CGFloat {
            if let cached = heights[width] { return cached }
            guard let view, let layoutManager = view.textLayoutManager,
                  let container = layoutManager.textContainer else { return 0 }
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            let height = ceil(layoutManager.usageBoundsForTextContainer.height)
            heights[width] = height
            return height
        }

        func segment(at point: CGPoint) -> Int? {
            guard let view, let layoutManager = view.textLayoutManager, let layout else { return nil }
            let origin = view.textContainerOrigin
            let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            guard let index = PassageGeometry.characterIndex(at: inContainer, in: layoutManager) else { return nil }
            return PassageGeometry.segment(at: index, in: layout.string)
        }

        /// Tells the screen where the first search mark landed, once per
        /// set of marks and width (the view lays out again for every scroll
        /// past, and the screen only needs to know once).
        func reportFound() {
            guard let onFound, let view, let rendering, let first = rendering.found.first, let layout,
                  let layoutManager = view.textLayoutManager, view.bounds.width > 0 else { return }
            let key = FoundReport(found: rendering.found, width: view.bounds.width)
            guard key != reported,
                  let range = PassageLayout.displayRange(ofContent: first, passage: rendering.passage,
                                                         ranges: layout.ranges),
                  let rect = PassageGeometry.rects(for: range, in: layoutManager).first else { return }
            reported = key
            let inView = rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            // After this layout pass: the callback sets the screen's state.
            Task { @MainActor in onFound(inView) }
        }

        func rects(forSegment index: Int) -> [CGRect] {
            guard let view, let layoutManager = view.textLayoutManager, let layout,
                  layout.ranges.indices.contains(index) else { return [] }
            let origin = view.textContainerOrigin
            return PassageGeometry.rects(for: layout.ranges[index], in: layoutManager).map {
                $0.offsetBy(dx: origin.x, dy: origin.y)
            }
        }

        func makeMenu(_ actions: PassageMenu) -> NSMenu {
            let menu = NSMenu(title: actions.title)
            let dark = view?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

            menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc", action: actions.copy))
            // The system's own Share submenu, with every service the Mac offers.
            let share = NSSharingServicePicker(items: [actions.shareText]).standardShareMenuItem
            menu.addItem(share)
            menu.addItem(.separator())

            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            let palette = NSMenu(title: "Highlight")
            for colour in HighlightColour.allCases {
                let item = ClosureMenuItem(colour.label, action: { actions.highlight(colour) })
                item.image = Self.swatch(colour.platformColor(dark: dark))
                item.isEnabled = actions.canAnnotate
                palette.addItem(item)
            }
            if actions.hasHighlight {
                palette.addItem(.separator())
                let remove = ClosureMenuItem("Remove Highlight", symbol: "eraser", action: actions.removeHighlight)
                remove.isEnabled = actions.canAnnotate
                palette.addItem(remove)
            }
            highlight.submenu = palette
            menu.addItem(highlight)

            let note = ClosureMenuItem("Note", symbol: "note.text.badge.plus", action: actions.note)
            note.isEnabled = actions.canAnnotate
            menu.addItem(note)
            menu.addItem(.separator())

            let ask = ClosureMenuItem("Ask", symbol: "sparkles", action: { actions.ask?() })
            ask.isEnabled = actions.ask != nil
            menu.addItem(ask)
            menu.autoenablesItems = false
            return menu
        }

        private static func swatch(_ colour: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                colour.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
                return true
            }
        }
    }
}

/// The text view: clicks pick segments, a right-click (or Control-click)
/// picks the one under it and shows the actions, and each segment is its own
/// accessibility element.
final class PassageNSTextView: NSTextView {
    fileprivate weak var coordinator: PassageTextView.Coordinator?
    private var segmentElements: [SegmentAccessibilityElement]?

    override var isFlipped: Bool { true }

    // A non-selectable NSTextView declines clicks; this one takes them,
    // since a click is how a segment is picked.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinator, let index = coordinator.segment(at: point) else { return }
        coordinator.onTap(index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinator, let index = coordinator.segment(at: point),
              let actions = coordinator.menu?(index) else { return nil }
        return coordinator.makeMenu(actions)
    }

    // The arrow, not the I-beam: this text can't be selected or edited.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {}

    // MARK: Accessibility

    /// The text changed: one element per segment replaces the text view's
    /// own text-area element.
    func invalidateAccessibility() {
        segmentElements = nil
        setAccessibilityRole(.group)
        setAccessibilityChildren(elements())
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func updateAccessibilitySelection() {
        guard let segmentElements, let selected = coordinator?.rendering?.selected else { return }
        for element in segmentElements {
            element.setAccessibilitySelected(selected.contains(element.index))
        }
    }

    override func layout() {
        super.layout()
        coordinator?.reportFound()
        if let segmentElements, let coordinator {
            for element in segmentElements {
                element.setAccessibilityFrameInParentSpace(coordinator.rects(forSegment: element.index)
                    .reduce(CGRect.null) { $0.union($1) })
            }
        }
    }

    private func elements() -> [SegmentAccessibilityElement] {
        if let segmentElements { return segmentElements }
        guard let coordinator, let rendering = coordinator.rendering else { return [] }
        let passage = rendering.passage
        let built = passage.segments.map { segment in
            let element = SegmentAccessibilityElement()
            element.index = segment.index
            element.onPress = { [weak coordinator] in coordinator?.onTap(segment.index) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(PassageLayout.accessibilityLabel(segment, in: passage))
            element.setAccessibilitySelected(rendering.selected.contains(segment.index))
            element.setAccessibilityFrameInParentSpace(coordinator.rects(forSegment: segment.index)
                .reduce(CGRect.null) { $0.union($1) })
            return element
        }
        segmentElements = built
        return built
    }
}

// Nonisolated: AppKit declares these overrides nonisolated. They're only
// ever called on the main thread, which `assumeIsolated` checks.
private nonisolated final class SegmentAccessibilityElement: NSAccessibilityElement {
    var index = 0
    var onPress: @MainActor () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        let press = onPress
        MainActor.assumeIsolated { press() }
        return true
    }
}

/// A menu item that runs a closure, so the passage menu can be built from
/// `PassageMenu` without a responder-chain selector per action.
private nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func invoke() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

#endif

/// What a found-mark report was made for: the same marks at the same width
/// need no second report.
private struct FoundReport: Equatable {
    let found: [Range<Int>]
    let width: CGFloat
}
