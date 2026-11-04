// What the device can hold and run. Mirrors lib/src/services/device_memory.dart,
// lib/src/services/device_storage.dart and the architecture gate
// (`runsOn`/`reasonFor`) in lib/src/services/inference/local_model_backend.dart.

import Foundation
import Metal
#if os(iOS)
import os
#endif

/// How much memory this device has.
///
/// The Dart needed a method channel per platform for this; here it is one
/// call. Exists for the same reason: the catalogue declares a minimum per
/// model, and an old phone offered a model it can't hold downloads it in full
/// and is then killed by the OS on first use.
public enum LocalDeviceMemory {
    /// Physical memory in megabytes (MiB), as the OS reports it. Nil is never
    /// returned on Apple platforms in practice, but is kept in the signature
    /// so callers stay permissive about an unknown amount, as the Dart is.
    public static func totalMB() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return bytes > 0 ? Int(bytes / 1_048_576) : nil
    }

    /// How much more this process may allocate before iOS terminates it, in
    /// megabytes. Nil on macOS, which has no such per-app cap.
    ///
    /// This is the number that actually decides whether a model can load on
    /// an iPhone: physical memory says what the device has, this says what
    /// the app is allowed right now, after the corpus, the vector index and
    /// everything else already resident.
    public static func appAvailableMB() -> Int? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes / 1_048_576) : nil
        #else
        return nil
        #endif
    }
}

/// How much free disk space this device has.
///
/// Worth *warning* about rather than hiding a model for: a reader can delete
/// photos and try again, but can't add RAM. So a model too large for the
/// disk stays visible with its download disabled and the numbers shown.
public enum LocalDeviceStorage {
    /// Filling a disk to the last megabyte breaks the OS, not just this app.
    /// The Dart's `_headroomMb`.
    public static let headroomBytes: Int64 = 500 * 1_048_576

    /// Free bytes on the volume holding `url`, or nil if it can't be read.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the plain
    /// capacity: on iOS it counts space the system would free (purgeable
    /// caches) for a user-requested download, which is what this is. Not
    /// cached, because free space is the one device fact that changes while
    /// the app is open, often *because* the reader went to free some up.
    public static func freeBytes(at url: URL) -> Int64? {
        // The directory may not exist yet; ask about the nearest one that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Whether `requiredBytes` can be written with headroom to spare, given
    /// `freeBytes`. Permissive when free space is unknown: refusing a download
    /// because a probe failed is worse than letting it fail the way it would
    /// have anyway (`DeviceStorage.hasRoomFor`).
    public static func hasRoom(for requiredBytes: Int64, freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredBytes + headroomBytes
    }
}

/// The facts about this device that decide whether MLX can run at all.
///
/// Taken as a value rather than read inside the check, so every device class
/// the gate has to get right can be asserted on one machine. The Dart learned
/// this the hard way: the fault (a 32-bit Android build) was invisible on the
/// only architecture the developer's machines had.
public struct LocalModelEnvironment: Sendable, Hashable {
    public var platform: LocalModelPlatform
    /// MLX needs Metal features the Simulator's GPU doesn't provide; it fails
    /// with Metal assertions rather than an error (mlx-swift's
    /// "Running on iOS" article).
    public var isSimulator: Bool
    /// MLX's Metal backend runs on Apple silicon only. macOS 26 still runs on
    /// Intel Macs, and the Mac app may ship a universal binary.
    public var isAppleSilicon: Bool
    public var hasMetalDevice: Bool

    public init(platform: LocalModelPlatform, isSimulator: Bool, isAppleSilicon: Bool, hasMetalDevice: Bool) {
        self.platform = platform
        self.isSimulator = isSimulator
        self.isAppleSilicon = isAppleSilicon
        self.hasMetalDevice = hasMetalDevice
    }

    public static let current: LocalModelEnvironment = {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        #if targetEnvironment(simulator)
        // The Metal device isn't asked for: the answer is irrelevant here.
        return LocalModelEnvironment(platform: .current, isSimulator: true, isAppleSilicon: appleSilicon,
                                     hasMetalDevice: false)
        #else
        return LocalModelEnvironment(platform: .current, isSimulator: false, isAppleSilicon: appleSilicon,
                                     hasMetalDevice: MTLCreateSystemDefaultDevice() != nil)
        #endif
    }()

    /// Why a downloaded model can't run here, in a sentence for the reader;
    /// nil when it can (`LocalModelChoice.reasonFor`).
    ///
    /// Specific about *this* device rather than generically apologetic,
    /// because the reader's next move differs.
    public var unsupportedReason: String? {
        if isSimulator {
            return "A downloaded model can't run in the Simulator, which lacks the GPU features MLX needs. "
                + "Run on a real iPhone or iPad, or on a Mac."
        }
        if !isAppleSilicon {
            return platform == .desktop
                ? "A downloaded model needs Apple silicon, and this Mac has an Intel processor."
                : "A downloaded model can't run on this device."
        }
        if !hasMetalDevice {
            return "A downloaded model needs a Metal GPU, and none was found on this device."
        }
        return nil
    }

    public var runsLocalModels: Bool { unsupportedReason == nil }
}
