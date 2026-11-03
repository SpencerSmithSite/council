import Foundation
import GRDB

/// The bundled core corpus (assets/theology.db.gz) that the search golden
/// fixtures were generated against, unpacked once per test run into a
/// temporary file and opened read-only.
enum GoldenCorpus {
    static let database: DatabaseQueue = {
        let source = Repo.asset("theology.db.gz")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CouncilCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = directory.appending(path: "theology.db")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            let gunzip = Process()
            gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
            gunzip.arguments = ["-c", source.path]
            gunzip.standardOutput = output
            try gunzip.run()
            gunzip.waitUntilExit()
            guard gunzip.terminationStatus == 0 else {
                fatalError("gunzip \(source.path) exited with \(gunzip.terminationStatus)")
            }

            var configuration = Configuration()
            configuration.readonly = true
            return try DatabaseQueue(path: destination.path, configuration: configuration)
        } catch {
            fatalError("Could not unpack and open \(source.path): \(error)")
        }
    }()
}
