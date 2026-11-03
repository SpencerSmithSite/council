import SwiftUI

struct BrowseView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Browse", systemImage: "square.grid.2x2", description: Text("Browse the corpus by tradition, era and author."))
                .navigationTitle("Browse")
                .settingsToolbar()
        }
    }
}

#Preview {
    BrowseView()
}
