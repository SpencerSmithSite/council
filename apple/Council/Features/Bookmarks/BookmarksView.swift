import CouncilCore
import SwiftUI

/// The passages the reader has bookmarked, newest first. Mirrors
/// `BookmarksScreen` in lib/src/screens/bookmarks_screen.dart.
///
/// Flutter removes a bookmark with a trash button on each row and no
/// question asked, then says so in a snack bar; here it is the standard swipe
/// (or the context menu), which says it by itself. No confirmation, as in
/// Flutter: a bookmark is one tap to put back from the passage, unlike a note.
///
/// Changes go through `AppModel` so `bookmarksRevision` moves and the reader's
/// bookmark button, if it is showing the same passage, agrees.
struct BookmarksView: View {
    @Environment(AppModel.self) private var model

    /// Nil until the first load.
    @State private var bookmarks: [Bookmark]?

    var body: some View {
        content
            .navigationTitle("Bookmarks")
            .councilScreenBackground()
            // Reloads after every bookmark change, wherever it was made.
            .task(id: model.bookmarksRevision) {
                bookmarks = model.bookmarks.bookmarks()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let bookmarks {
            if bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks Yet", systemImage: "bookmark",
                                       description: Text("Tap the bookmark button on any passage to save it here."))
            } else {
                List(bookmarks) { bookmark in
                    NavigationLink(value: ReadingRoute.passage(id: bookmark.contentId)) {
                        BookmarkRow(bookmark: bookmark)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            remove(bookmark)
                        } label: {
                            Label("Remove", systemImage: "bookmark.slash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            remove(bookmark)
                        } label: {
                            Label("Remove Bookmark", systemImage: "bookmark.slash")
                        }
                    }
                    .councilListRow()
                }
            }
        } else {
            ProgressView()
        }
    }

    private func remove(_ bookmark: Bookmark) {
        // Out of the list first, so the row animates away with the swipe; the
        // revision bump then reloads the same list from the store.
        withAnimation { bookmarks?.removeAll { $0.contentId == bookmark.contentId } }
        model.removeBookmark(contentID: bookmark.contentId)
    }
}

/// A bookmark: the passage's title, its work, and the opening words.
private struct BookmarkRow: View {
    let bookmark: Bookmark
    @Environment(\.councilPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bookmark.title)
                .font(.headline)
                .foregroundStyle(palette.text)
                .lineLimit(2)
            if !bookmark.source.isEmpty {
                Text(bookmark.source)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
            }
            if let preview = bookmark.preview, !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { BookmarksView() }
        .environment(AppModel())
}
