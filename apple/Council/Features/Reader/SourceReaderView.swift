import SwiftUI

/// Read a work straight through: every section in one continuous scroll.
/// Mirrors `SourceReaderScreen` in lib/src/screens/source_reader_screen.dart,
/// which pages one section at a time; see apple/PLAN.md, Phase 3, for why this
/// one scrolls.
struct SourceReaderView: View {
    let sourceID: Int
    let title: String
    /// Open at the section holding this unit. Takes precedence over the saved
    /// reading position.
    var initialUnitID: Int?

    var body: some View {
        // TODO(Phase 3): the reader.
        ContentUnavailableView(title, systemImage: "book")
            .navigationTitle(title)
            .councilScreenBackground()
    }
}
