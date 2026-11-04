import CouncilCore
import SwiftUI

/// "A collection that would help with this isn't installed", above the
/// composer after an answer, with a button to add it. Mirrors
/// `_CoverageNotice` in lib/src/screens/chat_screen.dart.
///
/// It belongs to the composer, not the transcript: it is about the question
/// just asked, not about what has been said. Installing the collection asks
/// that question again (`ChatSession.answerAgainAfterInstall`).
///
/// The gap is described from the bundled catalogue, so it works offline; the
/// manifest that says how to fetch the collection is a network call made only
/// when Add is tapped. Flutter's second button, "Browse library", pushes the
/// pack library (`BrowseView`).
struct CoverageNotice: View {
    let gap: PackSuggestion
    /// Called once the collection is installed.
    let onInstalled: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.councilPalette) private var palette

    @State private var busy = false
    @State private var error: String?

    private var library: PackLibrary { model.packLibrary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gap.explanation)
                        .foregroundStyle(palette.text)
                    Text("This answer draws only on what you have installed.")
                        .foregroundStyle(palette.secondaryLabel)
                    if let error {
                        Text(error)
                            .foregroundStyle(palette.error)
                            .padding(.top, 2)
                    }
                }
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(palette.secondaryLabel)
            }
            .font(.footnote)

            if busy {
                VStack(alignment: .leading, spacing: 6) {
                    if library.progress > 0 {
                        ProgressView(value: library.progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("Downloading — your question will be answered again automatically.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
            } else {
                // Side by side where they fit, Browse Library first as in
                // Flutter; stacked, trailing, where they don't (the size on the
                // Add button can be long), so neither is truncated.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        browseLink
                        addButton
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        addButton
                        browseLink
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(palette.surface, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var addButton: some View {
        Button(addLabel, systemImage: "plus.circle") {
            Task { await install() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    /// Flutter's "Browse library": the whole pack library, pushed onto the
    /// Ask tab's stack, for a reader who wants something other than the one
    /// collection suggested.
    private var browseLink: some View {
        NavigationLink {
            BrowseView()
        } label: {
            Text("Browse Library")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// "Add Church Fathers · 120 MB": the size is on the button because this
    /// is an unsolicited suggestion to spend someone's data. Without a
    /// manifest yet, the name alone.
    private var addLabel: String {
        let name = library.name(of: gap.packID)
        guard let collection = library.collection(gap.packID) else { return "Add \(name)" }
        let bytes = library.bytesToInstall(collection)
        return "Add \(name) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func install() async {
        busy = true
        error = nil
        // The manifest, the first time it is needed.
        if library.manifest == nil { await library.refresh() }
        guard let collection = library.collection(gap.packID) else {
            busy = false
            error = "That collection could not be reached."
            return
        }
        await library.install(collection)
        if let failure = library.error {
            busy = false
            error = failure
            return
        }
        onInstalled()
    }
}
