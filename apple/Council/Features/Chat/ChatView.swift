import CouncilCore
import SwiftUI

/// The Ask tab: a question, answered from the library with its sources.
///
/// Mirrors `ChatScreen` in lib/src/screens/chat_screen.dart, laid out as
/// apple/PLAN.md (Phase 5) has it, from standard parts:
///
/// - **The transcript** is a scroll view of messages: the reader's questions
///   as tinted bubbles, answers on a card with their sources underneath.
///   Answers are Markdown (`MarkdownText`), their `[1]` markers links to the
///   passage cited.
/// - **The composer** is a glass bar at the bottom (`safeAreaBar`, so the
///   transcript scrolls under it with the system's edge effect): a
///   multi-line field and a button that is Send, or Stop while an answer
///   streams. Glass is applied here by hand because no standard component is
///   a message composer; it is the same material Messages' composer uses.
/// - **Following**: while an answer streams the transcript keeps its end in
///   view, until the reader scrolls up to read; then a "Jump to Latest"
///   button offers the way back, as Flutter's `TailFollower` and
///   `_JumpToLatestButton` do. Sending a question or opening a thread always
///   goes to the end.
/// - **A pinned passage** (the reader's Ask) is a banner above the
///   transcript, with Open and a dismiss button. It leads the prompt, names
///   the thread, and changes the suggestions.
///
/// The send flow and its storage are `ChatSession`'s. Requests from other
/// screens (ask about a passage, continue a thread from Chat History) arrive
/// through `request`, which `RootView` fills from `AppModel.pendingAsk`.
/// `path` is the tab's own stack, onto which citations push their passage.
struct ChatView: View {
    @Binding var request: AskRequest?
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    @State private var session = ChatSession()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether new text pulls the view along. Off once the reader scrolls
    /// away from the end, back on when they return to it (or send).
    @State private var following = true
    @State private var userScrolling = false
    /// The transcript's scroll offset, kept so the view can be held where it
    /// is when an answer's sources unfold at its end (see `transcript`).
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        content
            .navigationTitle("Ask")
            .navigationSubtitle(session.conversation?.title ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .councilScreenBackground(grouped: true)
            .safeAreaBar(edge: .top) {
                if let passage = session.passage {
                    PassageBanner(passage: passage) {
                        withAnimation { session.unpin() }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) { composerBar }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        Task { await session.startNewConversation(app: model) }
                        draft = ""
                    }
                    .disabled(session.messages.isEmpty && session.passage == nil)
                }
            }
            // The backend may have changed while the tab was away (Apple
            // Intelligence switched on, Ollama started), as Flutter refreshes
            // the status when the screen opens.
            .task { await model.inference.refreshStatus() }
            .onChange(of: request, initial: true) { _, new in
                guard let new else { return }
                request = nil
                Task { await handle(new) }
            }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var content: some View {
        if session.messages.isEmpty {
            emptyState
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(session.messages) { message in
                    MessageRow(message: message, showsCaveat: message.id == session.caveatMessageID,
                               isStreaming: message.id == session.streamingMessageID, openPassage: openPassage)
                }
                if session.isLoading, session.messages.last?.isUser == true {
                    // Before the answer's own bubble exists: the library is
                    // being searched and the backend checked.
                    ProgressRow(label: session.isStopping ? "Stopping…" : "Searching the library…")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        // Dragging the transcript puts the keyboard away: a multi-line
        // composer's Return inserts a line rather than dismissing.
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // At the end, give or take a line, measured above the composer.
            geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 32
        } action: { _, atEnd in
            // Only the reader's own scrolling decides; content growing under
            // a reader who is following must not switch following off.
            if userScrolling { following = atEnd }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
            scrollOffset = offset
        }
        // An answer just finished, and its sources are about to unfold below
        // it. A position pinned to the bottom edge would ride down with them
        // and push the end of the answer off the top; holding the offset
        // keeps the words the reader was following where they are.
        .onChange(of: session.streamingMessageID) { old, new in
            if old != nil, new == nil { position.scrollTo(y: scrollOffset) }
        }
        .onChange(of: session.grew) {
            guard following else { return }
            // Jumps rather than animates: pieces arrive faster than an
            // animation finishes, and each would interrupt the last.
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: session.jumpToEnd) {
            following = true
            withAnimation { position.scrollTo(edge: .bottom) }
        }
    }

    /// The opening screen. With a passage pinned the suggestions are about
    /// it: a reader who has just selected three verses and pressed Ask has a
    /// question about those verses, not about the Nicene Creed.
    private var emptyState: some View {
        let anchored = session.passage != nil
        let suggestions = anchored
            ? ["What does this passage mean?", "What is the historical context?",
               "How have different traditions read this?", "Where else does Scripture say this?"]
            : ["What is the Trinity?", "Compare views on baptism", "What did Augustine say about grace?",
               "Explain the Nicene Creed"]
        let unavailable = ContentUnavailableView {
            Label(anchored ? "Ask About What You Selected" : "Ask a Theological Question",
                  systemImage: anchored ? "sparkles" : "bubble.left.and.text.bubble.right")
        } description: {
            VStack(spacing: 8) {
                Text(anchored ? "Answered from this passage and the rest of your library."
                     : "Answered from the passages in your library, with their sources.")
                if let note = backendNote {
                    Text(note)
                        .font(.footnote)
                }
            }
        } actions: {
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .disabled(session.isLoading)
        }
        // Scrolls only when it must: at the largest text sizes the prompts
        // are taller than the space the composer leaves.
        return ViewThatFits(in: .vertical) {
            unavailable
            ScrollView { unavailable }
        }
    }

    /// Said on the opening screen when the backend won't give an answer as
    /// such: search-only mode, or a backend that can't answer right now.
    private var backendNote: String? {
        if model.inference.backend.id == .none {
            return "Search-only mode is on, so you’ll get the matching passages rather than an answer."
        }
        if let status = model.inference.status, !status.available {
            return status.detail ?? ChatText.backendUnavailable
        }
        return nil
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 8) {
            if !following, session.isLoading, !session.messages.isEmpty {
                Button("Jump to Latest", systemImage: "arrow.down") {
                    following = true
                    withAnimation { position.scrollTo(edge: .bottom) }
                }
                .buttonStyle(.glass)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if let gap = session.gaps.first, !session.isLoading {
                // Scrolls inside a capped height: at the largest text size on
                // the narrowest phone the notice is taller than the screen on
                // its own, and the composer must never be pushed off it.
                ScrollView {
                    CoverageNotice(gap: gap) {
                        Task { await session.answerAgainAfterInstall(app: model) }
                    }
                    .id(gap.packID)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .frame(maxWidth: 760)
            }
            if model.inference.sendsDataOffDevice {
                Label("Questions and the passages found for them are sent to \(model.inference.backend.displayName).",
                      systemImage: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(session.passage == nil ? "Ask a question" : "Ask about this passage",
                              text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .onSubmit { send(draft) }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    sendOrStop
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: 760)
        }
        .padding(.bottom, 8)
        .animation(.default, value: following)
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if session.isLoading {
            Button("Stop", systemImage: "stop.fill") { session.stop() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(composerButtonSize)
                .disabled(session.isStopping)
                .keyboardShortcut(.cancelAction)
        } else {
            Button("Send", systemImage: "arrow.up") { send(draft) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(composerButtonSize)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// A Mac's large control is small next to a two-line composer; its
    /// extra large one matches the field, as the iPhone's large one does.
    private var composerButtonSize: ControlSize {
        #if os(macOS)
        .extraLarge
        #else
        .large
        #endif
    }

    // MARK: - Actions

    private func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.isLoading else { return }
        draft = ""
        Task { await session.send(text, app: model) }
    }

    private func openPassage(_ id: Int) {
        path.append(ReadingRoute.passage(id: id))
    }

    private func handle(_ request: AskRequest) async {
        switch request.kind {
        case .passage(let passage):
            draft = ""
            await session.pin(passage, app: model)
            composerFocused = true
        case .conversation(let id):
            await session.open(conversationID: id, app: model)
        }
    }
}

// MARK: - Messages

extension View {
    /// Lets the reader take a message's text away: selectable text on the
    /// Mac, where selecting a passage with the pointer is expected; a Copy
    /// context menu on iPhone and iPad, where selectable text takes the tap
    /// from the `[n]` links inside an answer.
    @ViewBuilder
    fileprivate func copyable(_ text: String) -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
        #endif
    }
}

/// One message: a question as a tinted bubble, an answer on a card with its
/// sources, and under the first answer a model wrote, the caveat (Flutter's
/// `_MessageBubble` and `_ModelCaveat`).
private struct MessageRow: View {
    let message: ChatSession.Message
    let showsCaveat: Bool
    /// The answer is still arriving: its sources are summed up in one line
    /// until it's done, so that following the stream keeps the newest words
    /// in view rather than the list of sources below them.
    let isStreaming: Bool
    let openPassage: (Int) -> Void

    @Environment(\.councilPalette) private var palette

    /// Settings' Show Citations. Off hides the sources under every answer,
    /// streaming or done, as Flutter's `_MessageBubble` drops its "Sources:"
    /// block; the `[n]` markers stay in the text, as they do in Flutter, and
    /// still open their passage.
    @AppStorage(AppSettings.showCitationsKey) private var showCitations = AppSettings.defaultShowCitations

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.accent, in: .rect(cornerRadius: 18))
                    .copyable(message.text)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                answer
                if showsCaveat { ModelCaveat() }
            }
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.text.isEmpty {
                ProgressRow(label: "Thinking…")
            } else {
                MarkdownText(markdown: message.text, citationCount: message.citations.count)
                    .copyable(message.text)
                    // The `[n]` markers, made links by MarkdownText.
                    .environment(\.openURL, OpenURLAction { url in
                        guard let number = CitationMarkers.sourceNumber(url) else { return .systemAction }
                        guard message.citations.indices.contains(number - 1) else { return .discarded }
                        openPassage(message.citations[number - 1].contentId)
                        return .handled
                    })
            }
            if !showCitations {
                // Nothing under the answer.
            } else if isStreaming, !message.citations.isEmpty {
                Divider().overlay(palette.separator)
                Label(message.citations.count == 1 ? "Drawing on 1 source" : "Drawing on \(message.citations.count) sources",
                      systemImage: "books.vertical")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
            } else if !message.citations.isEmpty {
                Divider().overlay(palette.separator)
                Text("Sources")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(message.citations.enumerated()), id: \.offset) { index, citation in
                        CitationRow(number: index + 1, citation: citation) {
                            openPassage(citation.contentId)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.chatCard, in: .rect(cornerRadius: 18))
    }
}

/// One cited passage: which work, who wrote it, which tradition it speaks
/// for, and whether its text can be traced to a published source (Flutter's
/// `_CitationTile`). Opens the passage.
private struct CitationRow: View {
    let number: Int
    let citation: Citation
    let open: () -> Void

    @Environment(\.councilPalette) private var palette

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("[\(number)]")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(citation.source)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.leading)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { details }
                        VStack(alignment: .leading, spacing: 4) { details }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the passage")
    }

    @ViewBuilder
    private var details: some View {
        if let tradition = citation.tradition, !tradition.isEmpty {
            Badge(tradition, background: palette.accentContainer, foreground: palette.onAccentContainer)
        }
        if let author = citation.author, !author.isEmpty {
            Text(author)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }
        if citation.isTraceable {
            Label("Origin recorded", systemImage: "checkmark.seal")
                .labelStyle(.iconOnly)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        } else {
            // Said plainly rather than hidden: a reader comparing traditions
            // is entitled to know which quotations they can go and check.
            Badge("Origin not recorded", background: palette.errorContainer, foreground: palette.onErrorContainer)
        }
    }
}

private struct Badge: View {
    let text: String
    let background: Color
    let foreground: Color

    init(_ text: String, background: Color, foreground: Color) {
        self.text = text
        self.background = background
        self.foreground = foreground
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: .capsule)
    }
}

/// Said once per thread, under the first answer a model wrote. It points at
/// the citations rather than being a generic disclaimer, and is said once
/// because a warning repeated under every answer stops being read.
private struct ModelCaveat: View {
    @Environment(\.councilPalette) private var palette

    var body: some View {
        Label("Answers are written by a language model and can be wrong or misattributed. Check them against the sources cited.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(palette.secondaryLabel)
            .padding(.horizontal, 4)
    }
}

private struct ProgressRow: View {
    let label: String
    @Environment(\.councilPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The passage a thread is about, kept in view above it: the reader will ask
/// several questions in a row and the text has to still be there for the
/// third (Flutter's `_PassageBanner`). Three lines of it, since it is a
/// reminder rather than the reading surface; Open shows it all.
///
/// On the palette's surface, not glass: it is body text.
private struct PassageBanner: View {
    let passage: PinnedPassage
    let dismiss: () -> Void

    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(caption, systemImage: "text.quote")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                NavigationLink("Open", value: ReadingRoute.passage(id: passage.contentUnitId))
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                Button("Unpin Passage", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Text(passage.quote)
                .font(.subheadline)
                .foregroundStyle(palette.text)
                .lineLimit(3)
        }
        .padding(12)
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.chatCard, in: .rect(cornerRadius: 14))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                .fill(palette.accent)
                .frame(width: 4)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: 760)
    }

    private var caption: String {
        passage.caption.isEmpty ? "Pinned passage" : passage.caption
    }
}

extension CouncilPalette {
    /// The card an answer and the pinned passage sit on. The palette's
    /// surface, except in Default on the Mac, where the system's control
    /// background is all but the window's own colour in dark mode and the
    /// card vanished; there it is the system's own quaternary fill.
    var chatCard: Color {
        #if os(macOS)
        isSystem ? Color(nsColor: .quaternarySystemFill) : surface
        #else
        surface
        #endif
    }
}

extension PinnedPassage {
    /// "Romans 8:28 · The Holy Bible", leaving out what's missing, and the
    /// work when the reference already names it (a prose work's sections are
    /// titled after it: "Tomus ad Antiochenos — 2").
    var caption: String {
        let source = sourceTitle ?? ""
        let showsSource = !source.isEmpty && !reference.hasPrefix(source)
        return [reference, showsSource ? source : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

#Preview {
    @Previewable @State var request: AskRequest?
    @Previewable @State var path = NavigationPath()
    NavigationStack(path: $path) {
        ChatView(request: $request, path: $path)
            .readingDestinations()
    }
    .environment(AppModel())
}
