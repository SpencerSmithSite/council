import Foundation

/// Paths into the repository, for tests that read files shared with the
/// Flutter app: the golden fixtures in shared/golden/, the bundled corpus and
/// the model in assets/.
///
/// Read in place rather than copied into the test bundle, so a regenerated
/// fixture is what the next test run sees, with no copy to fall out of date.
enum Repo {
    /// The repository root: the nearest ancestor of this file that holds
    /// pubspec.yaml. Walked up to rather than counted, so moving the test
    /// folder doesn't silently point every fixture somewhere else.
    static let root: URL = {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "pubspec.yaml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("No pubspec.yaml above \(#filePath); tests must run from a repository checkout")
    }()

    static func golden(_ path: String) -> URL {
        root.appending(path: "shared/golden").appending(path: path)
    }

    static func asset(_ path: String) -> URL {
        root.appending(path: "assets").appending(path: path)
    }
}
