// Ported from lib/src/services/updates/app_version.dart, held to it by
// shared/golden/updates/updates.json (`UpdatesGoldenTests`).

import Foundation

/// A Council version: the release date, then the build counter.
///
/// `2026.8.2+7` is the second of August 2026, build 7. It is parsed into
/// numbers because comparing the strings is wrong in a way that only shows up
/// later: `"2026.8.2" < "2026.8.10"` is false, so a string comparison would
/// decide the tenth is *older* than the second and every reader would stop
/// being offered updates for the rest of that month (the Dart's own warning).
///
/// The date parts are compared first and the build only breaks a tie, so a
/// rebuild of the same day (`+7` → `+8`) is still an update.
public struct AppVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    /// The dotted parts, most significant first: year, month, day.
    public let parts: [Int]

    /// The counter after the `+`. Zero when a version was written without one:
    /// the manifest states it separately, and a display string like
    /// `2026.8.2` carries no build at all.
    public let build: Int

    public init(_ parts: [Int], build: Int = 0) {
        self.parts = parts
        self.build = build
    }

    /// What the running build is taken to be when the platform reports a
    /// version this can't read. Treating it as impossibly new means no release
    /// ever looks newer, so the app says nothing rather than offering an update
    /// forever (`UpdateService.currentVersion`'s fallback in the Dart).
    public static let impossiblyNew = AppVersion([99999])

    /// Parses `2026.8.2`, `2026.8.2+7`, or either with a leading `v` (release
    /// tags are written `v2026.8.2`). Nil on anything else rather than
    /// throwing: this reads a manifest off the network and whatever the bundle
    /// reports, and neither is worth failing a launch over.
    ///
    /// An explicit `build` wins over one spliced into the text, as in the Dart:
    /// the bundle reports the version and the build as two fields, and that
    /// pair is more trustworthy than anything in the name.
    ///
    /// Number parsing is Dart's `int.tryParse`, quirks included, so both apps
    /// read the one `updates.json` alike (`DartInt`, shared with the shelf):
    /// surrounding whitespace is allowed, a sign is allowed, and `0x1A` is
    /// hexadecimal. The text is
    /// split at the *first* `+`, so `2026.+8.2` is unreadable and `2026.8.2+7+1`
    /// has build 0 (the golden fixture pins both).
    public init?(parsing raw: String?, build: Int? = nil) {
        guard let raw else { return nil }
        var text = Substring(DartText.trimmed(raw))
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        if text.isEmpty { return nil }

        var parsedBuild = build ?? 0
        if let plus = text.firstIndex(of: "+") {
            parsedBuild = build ?? (DartInt.tryParse(String(text[text.index(after: plus)...])) ?? 0)
            text = text[..<plus]
        }

        var parts: [Int] = []
        // Dart's `split('.')` keeps empty pieces ("2026..2" → three), and an
        // empty piece then fails to parse, which is the point.
        for segment in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = DartInt.tryParse(String(segment)), value >= 0 else {
                return nil
            }
            parts.append(value)
        }
        if parts.isEmpty { return nil }
        self.init(parts, build: parsedBuild)
    }

    /// The version as a reader sees it, without the build counter.
    public var name: String { parts.map(String.init).joined(separator: ".") }

    /// `2026.8.2+7`, or just the name when the build is zero (Dart's
    /// `toString`).
    public var description: String { build == 0 ? name : "\(name)+\(build)" }

    /// Compared over the longer of the two, treating a missing part as zero, so
    /// `2026.8` and `2026.8.0` are the same version rather than one being
    /// mysteriously older.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.compare(rhs) < 0
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.compare(rhs) == 0
    }

    /// Hashed with trailing zero parts dropped, for the same reason `compare`
    /// pads: equal versions have to hash alike.
    public func hash(into hasher: inout Hasher) {
        var significant = parts[...]
        while significant.last == 0 { significant = significant.dropLast() }
        hasher.combine(Array(significant))
        hasher.combine(build)
    }

    /// Dart's `compareTo`: negative, zero or positive.
    public func compare(_ other: AppVersion) -> Int {
        for i in 0..<max(parts.count, other.parts.count) {
            let mine = i < parts.count ? parts[i] : 0
            let theirs = i < other.parts.count ? other.parts[i] : 0
            if mine != theirs { return mine < theirs ? -1 : 1 }
        }
        return build == other.build ? 0 : (build < other.build ? -1 : 1)
    }

    /// The running build's version, from the bundle's
    /// `CFBundleShortVersionString` and `CFBundleVersion` (project.yml's
    /// MARKETING_VERSION and CURRENT_PROJECT_VERSION), the pair Dart reads
    /// through package_info_plus. `impossiblyNew` if the bundle says something
    /// unreadable.
    public static func running(in bundle: Bundle = .main) -> AppVersion {
        let info = bundle.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String
        let build = (info?["CFBundleVersion"] as? String).flatMap(DartInt.tryParse)
        return AppVersion(parsing: release, build: build) ?? .impossiblyNew
    }
}
