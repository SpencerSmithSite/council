// Ported from lib/src/services/updates/release_manifest.dart, held to it by
// shared/golden/updates/updates.json (`UpdatesGoldenTests`).

import Foundation

/// How a platform gets a new version.
public enum ReleaseDelivery: String, Sendable, Hashable {
    /// The app fetches the installer itself: the Mac (and, in the Flutter app,
    /// Android, Windows and Linux).
    case download
    /// The app can only send the reader somewhere: TestFlight or the App Store
    /// on iOS and iPadOS, where an app may not install anything, itself
    /// included.
    case store
}

/// One platform's current release, as published in `updates.json`.
public struct PlatformRelease: Sendable, Hashable {
    /// `ios`, `macos`, `android`, `windows` or `linux`: the manifest's key,
    /// matched against `ReleaseManifest.currentPlatform`.
    public let platform: String
    public let delivery: ReleaseDelivery
    public let url: URL
    public let version: AppVersion

    /// Exact size, so a download can show real progress and be checked against
    /// free disk before it starts. Nil for a store release, where the size is
    /// Apple's business.
    public let bytes: Int?

    /// Lower-case hex SHA-256 of the installer. Nil only for a store release.
    /// Required for anything downloaded, deliberately without leniency: what
    /// is downloaded gets run with the reader's own privileges, so a release
    /// the app can't verify is one it declines to install.
    public let sha256: String?

    public init(platform: String, delivery: ReleaseDelivery, url: URL, version: AppVersion,
                bytes: Int? = nil, sha256: String? = nil) {
        self.platform = platform
        self.delivery = delivery
        self.url = url
        self.version = version
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Size in whole megabytes (MiB, rounded down), for telling a reader what
    /// they are about to pull down. Zero when unknown.
    public var megabytes: Int { (bytes ?? 0) / (1024 * 1024) }

    /// The file the download is written as, taken from the URL so a `.dmg`
    /// stays a `.dmg`: the system decides what to do with a file by its
    /// extension.
    ///
    /// Reduced to one harmless path component, because the URL's last segment
    /// is percent-decoded and `%2e%2e%2f…` would otherwise name a place outside
    /// the staging directory, written *before* the checksum that would have
    /// rejected it ran (the Dart's `_safeFileName`). Only the last component,
    /// whichever separator; anything outside `[A-Za-z0-9._-]` becomes `_`, one
    /// per UTF-16 code unit as Dart's regular expression replaces; leading dots
    /// go, so the result names neither a directory nor a hidden file.
    public var fileName: String {
        // Dart's `Uri.pathSegments.last`: the percent-encoded path split on
        // "/" (an empty last segment for a trailing slash, none for no path),
        // then decoded.
        let path = url.path(percentEncoded: true)
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(path.hasPrefix("/") ? 1 : 0)
        let last = segments.last.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
        return Self.safeFileName(last)
    }

    static func safeFileName(_ candidate: String) -> String {
        let base = candidate.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""
        var cleaned = [UInt16]()
        for unit in base.utf16 {
            switch unit {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D: cleaned.append(unit)
            default: cleaned.append(0x5F)
            }
        }
        let trimmed = cleaned.drop { $0 == 0x2E }
        return trimmed.isEmpty ? "Council-update" : String(decoding: trimmed, as: UTF16.self)
    }
}

/// Why `updates.json` couldn't be used.
public struct ReleaseManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
}

/// The published state of every platform, fetched from the site.
///
/// Exists because the Mac app is a direct download (a Developer ID DMG, no Mac
/// App Store), so nothing else tells a reader a new build exists.
public struct ReleaseManifest: Sendable {
    /// The release-wide version. A platform may override it, for when one
    /// store is behind the rest.
    public let version: AppVersion

    /// One line on what changed. Nil when the release didn't say.
    public let notes: String?

    /// The download page, for a reader who would rather do it by hand.
    public let page: URL?

    public let platforms: [String: PlatformRelease]

    public init(version: AppVersion, platforms: [String: PlatformRelease], notes: String? = nil, page: URL? = nil) {
        self.version = version
        self.platforms = platforms
        self.notes = notes
        self.page = page
    }

    /// The manifest key for the platform this build runs on. Both iPhone and
    /// iPad read `ios`, as the Flutter app does on either.
    public static var currentPlatform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    public func forCurrentPlatform() -> PlatformRelease? {
        platforms[Self.currentPlatform]
    }

    /// Parses the body of `updates.json`. Throws on anything it can't trust.
    ///
    /// Strict on purpose, and in exactly the Dart's places, since both apps
    /// read the one file:
    ///
    /// - No usable version, no `platforms` object, or no usable platform at
    ///   all: the whole manifest fails.
    /// - An entry that isn't an object, has an unknown `kind`, a URL that
    ///   isn't https with a host, or (for a download) no positive integer
    ///   `bytes` or no 64-hex-digit `sha256`: that entry is dropped and the
    ///   others stand, so adding a delivery route later doesn't stop older
    ///   builds checking at all.
    /// - A string field holding some other type (`version`, `notes`, `url`, or
    ///   an entry's `url`, `sha256`, `version` once reached): the whole
    ///   manifest fails, because Dart's `as String?` throws there rather than
    ///   skipping the entry.
    /// - `build` and `bytes` count only as JSON integers; `7.0` is ignored, as
    ///   Dart's `is int` ignores it.
    public static func parse(_ data: Data) throws -> ReleaseManifest {
        let json: OrderedJSON
        do {
            json = try OrderedJSON.parse(data)
        } catch {
            throw ReleaseManifestError(description: "The update manifest is not JSON.")
        }
        guard case .object = json else {
            throw ReleaseManifestError(description: "The update manifest is not a JSON object.")
        }
        return try parse(object: json)
    }

    static func parse(object json: OrderedJSON) throws -> ReleaseManifest {
        let build = integer(json["build"])
        guard let version = AppVersion(parsing: try string(json["version"], "version"), build: build) else {
            throw ReleaseManifestError(description: "The update manifest has no usable version.")
        }

        guard case .object(let members)? = json["platforms"] else {
            throw ReleaseManifestError(description: "The update manifest lists no platforms.")
        }

        var platforms: [String: PlatformRelease] = [:]
        // A repeated key keeps its last value, as `jsonDecode` keeps it.
        var seen = Set<String>()
        for (id, value) in members.reversed() where seen.insert(id).inserted {
            if let release = try release(id: id, value, inheriting: version) {
                platforms[id] = release
            }
        }
        if platforms.isEmpty {
            throw ReleaseManifestError(description: "The update manifest has no platform this build could use.")
        }

        let notes = try string(json["notes"], "notes").map(DartText.trimmed)
        let page = try string(json["url"], "url").flatMap { URL(string: $0) }.flatMap { $0.scheme?.isEmpty == false ? $0 : nil }
        return ReleaseManifest(version: version, platforms: platforms,
                               notes: notes?.isEmpty == false ? notes : nil, page: page)
    }

    /// One entry, or nil to drop it. Checked in the Dart's order, which
    /// matters only for which mistakes fail the whole manifest: a non-string
    /// `sha256` behind a URL that was already rejected is never reached.
    private static func release(id: String, _ value: OrderedJSON, inheriting version: AppVersion) throws -> PlatformRelease? {
        guard case .object = value else { return nil }

        let delivery: ReleaseDelivery
        switch value["kind"] {
        case .string("download")?: delivery = .download
        case .string("store")?: delivery = .store
        default: return nil
        }

        // Only https. For a download this URL ends up as an executable on the
        // reader's machine.
        guard let url = normalisedURL(try string(value["url"], "url") ?? ""),
              url.scheme == "https", let host = url.host(percentEncoded: true), !host.isEmpty else {
            return nil
        }

        let bytes = integer(value["bytes"])
        let sha = try string(value["sha256"], "sha256").map(DartText.lowercased)
        if delivery == .download {
            guard let bytes, bytes > 0 else { return nil }
            guard let sha, sha.utf8.count == 64,
                  sha.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
                return nil
            }
        }

        let ownVersion = AppVersion(parsing: try string(value["version"], "version"), build: integer(value["build"]))
        return PlatformRelease(platform: id, delivery: delivery, url: url, version: ownVersion ?? version,
                               bytes: bytes, sha256: sha)
    }

    /// `URL(string:)` with the scheme and host lower-cased, as Dart's
    /// `Uri.parse` normalises them, so `HTTPS://Example.COM/…` is accepted and
    /// stored as `https://example.com/…` in both apps.
    private static func normalisedURL(_ text: String) -> URL? {
        guard let url = URL(string: text), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme?.lowercased()
        if let host = components.percentEncodedHost { components.percentEncodedHost = host.lowercased() }
        return components.url
    }

    /// Dart's `x as String?`: nil for absent or null, the string, or a throw.
    private static func string(_ value: OrderedJSON?, _ field: String) throws -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?: return text
        default: throw ReleaseManifestError(description: "The update manifest's \(field) is not text.")
        }
    }

    /// Dart's `x is int ? x : null`.
    private static func integer(_ value: OrderedJSON?) -> Int? {
        if case .int(let number)? = value { return number }
        return nil
    }
}
