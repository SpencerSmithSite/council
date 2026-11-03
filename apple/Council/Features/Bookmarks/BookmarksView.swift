import SwiftUI

struct BookmarksView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Bookmarks", systemImage: "bookmark", description: Text("Saved passages will appear here."))
                .navigationTitle("Bookmarks")
                .settingsToolbar()
        }
    }
}

#Preview {
    BookmarksView()
}
