import SwiftUI

/// One note: the quotation it was taken from, which can't be edited, and the
/// reader's own words, which save as they're typed. Mirrors
/// `NoteEditorScreen` in lib/src/screens/note_editor_screen.dart.
///
/// Pushed from the Notes list, and presented in a sheet (inside its own
/// `NavigationStack`) by the reader straight after "Note" creates one.
struct NoteEditorView: View {
    let noteID: Int
    /// Put the cursor in the body on appear: true when the note was just
    /// created from a selection and is still empty.
    var autofocus = false

    var body: some View {
        // TODO(Phase 3): the editor.
        ContentUnavailableView("Note", systemImage: "note.text")
            .navigationTitle("Note")
            .councilScreenBackground()
    }
}
