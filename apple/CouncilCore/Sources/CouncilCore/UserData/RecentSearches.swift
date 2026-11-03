import Foundation

/// The searches the reader ran lately, newest first, for the Search tab to
/// offer again, as the system's own search screens do.
///
/// Native-only (the Flutter Read tab keeps none), so the key `recent_searches`
/// has no Flutter counterpart and nothing for Phase 7 to migrate. A plain
/// string array in `UserDefaults`, like the shelf's sets.
public struct RecentSearches: Sendable {
    public static let key = "recent_searches"
    /// Enough to find last week's search again; more is a list to scroll.
    public static let limit = 8

    // UserDefaults is documented thread-safe but isn't `Sendable` in this
    // SDK; see `BookmarkStore`.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Puts `query` at the top. The same search typed in another case
    /// replaces the old entry rather than sitting beside it.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }

    public func remove(_ query: String) {
        defaults.set(all().filter { $0 != query }, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
