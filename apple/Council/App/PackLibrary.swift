import CouncilCore
import Foundation
import Observation
import os

/// The content library as the screens see it: what's installed, what could
/// be, and the one install in flight. Mirrors `PackProvider` in
/// lib/src/services/packs/pack_provider.dart.
///
/// Phase 5's chat uses it for the coverage notice (a collection that would
/// have helped isn't installed, with a button to add it); Phase 6's Browse
/// builds on it.
///
/// Two sources, kept apart as Flutter keeps them. The *catalogue*
/// (`pack_catalogue.json`, bundled) says what every pack holds, so the app can
/// say what it is missing on first launch, offline, before anyone opens
/// Browse. The *manifest* is fetched from the network only when a collection
/// is actually wanted, so a gap can always be described even when the fix
/// can't be offered yet.
@Observable @MainActor
final class PackLibrary {
    /// The bundled description of every pack. Nil only for a broken bundle,
    /// in which case no gaps are ever reported.
    let catalogue: PackCatalogue?

    private(set) var manifest: PackManifest?
    private(set) var installed: Set<String> = []
    /// Installed collection id -> its name, from the local record. What Browse
    /// lists when the manifest can't be fetched, so an offline reader can
    /// still see and remove what they have.
    private(set) var installedNames: [String: String] = [:]
    /// Fragments physically present, as opposed to collections the reader
    /// chose.
    private(set) var installedFragments: Set<String> = []
    private(set) var error: String?
    private(set) var loading = false
    /// The collection downloading, and its progress in 0...1.
    private(set) var busyID: String?
    private(set) var progress: Double = 0

    @ObservationIgnored private var service: PackService?

    private static let logger = Logger(subsystem: "site.spencersmith.council", category: "Packs")

    init(bundle: Bundle = .main) {
        do {
            guard let url = bundle.url(forResource: "pack_catalogue", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            catalogue = try PackCatalogue.load(from: url)
        } catch {
            Self.logger.error("Pack catalogue unavailable: \(String(describing: error), privacy: .public)")
            catalogue = nil
        }
    }

    /// Hands over the service once the corpus is open, and loads what is
    /// installed. No network: the coverage notice has to work offline.
    func attach(_ service: PackService) async {
        self.service = service
        attached = true
        await loadInstalled()
    }

    /// Whether the service has been handed over, so screens can wait for it
    /// (`.task(id:)`) rather than refreshing into nothing on a cold launch.
    private(set) var attached = false

    func loadInstalled() async {
        guard let service else { return }
        do {
            installed = try await service.installedCollections()
            installedFragments = try await service.installedFragments()
            installedNames = try await service.installedCollectionNames()
        } catch {
            Self.logger.error("Couldn't read installed packs: \(String(describing: error), privacy: .public)")
        }
    }

    /// Which uninstalled collections would have helped answer `question`.
    ///
    /// The app can only search text it holds, so without this a library
    /// missing the fathers answers a question about the Eucharist from
    /// confessions alone: fluent, well cited, and drawn from under a tenth of
    /// what exists.
    func coverageGaps(for question: String, tags: [String]) -> [PackSuggestion] {
        catalogue?.suggest(question: question, queryTags: tags, installedFragments: installedFragments) ?? []
    }

    /// A pack's name for a notice that names it, or its id.
    func name(of packID: String) -> String {
        let name = catalogue?.name(of: packID) ?? ""
        return name.isEmpty ? packID : name
    }

    /// The collection with this id, once the manifest has been fetched.
    func collection(_ id: String) -> PackCollection? {
        manifest?.collection(id)
    }

    /// What this collection would cost to add now. Zero is a real and common
    /// answer: someone holding "Church Fathers" already has every fragment
    /// "Augustine of Hippo" needs.
    func bytesToInstall(_ collection: PackCollection) -> Int {
        manifest?.bytesToInstall(collection, installedFragments: installedFragments) ?? 0
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains(id)
    }

    /// Loads what is installed, then what is available. Installed packs come
    /// from the local database and stand even when the fetch fails, and so
    /// does a manifest fetched earlier: as in Flutter, a failed refresh only
    /// adds the error.
    ///
    /// Skipped while another refresh is in flight (Browse refreshes on
    /// appear and on pull, and the two can overlap). A refresh whose task was
    /// cancelled (the screen went away mid-fetch) reports nothing: the
    /// reader didn't see it fail, they left.
    func refresh() async {
        guard let service, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        await loadInstalled()
        do {
            manifest = try await service.fetchManifest()
        } catch {
            if Task.isCancelled { return }
            self.error = "Could not load the list of available content. \(error.localizedDescription)"
        }
    }

    /// Installs `collection`. Afterwards `error` says why if it failed.
    func install(_ collection: PackCollection) async {
        guard let service, let manifest, busyID == nil else { return }
        busyID = collection.id
        progress = 0
        error = nil
        defer {
            busyID = nil
            progress = 0
        }
        do {
            try await service.install(collection, from: manifest) { received, total in
                guard total > 0 else { return }
                let next = Double(received) / Double(total)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Every chunk would redraw hundreds of times a second
                    // for no visible gain.
                    if next - self.progress >= 0.01 || next >= 1 { self.progress = next }
                }
            }
            await loadInstalled()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Removes the collection with this id, keeping any fragment another
    /// installed collection still needs. Afterwards `error` says why if it
    /// failed. `PackProvider.uninstall` in Dart.
    ///
    /// Takes an id rather than a `PackCollection` because removal reads only
    /// the local record (`PackService.uninstall`), so it works offline, when
    /// Browse has no manifest to take a collection from.
    ///
    /// The installed sets are reloaded here, not left to
    /// `AppModel.contentRevision`: the service announces a change only when
    /// text actually left the corpus, and removing a collection whose
    /// fragments another one still needs removes none, yet it is no longer
    /// installed.
    func uninstall(_ id: String) async {
        guard let service, busyID == nil else { return }
        busyID = id
        error = nil
        defer { busyID = nil }
        do {
            try await service.uninstall(id)
        } catch {
            self.error = error.localizedDescription
        }
        await loadInstalled()
    }
}
