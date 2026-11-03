import SwiftUI

struct BookmarksView: View {
    var body: some View {
        ContentUnavailableView("Bookmarks", systemImage: "bookmark", description: Text("Saved passages will appear here."))
            .navigationTitle("Bookmarks")
    }
}

#Preview {
    NavigationStack { BookmarksView() }
}
