import SwiftUI

/// One passage on its own: its text (markable, as in the reader), where it
/// comes from, its tags, a bookmark, and a way into the whole work. Mirrors
/// the single-passage path of `ContentDetailScreen` in
/// lib/src/screens/content_detail_screen.dart.
struct ContentDetailView: View {
    let contentID: Int

    var body: some View {
        // TODO(Phase 3): the passage.
        ContentUnavailableView("Passage", systemImage: "text.quote")
            .navigationTitle("Passage")
            .councilScreenBackground()
    }
}
