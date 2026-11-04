#if os(macOS)
// The macOS tools the in-place installer (`MacUpdateInstaller`) is built from:
// running a command, mounting a disk image, and checking a code signature.

import Foundation
import Security
import Synchronization

/// Runs a command to completion without blocking a thread on it.
struct ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let errorText: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `executable` with `arguments` (passed as they are, never through
    /// a shell), with stdin closed. Kills it after `timeout`.
    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(120)) async throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drained as it arrives: a pipe holds 64 KB, and a process that fills
        // it blocks until someone reads.
        let collected = Mutex((out: Data(), err: Data()))
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.out.append(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.err.append(data) }
        }

        let finished = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw Failure(description: "\(executable) could not start: \(error.localizedDescription)")
        }

        let status = try await withTimeLimit(timeout) {
            var iterator = finished.makeAsyncIterator()
            return await iterator.next() ?? -1
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        guard let status else {
            process.terminate()
            throw Failure(description: "\(executable) did not finish in time")
        }
        let rest = (out.fileHandleForReading.readDataToEndOfFile(), err.fileHandleForReading.readDataToEndOfFile())
        let (output, errorData) = collected.withLock { ($0.out + rest.0, $0.err + rest.1) }
        return Result(status: status, output: output,
                      errorText: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// `hdiutil`, for mounting a downloaded update privately.
enum DiskImage {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Mounts `image` read-only in a fresh folder under `root`, out of sight:
    /// `-nobrowse` keeps it off the desktop and out of the Finder sidebar,
    /// `-noautoopen` stops a Finder window, `-mountrandom` keeps it out of
    /// /Volumes. hdiutil still verifies the image's own checksums. Returns the
    /// mount point.
    static func attach(_ image: URL, under root: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist",
            "-mountrandom", root.path, image.path,
        ])
        guard result.status == 0 else {
            throw Failure(description: "hdiutil attach failed (\(result.status)): \(result.errorText)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw Failure(description: "hdiutil attach gave no description of what it mounted")
        }
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard mounts.count == 1, let mount = mounts.first else {
            // Attached, but not as the one volume an update image has. Undo
            // it by the whole-disk device ("/dev/disk5", the shortest entry),
            // which detaches every slice, mounted or not.
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            if let disk = devices.min(by: { $0.count < $1.count }) {
                await detach(URL(filePath: disk))
            }
            throw Failure(description: "the disk image holds \(mounts.count) volumes, not one")
        }
        return URL(filePath: mount, directoryHint: .isDirectory)
    }

    /// Unmounts, forcing it if a plain detach is refused (Spotlight or
    /// `syspolicyd` can hold a freshly mounted volume for a moment).
    static func detach(_ mount: URL) async {
        for arguments in [["detach", mount.path], ["detach", "-force", mount.path]] {
            if let result = try? await ProcessRunner.run("/usr/bin/hdiutil", arguments, timeout: .seconds(60)),
               result.status == 0 {
                return
            }
        }
    }
}

/// Checks code signatures with Security.framework.
///
/// A protocol so the installer's file handling can be tested with apps that
/// aren't signed by the team (there is no Developer ID certificate on a test
/// machine); `SecurityCodeSigning` is the real one, tested on its own.
public protocol CodeSigning: Sendable {
    /// Throws unless `app` is validly signed, every nested piece of code
    /// included, by a certificate Apple issued to `teamID`, as `identifier`.
    func validate(app: URL, teamID: String, identifier: String) throws

    /// The team that signed `app`, if it is validly signed by an
    /// Apple-issued certificate. Nil for unsigned and ad hoc signed builds
    /// (a development build run from Xcode with signing off).
    func team(of app: URL) -> String?
}

public struct CodeSigningFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
}

public struct SecurityCodeSigning: CodeSigning {
    public init() {}

    /// The requirement a genuine Council must meet. `anchor apple generic`
    /// is what makes the team check mean anything: it demands a chain to
    /// Apple's root, so a self-made certificate that merely *says*
    /// OU=Y2Q5JVG8X5 fails. Apple puts the team ID in the leaf's OU for both
    /// Developer ID and development certificates, so a development build
    /// updating to a Developer ID release passes too.
    static func requirement(teamID: String, identifier: String?) -> String {
        let anchor = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard let identifier else { return anchor }
        return "identifier \"\(identifier)\" and \(anchor)"
    }

    public func validate(app: URL, teamID: String, identifier: String) throws {
        // Quotes would end the requirement string early; neither value ever
        // has one, so refuse rather than escape.
        guard !teamID.contains("\""), !identifier.contains("\"") else {
            throw CodeSigningFailure(description: "unusable team or identifier")
        }
        let code = try staticCode(app)
        var requirement: SecRequirement?
        var status = SecRequirementCreateWithString(Self.requirement(teamID: teamID, identifier: identifier) as CFString,
                                                    [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw CodeSigningFailure(description: "could not build the signing requirement (\(status))")
        }
        // Strict validation of the whole bundle: every architecture, every
        // nested framework and helper, and the resource seal, so nothing in
        // the bundle can differ from what the team signed.
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var detail: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &detail)
        guard status == errSecSuccess else {
            let reason = detail?.takeRetainedValue().localizedDescription ?? Self.describe(status)
            throw CodeSigningFailure(description: reason)
        }
    }

    public func team(of app: URL) -> String? {
        guard let code = try? staticCode(app) else { return nil }
        var anchor: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &anchor) == errSecSuccess,
              let anchor else { return nil }
        // Resources skipped: this asks who signed the bundle, and the running
        // app's resources run to a hundred megabytes of corpus.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, flags, anchor) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw CodeSigningFailure(description: Self.describe(status))
        }
        return code
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "code signing error \(status)"
    }
}
#endif
