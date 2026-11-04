import CouncilCore
import SwiftUI

/// Past conversations, most recently active first. Mirrors
/// `ChatHistoryScreen` in lib/src/screens/chat_history_screen.dart.
///
/// Choosing one doesn't open a copy of it here: it is handed to the Ask tab
/// (`AppModel.continueConversation`), which switches to it and carries on
/// the thread. Two live views of one thread, each appending to it, is a way
/// to lose messages, which is why Flutter hands the choice back too.
///
/// Swipe (or the context menu) deletes, after Flutter's question. The list
/// follows the history store's change stream, so a thread the Ask tab is
/// writing to moves to the top while this is on screen, as on the Mac and
/// iPad, where both are visible at once.
struct ChatHistoryView: View {
    @Environment(AppModel.self) private var model

    /// Nil until the first load finishes.
    @State private var conversations: [Conversation]?
    @State private var loadError: String?

    var body: some View {
        content
            .navigationTitle("Chat History")
            .councilScreenBackground()
            .task(id: model.chatHistory != nil) {
                guard let store = model.chatHistory else { return }
                await load()
                for await _ in store.changes() {
                    await load()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.chatHistory == nil {
            switch model.state {
            case .preparing:
                ProgressView()
            default:
                ContentUnavailableView("Chat History Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Your conversations couldn’t be opened."))
            }
        } else if let loadError {
            ContentUnavailableView("Chat History Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else if let conversations {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Questions you ask, in the Ask tab or about a passage while reading, are kept here so you can pick them back up."))
            } else {
                List(conversations) { conversation in
                    Button {
                        model.continueConversation(conversation.id)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    #if os(macOS)
                    // A Mac list otherwise draws each row as a push button.
                    .buttonStyle(.plain)
                    #endif
                    .deleteWithConfirmation(title: "Delete this conversation?",
                                            message: "The whole thread will be removed.") {
                        await delete(conversation)
                    }
                    .councilListRow()
                }
                .refreshable { await load() }
            }
        } else {
            ProgressView()
        }
    }

    private func load() async {
        guard let store = model.chatHistory else { return }
        do {
            let loaded = try await store.conversations()
            conversations = loaded
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Off the list at once, so the row animates out with the swipe; the
    /// store's change stream then reloads it from the database, which agrees.
    private func delete(_ conversation: Conversation) async {
        guard let store = model.chatHistory else { return }
        withAnimation { conversations?.removeAll { $0.id == conversation.id } }
        try? await store.deleteConversation(id: conversation.id)
    }
}

/// A thread: its title, the passage it is about, the newest message, and when
/// and how long (Flutter's `_tile`). A thread begun from a selected passage is
/// a different kind of thing from a question asked cold, and its icon says so.
private struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.councilPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: conversation.passage == nil ? "bubble.left" : "text.quote")
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let reference {
                    Text(reference)
                        .font(.subheadline)
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(2)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    /// The pinned passage's caption ("Romans 8:28 · The Holy Bible"),
    /// leaving out the reference when the title already is it: a thread
    /// about a passage is named after it.
    private var reference: String? {
        guard let passage = conversation.passage else { return nil }
        if passage.reference == conversation.title {
            // Named after its reference already: add only the work, if the
            // reference doesn't name it.
            let source = passage.sourceTitle ?? ""
            return source.isEmpty || passage.reference.hasPrefix(source) ? nil : source
        }
        return passage.caption.isEmpty ? nil : passage.caption
    }

    /// The newest message as plain text on one line's worth of spaces
    /// (Flutter collapses whitespace runs the same way). Its inline Markdown
    /// is read rather than shown: Flutter's list shows an answer's `**` as
    /// typed.
    private var preview: String {
        let raw = conversation.preview ?? ""
        let plain = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            .map { String($0.characters) } ?? raw
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Yesterday · 4 messages".
    private var caption: String {
        let count = conversation.messageCount
        return "\(RelativeDate.format(conversation.updatedAt)) · \(count) \(count == 1 ? "message" : "messages")"
    }
}

#Preview {
    NavigationStack { ChatHistoryView() }
        .environment(AppModel())
}
