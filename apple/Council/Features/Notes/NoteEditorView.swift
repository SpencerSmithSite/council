import CouncilCore
import SwiftUI

/// One note: the quotation it was taken from, which can't be edited, and the
/// reader's own words, which save as they're typed. Mirrors
/// `NoteEditorScreen` in lib/src/screens/note_editor_screen.dart.
///
/// Pushed from the Notes list, and presented in a sheet (inside its own
/// `NavigationStack`) by the reader straight after "Note" creates one. It
/// works the same in both: it closes itself with `dismiss`, which pops the
/// push or dismisses the sheet. In the sheet, "Open Passage" only works if
/// that stack applies `.readingDestinations()`.
///
/// There is no Save button, as in Flutter and every notes app. The body is
/// written a moment after typing pauses, again when the screen goes away, and
/// when the app goes to the background, so neither a back gesture nor the app
/// being killed afterwards can lose what was typed. What is stored is the
/// trimmed text; the field itself is never rewritten under the cursor.
///
/// A note that was created by opening this screen and never written in is
/// deleted again when the screen goes away (Flutter's `_commit`), or "Note"
/// followed by a change of mind would leave a bare quotation in the Notes
/// list for good.
struct NoteEditorView: View {
    let noteID: Int
    /// Put the cursor in the body on appear: true when the note was just
    /// created from a selection and is still empty.
    var autofocus = false

    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Phase {
        case loading
        case editing(Note)
        /// Deleted here or elsewhere, or never existed.
        case missing
    }

    @State private var phase: Phase = .loading
    @State private var text = ""
    /// The trimmed body as last written, to skip writes that change nothing.
    @State private var savedBody = ""
    /// The body the note had when it was opened; empty for a note just
    /// created, which is what makes an untouched one abandonable.
    @State private var originalBody = ""
    @State private var confirmingDelete = false
    /// Set while the passage is pushed over the editor, so the disappearance
    /// that causes saves but doesn't treat the note as abandoned.
    @State private var openingPassage = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .councilScreenBackground()
            .toolbar { toolbarContent }
            .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await deleteNote() }
                }
            } message: {
                Text("What you wrote will be removed. The passage itself is untouched.")
            }
            .task(id: model.annotations != nil) { await load() }
            // Write a moment after typing pauses. Restarted, and the pending
            // write cancelled, by every keystroke.
            .task(id: text) {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                save()
            }
            .onChange(of: model.annotationsRevision) { _, _ in
                Task { await checkStillExists() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { save() }
            }
            .onAppear { openingPassage = false }
            .onDisappear { commit() }
    }

    private var title: String {
        if case .editing(let note) = phase, let reference = note.reference, !reference.isEmpty {
            return reference
        }
        return "Note"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .missing:
            ContentUnavailableView("Note Deleted", systemImage: "note.text",
                                   description: Text("This note is no longer in your library."))
        case .editing(let note):
            VStack(alignment: .leading, spacing: 0) {
                if let quote = note.quote, !quote.isEmpty {
                    quotation(quote, note: note)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }
                editor
            }
        }
    }

    /// The passage the note is about: the corpus's words, so read-only, and
    /// a way back to them.
    private func quotation(_ quote: String, note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Capped, because a note about nine verses should still leave room
            // to write. The whole passage is a tap away.
            Text(quote)
                .foregroundStyle(palette.text)
                .lineSpacing(3)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 8)
                .textSelection(.enabled)
            let provenance = [note.reference, note.sourceTitle]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            if !provenance.isEmpty {
                Text(provenance)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
            }
            if let unitID = note.contentUnitId {
                NavigationLink(value: ReadingRoute.passage(id: unitID)) {
                    Label("Open Passage", systemImage: "text.quote")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .simultaneousGesture(TapGesture().onEnded {
                    openingPassage = true
                    save()
                })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.surface, in: .rect(cornerRadius: 12))
        // A rule down the leading edge, as a block quotation is set.
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(.tint)
                .frame(width: 3)
        }
        .accessibilityElement(children: .contain)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .focused($bodyFocused)
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(palette.text)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            #if os(iOS)
            .textInputAutocapitalization(.sentences)
            #endif
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    // TextEditor has no placeholder; this sits where its first
                    // line starts and lets taps through.
                    Text("Your thoughts on this passage…")
                        .foregroundStyle(palette.secondaryLabel)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Note")
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .editing(let note) = phase {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: shareText(note)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// The quotation with its reference, then what the reader wrote.
    private func shareText(_ note: Note) -> String {
        var parts: [String] = []
        if let quote = note.quote, !quote.isEmpty {
            parts.append("“\(quote)”")
            let provenance = [note.reference, note.sourceTitle]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: ", ")
            if !provenance.isEmpty { parts.append("— \(provenance)") }
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Data

    private func load() async {
        guard let store = model.annotations else { return }
        // Only the first time: once editing, the field is the truth, and
        // re-reading after our own writes would move the cursor.
        guard case .loading = phase else { return }
        do {
            guard let note = try await store.note(id: noteID) else {
                phase = .missing
                return
            }
            text = note.body
            savedBody = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            originalBody = note.body
            phase = .editing(note)
            if autofocus { bodyFocused = true }
        } catch {
            phase = .missing
        }
    }

    /// Notices the note being deleted somewhere else (the Notes list beside
    /// this on an iPad, say), so the editor stops writing to it.
    private func checkStillExists() async {
        guard case .editing = phase, let store = model.annotations else { return }
        // Only a read that succeeded and found nothing: a failed read says
        // nothing about the note.
        do {
            if try await store.note(id: noteID) == nil { phase = .missing }
        } catch {}
    }

    /// Write the body if it has changed. Unstructured, so a write started as
    /// the screen goes away still finishes.
    private func save() {
        guard case .editing = phase, let store = model.annotations else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body != savedBody else { return }
        savedBody = body
        let id = noteID
        Task { try? await store.updateNoteBody(id: id, body: body) }
    }

    /// The screen is going away: save, or remove a note that was created by
    /// opening it and never written in.
    private func commit() {
        guard case .editing = phase, let store = model.annotations else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && originalBody.isEmpty && !openingPassage {
            phase = .missing
            let id = noteID
            Task { try? await store.deleteNote(id: id) }
        } else {
            save()
        }
    }

    private func deleteNote() async {
        guard let store = model.annotations else { return }
        phase = .missing
        try? await store.deleteNote(id: noteID)
        dismiss()
    }
}

#Preview {
    NavigationStack { NoteEditorView(noteID: 1) }
        .environment(AppModel())
}
