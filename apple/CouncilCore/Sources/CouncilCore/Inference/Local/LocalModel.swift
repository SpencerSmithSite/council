// The downloadable-model catalogue. Mirrors `LocalModelChoice` and
// `LocalModelTier` in lib/src/services/inference/local_model_backend.dart,
// re-expressed for MLX builds of the same Qwen3 models.

import Foundation

/// One downloadable model, with the numbers needed to decide whether to offer
/// it on a given device.
///
/// Sized in RAM rather than disk, because RAM is the binding constraint: the
/// vector index already holds every corpus embedding resident (~170 MB at
/// 445,445 chunks), and a model has to fit *beside* that, not merely onto the
/// filesystem.
///
/// The Flutter app ran these through LiteRT-LM as single `.litertlm` files.
/// MLX can't read those (apple/PLAN.md, Phase 7), so each entry here points
/// at the `mlx-community` 4-bit build of the same weights instead: a Hugging
/// Face repository pinned to one commit, with every file it needs listed with
/// its size and SHA-256. Pinning is what lets the download be checked: a file
/// that doesn't hash to what is written here is never treated as installed,
/// and a repository that is later re-uploaded can't change what the app
/// runs. All four are Apache-2.0 and ungated, as the Dart requires (no
/// account, no key).
public struct LocalModel: Sendable, Hashable, Identifiable {
    /// Persisted under the `local_model` preference. The Flutter ids, kept
    /// exactly, so a reader's choice survives the move to the native app.
    public let id: String
    public let name: String

    /// The Hugging Face repository, e.g. `mlx-community/Qwen3-0.6B-4bit`.
    public let repository: String
    /// The commit every file is fetched from. Never `main`: see the type doc.
    public let revision: String
    /// What has to be on disk for MLX to load the model. Not the whole
    /// repository: the README, `.gitattributes`, and `vocab.json`/`merges.txt`
    /// (which `tokenizer.json` supersedes) are left out.
    public let files: [LocalModelFile]

    /// Rough resident cost of the weights plus a full KV cache at
    /// `maxTokens`, in megabytes.
    ///
    /// Lower than the Dart's for the two larger phone-capable models because
    /// the MLX 4-bit weights are smaller than the `.litertlm` builds (0.97 GB
    /// against 2.1 GB for the 1.7B). Estimated as weights + KV cache
    /// (layers × KV heads × head size × 4 bytes per token) + ~150 MB of
    /// working buffers; the 0.6B's is measured by the smoke test.
    public let ramMB: Int

    /// Least device memory this is sensible on, in megabytes. Deliberately
    /// above `ramMB`: the OS, the app, the corpus database and the vector index
    /// are all resident too, and a model that just barely fits is one that
    /// gets the app killed under memory pressure.
    ///
    /// Compared against what the OS *reports*, which can be less than what the
    /// device is sold as. Each is set roughly a tier below the nominal size it
    /// is meant to admit.
    public let minDeviceRAMMB: Int

    /// What a *phone or iPad* needs, or nil if this model is Mac-only.
    ///
    /// Separate from `minDeviceRAMMB` because the same number can't serve
    /// both. A Mac may page and is limited by physical memory; iOS caps what a
    /// single app may hold well under the physical amount, and going over
    /// means the OS kills the app rather than swapping. So a 16 GB iPad
    /// reports 16 GB and still can't hold a 6 GB model, while a 16 GB Mac can.
    ///
    /// A ceiling, not a floor: the small models stay available everywhere.
    /// The phone figures are the least-evidenced numbers here; being too
    /// conservative costs a flagship reader a better model, being too generous
    /// costs an ordinary reader a large download that ends in a crash.
    public let minPhoneRAMMB: Int?

    /// The model's whole context, prompt and answer together, in tokens.
    ///
    /// LiteRT-LM's `maxTokens` was the size of the KV cache, so a long prompt
    /// left less room for the answer. Kept with that meaning: the answer is
    /// capped at what's left after the prompt (see `LocalModelSampling`).
    public let maxTokens: Int

    /// Tied to the model rather than fixed: a 4B model on a Mac can be given
    /// far more retrieved text than a 0.6B one on a phone, and over-filling a
    /// small window degrades the answer instead of failing.
    public let contextBudgetChars: Int

    /// Whether the model reasons in `<think>` by default and so needs telling
    /// not to. True of the hybrid Qwen3 releases; false of the 2507 Instruct,
    /// which never thinks. See `LocalModelBackend.thinkingContext`.
    public let thinksByDefault: Bool

    public let note: String

    public init(id: String, name: String, repository: String, revision: String, files: [LocalModelFile],
                ramMB: Int, minDeviceRAMMB: Int, minPhoneRAMMB: Int?, maxTokens: Int,
                contextBudgetChars: Int, thinksByDefault: Bool, note: String) {
        self.id = id
        self.name = name
        self.repository = repository
        self.revision = revision
        self.files = files
        self.ramMB = ramMB
        self.minDeviceRAMMB = minDeviceRAMMB
        self.minPhoneRAMMB = minPhoneRAMMB
        self.maxTokens = maxTokens
        self.contextBudgetChars = contextBudgetChars
        self.thinksByDefault = thinksByDefault
        self.note = note
    }

    /// The whole download, in bytes. Derived from `files`, so it can't drift
    /// from what is actually fetched.
    public var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The download in megabytes (MiB), rounded up, as the Dart's
    /// `downloadMb`.
    public var downloadMB: Int { Int((downloadBytes + 1_048_575) / 1_048_576) }

    /// The download as prose for the reader ("347 MB", "2.3 GB"), in decimal
    /// units as Finder and iOS Settings show sizes. Computed from the bytes,
    /// so the label and the disk check can never disagree (the Dart test
    /// "every model declares a download size matching its label" exists
    /// because the two were separate literals there).
    public var approximateSize: String { LocalModelFormat.size(downloadBytes) }

    /// Where `file` is fetched from: the pinned revision, never a branch.
    public func url(for file: LocalModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }
}

/// One file of a model, as pinned in the catalogue.
public struct LocalModelFile: Sendable, Hashable {
    /// Relative to the model directory, and to the repository root.
    public let path: String
    public let bytes: Int64
    /// Lowercase hex. For LFS files this is the LFS object id Hugging Face
    /// publishes; for the small JSON files it was computed from the pinned
    /// revision when the catalogue was written.
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// Phone/iPad or Mac, which decides the memory rule (see `minPhoneRAMMB`).
///
/// iPad counts as a phone: it has the same per-app memory cap. Mirrors the
/// Dart's `_isDesktop`.
public enum LocalModelPlatform: Sendable, Hashable {
    case phone
    case desktop

    public static var current: LocalModelPlatform {
        #if os(macOS)
        .desktop
        #else
        .phone
        #endif
    }
}

/// How a model is being offered on this particular device.
///
/// A label about *fit*, not about the model: the same weights are the "large"
/// option on a mid-range phone and the "small" one on a workstation, which is
/// the whole point of choosing per device. Mirrors `LocalModelTier`.
public enum LocalModelTier: Sendable, Hashable, CaseIterable {
    /// Faster and lighter, at the cost of answer quality.
    case small
    /// The sensible default here.
    case recommended
    /// The best answers this device can produce, and the slowest.
    case large

    public var label: String {
        switch self {
        case .small: "Smaller and faster"
        case .recommended: "Recommended"
        case .large: "Best answers"
        }
    }

    /// Why a reader might pick this one. Phrased as the trade being made,
    /// since every one of these is a trade rather than a ranking.
    public var rationale: String {
        switch self {
        case .small:
            "Quickest to download and to answer. Best when you mostly want the passages found and summarised."
        case .recommended:
            "The best balance for this device — capable enough to follow a question, quick enough to stay usable."
        case .large:
            "The most capable model this device can hold. Noticeably slower to answer, and a much larger download."
        }
    }
}

/// A model as offered in the picker, with the tier it is offered as.
public struct LocalModelOption: Sendable, Hashable {
    public let tier: LocalModelTier
    public let model: LocalModel
}

// MARK: - Choosing per device

public extension LocalModel {
    /// What this model asks for on `platform`.
    func requiredMB(on platform: LocalModelPlatform = .current) -> Int {
        switch platform {
        case .desktop: minDeviceRAMMB
        case .phone: minPhoneRAMMB ?? Int.max
        }
    }

    /// Whether a device with `deviceMemoryMB` has the memory this model asks
    /// for. Permissive when the amount is unknown (nil): hiding every model
    /// from a device that merely failed to answer is worse than offering one
    /// it might not run (`DeviceMemory.meets`).
    func fits(deviceMemoryMB: Int?, on platform: LocalModelPlatform = .current) -> Bool {
        guard let deviceMemoryMB else { return true }
        return deviceMemoryMB >= requiredMB(on: platform)
    }

    /// Every model on offer for `platform`, smallest first (the Dart's `all`).
    ///
    /// Split because the sizes that make sense differ by an order of
    /// magnitude: a 4.6 GB model is reasonable on a Mac and absurd on a phone,
    /// and a picker showing all four everywhere would mostly be offering
    /// downloads that can't run.
    static func offered(on platform: LocalModelPlatform = .current) -> [LocalModel] {
        catalogue.filter { platform == .desktop || $0.minPhoneRAMMB != nil }
    }

    /// `offered(on:)`, minus anything a device with `deviceMemoryMB` doesn't
    /// have the memory for (`availableHere`).
    ///
    /// Never returns empty. If nothing fits, the smallest is offered anyway,
    /// with `fits(deviceMemoryMB:)` false, so the screen can say plainly that
    /// it is more than the device has rather than hiding the feature and
    /// explaining nothing.
    static func available(deviceMemoryMB: Int?, on platform: LocalModelPlatform = .current) -> [LocalModel] {
        let all = offered(on: platform)
        let fitting = all.filter { $0.fits(deviceMemoryMB: deviceMemoryMB, on: platform) }
        return fitting.isEmpty ? [all[0]] : fitting
    }

    /// The two or three models worth putting in front of this reader
    /// (`tiersHere`).
    ///
    /// Everything that fits is not a useful list. These are the three
    /// questions a reader actually has: what is the sensible choice, what if I
    /// want it smaller and faster, and what if I want the best answers this
    /// machine can give. `.recommended` is deliberately *not* the largest that
    /// fits once there are three or more: the largest is the slowest, and
    /// defaulting to it would make the feature feel broken on the very
    /// machines that can run the most.
    static func tiers(deviceMemoryMB: Int?, on platform: LocalModelPlatform = .current) -> [LocalModelOption] {
        let fits = available(deviceMemoryMB: deviceMemoryMB, on: platform)
        switch fits.count {
        case 1:
            return [LocalModelOption(tier: .recommended, model: fits[0])]
        case 2:
            return [LocalModelOption(tier: .small, model: fits[0]),
                    LocalModelOption(tier: .recommended, model: fits[1])]
        default:
            return [LocalModelOption(tier: .small, model: fits[0]),
                    LocalModelOption(tier: .recommended, model: fits[fits.count - 2]),
                    LocalModelOption(tier: .large, model: fits[fits.count - 1])]
        }
    }

    /// The model to select by default on a device with `deviceMemoryMB`
    /// (`recommendedHere`).
    ///
    /// Defined as whatever `tiers` labels `.recommended`, so the model
    /// selected by default and the row marked "Recommended" can never
    /// disagree, which they once did in the Dart.
    static func recommended(forDeviceMemory deviceMemoryMB: Int?,
                            on platform: LocalModelPlatform = .current) -> LocalModel {
        tiers(deviceMemoryMB: deviceMemoryMB, on: platform).first { $0.tier == .recommended }!.model
    }

    /// The model recommended for this device's memory as the OS reports it.
    static func recommendedHere() -> LocalModel {
        recommended(forDeviceMemory: LocalDeviceMemory.totalMB())
    }

    /// The conservative default, for the moment before memory has been read
    /// (the Dart's `recommended()`): the smallest. Being briefly
    /// under-ambitious costs a reader nothing, while briefly claiming a model
    /// the device can't hold would show them a download they shouldn't start.
    static func conservativeDefault(on platform: LocalModelPlatform = .current) -> LocalModel {
        offered(on: platform)[0]
    }

    /// Resolves a stored `local_model` id against the whole catalogue, not
    /// the platform's shortlist, so a choice made on a Mac is recognised on
    /// an iPhone rather than silently reset. Falls back to the conservative
    /// default when the id is unknown (a model removed in a later version,
    /// such as `gemma3-1b`).
    static func byID(_ id: String, on platform: LocalModelPlatform = .current) -> LocalModel {
        catalogue.first { $0.id == id } ?? conservativeDefault(on: platform)
    }
}

// MARK: - The catalogue

public extension LocalModel {
    /// Every model, smallest first, for resolving a stored id whatever device
    /// wrote it.
    ///
    /// Qwen throughout, and deliberately so: it publishes at every size from
    /// 0.6B to 8B under Apache-2.0 with no gate, so one family can cover a
    /// phone and a Mac workstation. Gemma's repositories are gated behind a
    /// Hugging Face account, which this backend promises readers they won't
    /// need. SmolLM 135M was tried in the Flutter app and removed: it ignored
    /// the retrieved passages entirely.
    static let catalogue: [LocalModel] = [qwen3_0_6B, qwen3_1_7B, qwen3_4B, qwen3_8B]

    /// The tokenizer files are byte-identical across all four repositories.
    private static let qwenTokenizerFiles: [LocalModelFile] = [
        .init(path: "added_tokens.json", bytes: 707,
              sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        .init(path: "special_tokens_map.json", bytes: 613,
              sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        .init(path: "tokenizer.json", bytes: 11_422_654,
              sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
    ]

    /// The hybrid releases share a `tokenizer_config.json` (it carries the chat
    /// template with the `enable_thinking` switch).
    private static let hybridTokenizerConfig = LocalModelFile(
        path: "tokenizer_config.json", bytes: 9_706,
        sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0")

    /// 28 layers, 8 KV heads of 128: 224 MiB of KV cache at 2,048 tokens.
    static let qwen3_0_6B = LocalModel(
        id: "qwen3-0.6b",
        name: "Qwen 3 0.6B",
        repository: "mlx-community/Qwen3-0.6B-4bit",
        revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
        files: [
            .init(path: "config.json", bytes: 937,
                  sha256: "15d3ac26c043ae477273ed5802ee0f0b33bb14f18c9d3dd70910c02d906e3f1f"),
            .init(path: "model.safetensors", bytes: 335_450_584,
                  sha256: "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2"),
            .init(path: "model.safetensors.index.json", bytes: 49_731,
                  sha256: "7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb"),
            hybridTokenizerConfig,
        ] + qwenTokenizerFiles,
        ramMB: 700,
        // Admits a nominal 3 GB phone, excludes a 2 GB one. The Dart's figure,
        // verified there on a device reporting 3,967 MB.
        minDeviceRAMMB: 2600,
        minPhoneRAMMB: 2600,
        maxTokens: 2048,
        contextBudgetChars: 3000,
        thinksByDefault: true,
        note: "Small enough for any recent phone. Good at summarising and comparing the passages Council "
            + "retrieves; a hosted model is still better for open-ended questions.")

    /// 28 layers, 8 KV heads of 128: weights 923 MiB + 224 MiB of KV cache.
    static let qwen3_1_7B = LocalModel(
        id: "qwen3-1.7b",
        name: "Qwen 3 1.7B",
        repository: "mlx-community/Qwen3-1.7B-4bit",
        revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        files: [
            .init(path: "config.json", bytes: 937,
                  sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
            .init(path: "model.safetensors", bytes: 968_080_210,
                  sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
            .init(path: "model.safetensors.index.json", bytes: 49_731,
                  sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
            hybridTokenizerConfig,
        ] + qwenTokenizerFiles,
        ramMB: 1400,
        // The Dart's desktop floor. On a phone the Dart asked for a nominal
        // 12 GB, sized for a 2.4 GB LiteRT build; the MLX build is ~1.4 GB
        // resident, which fits inside the per-app cap of a nominal 8 GB
        // iPhone or iPad (iPhone 15 Pro and later) but not a 6 GB one.
        // Unverified on hardware.
        minDeviceRAMMB: 5000,
        minPhoneRAMMB: 7000,
        maxTokens: 2048,
        contextBudgetChars: 4000,
        thinksByDefault: true,
        note: "Noticeably better reasoning than the 0.6B. Only worth it on a phone with plenty of memory to spare.")

    /// 36 layers, 8 KV heads of 128: weights 2,158 MiB + 576 MiB of KV cache
    /// at 4,096 tokens.
    static let qwen3_4B = LocalModel(
        id: "qwen3-4b-2507",
        name: "Qwen 3 4B Instruct",
        repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        files: [
            .init(path: "chat_template.jinja", bytes: 4_040,
                  sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
            .init(path: "config.json", bytes: 938,
                  sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
            .init(path: "generation_config.json", bytes: 238,
                  sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
            .init(path: "model.safetensors", bytes: 2_263_022_417,
                  sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
            .init(path: "model.safetensors.index.json", bytes: 63_964,
                  sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777"),
            .init(path: "tokenizer_config.json", bytes: 5_440,
                  sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
        ] + qwenTokenizerFiles,
        ramMB: 3000,
        // Mac only: 3 GB resident is beyond what iOS will let one app hold,
        // whatever its physical memory says.
        minDeviceRAMMB: 7000,
        minPhoneRAMMB: nil,
        maxTokens: 4096,
        contextBudgetChars: 6000,
        thinksByDefault: false,
        note: "The best balance on a desktop. Handles a longer question and more retrieved text than the smaller two.")

    /// 36 layers, 8 KV heads of 128: weights 4,394 MiB + 576 MiB of KV cache.
    static let qwen3_8B = LocalModel(
        id: "qwen3-8b",
        name: "Qwen 3 8B",
        repository: "mlx-community/Qwen3-8B-4bit",
        revision: "545dc4251c05440727734bcd94334791f6ab0192",
        files: [
            .init(path: "config.json", bytes: 939,
                  sha256: "e5485285fd7e289e76e9cffa112f6dc2e3426519082f7db9b69041589f81a218"),
            .init(path: "model.safetensors", bytes: 4_607_835_174,
                  sha256: "f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8"),
            .init(path: "model.safetensors.index.json", bytes: 64_065,
                  sha256: "3fb25463b4078b1fc27159daa605190029c2e965f533bf0b1b594f96cbfceb8a"),
            hybridTokenizerConfig,
        ] + qwenTokenizerFiles,
        ramMB: 5200,
        // Admits a nominal 16 GB Mac. Mac only, as above.
        minDeviceRAMMB: 14000,
        minPhoneRAMMB: nil,
        maxTokens: 4096,
        contextBudgetChars: 8000,
        thinksByDefault: true,
        note: "The most capable option, and the heaviest. For a machine with memory to spare, where it approaches "
            + "what a hosted model gives you.")
}

/// Sizes as prose, deterministic rather than locale-formatted so the
/// catalogue's labels can be asserted in tests.
enum LocalModelFormat {
    /// Decimal units: "347 MB" below a gigabyte, "2.3 GB" above.
    static func size(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        let gb = (Double(bytes) / 1_000_000_000 * 10).rounded() / 10
        return String(format: "%.1f GB", gb)
    }
}
