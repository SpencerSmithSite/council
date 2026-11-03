import CouncilCore
import SwiftUI

extension View {
    /// The actions on a passage selection, for a screen showing `PassageText`:
    /// the system toolbar while something is selected (a bottom bar on iPhone
    /// and iPad, window toolbar items on the Mac) and the note editor sheet
    /// that "Note" opens. Shared by the reader and the passage screen.
    ///
    /// The toolbar is Flutter's `PassageActionBar` (lib/src/reader/
    /// passage_action_bar.dart) as system chrome: Flutter drew a floating pill
    /// of its own; here the bar is the platform's Liquid Glass toolbar and the
    /// palette a menu rather than a sheet. The count ("3 verses selected") is
    /// the screen's navigation subtitle while the selection lasts, as Photos
    /// and Files show their count in the title in select mode: on an iPhone
    /// the bottom bar has room for the clear button and the five actions, and
    /// with the count as well it folds Highlight, Note and Ask into an
    /// overflow menu. Screens read it from `PassageSelection.subtitle`.
    func passageActions(_ selection: PassageSelection) -> some View {
        modifier(PassageActionsModifier(selection: selection))
    }
}

private struct PassageActionsModifier: ViewModifier {
    let selection: PassageSelection
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var selection = selection

        content
            .toolbar {
                if !selection.isEmpty {
                    #if os(iOS)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear Selection", systemImage: "xmark") {
                            withAnimation { selection.clear() }
                        }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItemGroup(placement: .bottomBar) {
                        PassageActionButtons(selection: selection, store: model.annotations)
                    }
                    #else
                    ToolbarItemGroup(placement: .primaryAction) {
                        PassageActionButtons(selection: selection, store: model.annotations)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear Selection", systemImage: "xmark") { selection.clear() }
                            .keyboardShortcut(.cancelAction)
                    }
                    #endif
                }
            }
            .sheet(item: $selection.editingNote) { note in
                NoteSheet(noteID: note.id)
            }
    }
}

/// Copy, Share, Highlight, Note, Ask: the same actions, in the same order, as
/// the context menu.
private struct PassageActionButtons: View {
    let selection: PassageSelection
    let store: AnnotationStore?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            selection.copy()
        }

        ShareLink(item: selection.shareText,
                  subject: Text(selection.reference.isEmpty ? "From Council" : selection.reference)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Menu {
            Picker("Highlight Colour", selection: colourChoice) {
                ForEach(HighlightColour.allCases) { colour in
                    // A palette picker colours each swatch with its tint.
                    Label(colour.label, systemImage: "circle.fill")
                        .tint(colour.color(dark: colorScheme == .dark))
                        .tag(Optional(colour))
                }
            }
            .pickerStyle(.palette)
            .disabled(store == nil)

            if selection.hasHighlight {
                Button("Remove Highlight", systemImage: "eraser", role: .destructive) {
                    selection.removeHighlight(store: store)
                }
                .disabled(store == nil)
            }
        } label: {
            Label("Highlight", systemImage: "highlighter")
        }

        Button("Note", systemImage: "note.text.badge.plus") {
            selection.note(store: store)
        }
        .disabled(store == nil)

        // TODO(Phase 5): pin the passage and open Ask with it. Shown now,
        // disabled, so the bar has its final shape and nothing pretends to work.
        Button("Ask", systemImage: "sparkles") {}
            .disabled(true)
    }

    /// The palette has no "current" colour (a selection can span several
    /// marks, or none), so it reads as unset and picking a colour applies it.
    private var colourChoice: Binding<HighlightColour?> {
        Binding(get: { nil }, set: { colour in
            if let colour { selection.highlight(colour, store: store) }
        })
    }
}

/// The note just made from a selection, in the editor, in its own stack with
/// a Done button, as Flutter pushes `NoteEditorScreen(autofocus: true)`.
private struct NoteSheet: View {
    let noteID: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NoteEditorView(noteID: noteID, autofocus: true)
                // The editor's "Open Passage" pushes inside this stack.
                .readingDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}
