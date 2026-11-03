import SwiftUI

struct NotesView: View {
    var body: some View {
        ContentUnavailableView("Notes", systemImage: "note.text", description: Text("Your highlights and notes will appear here."))
            .navigationTitle("Notes")
            .councilScreenBackground()
    }
}

#Preview {
    NavigationStack { NotesView() }
}
