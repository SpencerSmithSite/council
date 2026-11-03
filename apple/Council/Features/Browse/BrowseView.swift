import SwiftUI

struct BrowseView: View {
    var body: some View {
        ContentUnavailableView("Browse", systemImage: "square.grid.2x2", description: Text("Browse the corpus by tradition, era and author."))
            .navigationTitle("Browse")
            .councilScreenBackground()
    }
}

#Preview {
    NavigationStack { BrowseView() }
}
