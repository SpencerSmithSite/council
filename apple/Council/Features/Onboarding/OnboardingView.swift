import CouncilCore
import SwiftUI

/// First-run setup: the native counterpart of `OnboardingScreen`
/// (lib/src/screens/onboarding_screen.dart), presented over the app by
/// `onboardingPresentation()` while `OnboardingGate` says the reader is new.
///
/// The same three steps hand the reader the three choices the app is built
/// around, in Flutter's order and with its wording:
///
/// 1. **Scripture** (`OnboardingScriptureStep`): the King James is already
///    here; the other public-domain translations are offered, never forced.
/// 2. **The library** (`OnboardingLibraryStep`): the essential and era
///    collections, with Creeds & Confessions preselected and marked "Start
///    here".
/// 3. **Answers** (`OnboardingAnswersStep`): where answers come from, opening
///    on the private backend the device can offer, with search-only one tap
///    away.
///
/// Then, if anything was chosen, a fourth page (`OnboardingDownloadsStep`)
/// follows the downloads in place of Flutter's blocking "Downloading …"
/// screen. Nothing downloads until Get Started, so the reader sees the total
/// first, and every step can be skipped: the app works on Scripture alone,
/// offline, with no AI.
///
/// A `NavigationStack` pages through the steps, as Apple's own setup flows
/// do: Continue pushes the next, the system back button (or, on the Mac, a
/// Back button beside Continue) returns. Each step is a grouped `Form` under
/// a large SF Symbol header, with the primary action a `.glassProminent`
/// button in a bottom bar.
///
/// `onFinish` is called once the reader is through it; the presenter closes
/// the sheet there. `has_onboarded` itself is recorded here, through
/// `OnboardingGate.markOnboarded`, at the moment the reader commits (see
/// there for why that is earlier than Flutter).
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @State private var flow = OnboardingFlow()

    var body: some View {
        NavigationStack(path: $flow.path) {
            OnboardingScriptureStep()
                .navigationDestination(for: OnboardingFlow.Step.self) { step in
                    switch step {
                    case .library: OnboardingLibraryStep()
                    case .answers: OnboardingAnswersStep()
                    case .downloads: OnboardingDownloadsStep()
                    }
                }
        }
        .environment(flow)
        .onAppear { flow.onFinish = onFinish }
        // The catalogue needs the pack service, which exists once the corpus
        // is open: on a true first launch that is a moment after this sheet
        // appears.
        .task(id: model.packs != nil) {
            guard let packs = model.packs else { return }
            // `AppModel` attaches the library in a task of its own, which may
            // not have run yet; attaching again only reloads what's installed.
            await model.packLibrary.attach(packs)
            await model.packLibrary.refresh()
            flow.preselect(from: model.packLibrary)
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 640, idealHeight: 720)
        #endif
    }
}

/// What the steps share: the path, the collections chosen so far, and the
/// actions of the bottom bar. Owned by `OnboardingView` for the life of the
/// sheet; the downloads themselves outlive it in `OnboardingGate`.
@Observable @MainActor
final class OnboardingFlow {
    enum Step: Hashable {
        case library, answers, downloads
    }

    var path: [Step] = []

    /// Collections chosen across the first two steps but not yet downloaded.
    /// Collected first and installed on finish, as Flutter's `_chosen`, so
    /// the reader sees the total before committing rather than discovering
    /// it one download at a time.
    var chosen: Set<String> = []

    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var didPreselect = false

    /// Creeds & Confessions, chosen before the reader arrives: the smallest
    /// collection that makes a comparative question answerable at all, which
    /// is what the app is for (Flutter's `initState`). Once per sheet, so a
    /// reader who unticks it isn't overruled by a catalogue retry; and not
    /// when it's already installed (onboarding shown again from Settings),
    /// where it would only add "0 B to download".
    func preselect(from library: PackLibrary) {
        guard !didPreselect, let manifest = library.manifest else { return }
        didPreselect = true
        if let creeds = manifest.collection(Self.startHere), library.bytesToInstall(creeds) > 0 {
            chosen.insert(Self.startHere)
        }
    }

    static let startHere = "creeds-and-confessions"

    func binding(for id: String) -> Binding<Bool> {
        Binding { self.chosen.contains(id) } set: { on in
            if on { self.chosen.insert(id) } else { self.chosen.remove(id) }
        }
    }

    /// The download for everything chosen, over the *union* of their
    /// fragments less what is installed: collections overlap, so summing
    /// their sizes would overstate it (Flutter's `_totalBytes`).
    func totalBytes(in library: PackLibrary) -> Int {
        guard let manifest = library.manifest else { return 0 }
        var fragments = Set<String>()
        for collection in manifest.collections where chosen.contains(collection.id) {
            fragments.formUnion(collection.fragments)
        }
        fragments.subtract(library.installedFragments)
        return fragments.reduce(0) { $0 + (manifest.fragment($1)?.bytes ?? 0) }
    }

    /// "2 selected · 3.4 MB to download", under the button on every step
    /// once anything is chosen, as Flutter's bottom bar.
    func summary(in library: PackLibrary) -> String? {
        guard !chosen.isEmpty else { return nil }
        return String(localized: "\(chosen.count) selected · \(PackManifest.formatBytes(totalBytes(in: library))) to download")
    }

    func next(_ step: Step) {
        path.append(step)
    }

    func back() {
        if !path.isEmpty { path.removeLast() }
    }

    /// Skip, from any step: finish without downloading anything (Flutter's
    /// `_finish(download: false)`). The AI choice already made stands, as in
    /// Flutter, where tapping an option sets it there and then.
    func skip(_ gate: OnboardingGate) {
        gate.markOnboarded()
        onFinish()
    }

    /// Get Started: queue the chosen collections, in manifest order, and
    /// follow them on the downloads page; or, with nothing to fetch, finish.
    func start(_ gate: OnboardingGate, library: PackLibrary) {
        gate.markOnboarded()
        let collections = library.manifest?.collections.filter { chosen.contains($0.id) } ?? []
        guard !collections.isEmpty else {
            onFinish()
            return
        }
        gate.install(collections, with: library)
        path.append(.downloads)
    }
}

// MARK: - The page every step shares

/// One step: a large SF Symbol, a title and a sentence of explanation at the
/// top of a grouped `Form`, then the step's own sections, with the primary
/// action pinned below (Flutter's `_Page` and `_BottomBar`).
///
/// The bar is a `safeAreaBar`, so the form scrolls under it with the system's
/// scroll-edge effect rather than behind a drawn divider.
struct OnboardingPage<Content: View>: View {
    @Environment(\.councilPalette) private var palette
    @Environment(OnboardingFlow.self) private var flow

    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var summary: String?
    let primaryTitle: LocalizedStringKey
    let primary: () -> Void
    /// Nil hides Skip (the downloads page, past the point of choosing).
    var skip: (() -> Void)?
    /// Whether the Mac's Back button shows: every step but the first.
    var showsBack = true
    @ViewBuilder var content: Content

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 54

    var body: some View {
        Form {
            #if os(macOS)
            // The header of an empty section rather than a row, so it sits
            // on the page itself: the Mac's grouped form gives every row a
            // card, whatever `listRowBackground` asks for.
            Section {
            } header: {
                header
                    .textCase(nil)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            #else
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 8))
            }
            #endif
            content
        }
        .formStyle(.grouped)
        .councilScreenBackground(grouped: true)
        // Named for the back button's history menu and VoiceOver; the header
        // says it on the page, so the bar doesn't repeat it.
        .navigationTitle(title)
        #if os(iOS)
        // Inline, or the large title stays drawn whatever `removing` says.
        .navigationBarTitleDisplayMode(.inline)
        // A page with nowhere to go back to has nothing in its bar, which
        // would only push the header down.
        .toolbarVisibility(showsBack ? .automatic : .hidden, for: .navigationBar)
        #else
        // The Mac's Back is in the bottom bar, beside Continue, as in its
        // setup assistants; the sheet's own bar would only repeat it.
        .toolbar(.hidden)
        #endif
        .toolbar(removing: .title)
        .safeAreaBar(edge: .bottom) { bottomBar }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                // Spelled out: as a Mac section header it would otherwise
                // take the header's bold.
                .font(.body.weight(.regular))
                .foregroundStyle(palette.secondaryLabel)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
            }
            #if os(macOS)
            // The Mac's setup assistants put Back and Continue together at the
            // bottom right, with the default button on the right.
            HStack {
                if let skip {
                    Button("Skip", action: skip)
                }
                Spacer()
                if showsBack {
                    Button("Back") { flow.back() }
                        .keyboardShortcut(.cancelAction)
                }
                primaryButton
            }
            .controlSize(.large)
            #else
            primaryButton
                .controlSize(.large)
            if let skip {
                Button("Skip", action: skip)
                    .buttonStyle(.borderless)
            }
            #endif
        }
        .frame(maxWidth: 520)
        // Pinned, so at the largest accessibility sizes it would otherwise
        // take half the screen from the content it sits under.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var primaryButton: some View {
        Button(action: primary) {
            Text(primaryTitle)
                .fontWeight(.semibold)
                #if os(iOS)
                .frame(maxWidth: .infinity)
                #endif
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Collections

/// A collection to tick: its name, what it holds, and what adding it would
/// download now (Flutter's `_Choice`). A `Toggle`, so it is a switch on
/// iPhone and iPad and a switch in the Mac's grouped form, with the
/// selection read by VoiceOver as the switch's value.
struct CollectionToggle: View {
    @Environment(\.councilPalette) private var palette
    let collection: PackCollection
    let bytes: Int
    var recommended = false
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.name)
                    .foregroundStyle(palette.text)
                if !collection.description.isEmpty {
                    Text(collection.description)
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryLabel)
                }
                HStack(spacing: 6) {
                    if recommended {
                        Text("Start here")
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.accent)
                        Text(verbatim: "·").accessibilityHidden(true)
                    }
                    // Zero is a real answer, a collection whose fragments are
                    // already here, but "0 B" reads as a broken size rather
                    // than as good news.
                    Text(bytes == 0 ? String(localized: "Already installed") : PackManifest.formatBytes(bytes))
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        }
        .councilListRow()
    }
}

/// Stands in for a step's collections while the catalogue loads or when it
/// can't be reached (Flutter's `_Body`), so a step that offers downloads
/// still reads, and can be passed, offline.
struct CatalogueStateSection: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.councilPalette) private var palette

    var body: some View {
        let library = model.packLibrary
        Section {
            if let error = library.error, !library.loading {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The catalogue could not be reached. You can add collections later from Browse.")
                        .foregroundStyle(palette.text)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                }
                Button("Try Again", systemImage: "arrow.clockwise") {
                    Task {
                        await library.refresh()
                        flow.preselect(from: library)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading the catalogue…")
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
        }
        .councilListRow()
    }
}
