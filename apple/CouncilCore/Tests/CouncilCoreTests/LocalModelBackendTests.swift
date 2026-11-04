import Foundation
import Testing
@testable import CouncilCore

/// `LocalModelBackend`'s contract and status states, with the device facts
/// injected. Generation itself needs Metal and real weights, so it is covered
/// by the opt-in `LocalModelSmokeTests`; what is tested here is everything
/// that has to be right *before* MLX is touched.
@Suite struct LocalModelBackendTests {
    let root: URL
    let fake = FakeModel()
    let store: LocalModelStore

    static let appleSilicon = LocalModelEnvironment(platform: .desktop, isSimulator: false, isAppleSilicon: true,
                                                    hasMetalDevice: true)
    static let simulator = LocalModelEnvironment(platform: .phone, isSimulator: true, isAppleSilicon: true,
                                                 hasMetalDevice: false)
    static let iPhone = LocalModelEnvironment(platform: .phone, isSimulator: false, isAppleSilicon: true,
                                              hasMetalDevice: true)

    init() throws {
        root = try temporaryDirectory()
        store = LocalModelStore(root: root, transport: FakeModelTransport(files: fake.files), freeBytes: { _ in nil })
    }

    func backend(_ model: LocalModel? = nil, environment: LocalModelEnvironment = appleSilicon,
                 memory: Int? = 16384, appAvailable: Int? = nil) -> LocalModelBackend {
        LocalModelBackend(model: model ?? fake.model, store: store, runtime: LocalModelRuntime(),
                          environment: environment, deviceMemoryMB: { memory }, appAvailableMB: { appAvailable })
    }

    func install() async throws {
        for try await _ in store.download(fake.model) {}
    }

    // MARK: - The contract

    @Test func describesItselfAsTheFlutterBackendDid() {
        let backend = backend(.qwen3_1_7B)
        #expect(backend.id == .local)
        #expect(backend.id.rawValue == "local")
        #expect(backend.displayName == "Downloaded model")
        #expect(backend.isPrivate)
        #expect(backend.contextBudgetChars == 4000)
        #expect(self.backend(.qwen3_8B).contextBudgetChars == 8000)
    }

    @Test func offersTheModelsForItsPlatform() async throws {
        #expect(try await backend(environment: Self.iPhone).availableModels() == ["Qwen 3 0.6B", "Qwen 3 1.7B"])
        #expect(try await backend().availableModels().count == 4)
    }

    // MARK: - Status

    @Test func theSimulatorIsUnsupportedWithAReason() async {
        let status = await backend(environment: Self.simulator).checkStatus()
        #expect(!status.available)
        #expect(status.detail?.contains("Simulator") == true)
        #expect(status.detail?.contains("Ollama or an API key") == true)
    }

    @Test func notEnoughMemoryIsSaidWithTheNumbers() async {
        let status = await backend(.qwen3_8B, memory: 8192).checkStatus()
        #expect(!status.available)
        #expect(status.detail == "Qwen 3 8B needs a device with about 14 GB of memory, and this one has 8 GB. "
            + "Choose a smaller model.")
    }

    @Test func aMacOnlyModelOnAPhoneIsTooLarge() async {
        let status = await backend(.qwen3_4B, environment: Self.iPhone, memory: 16384).checkStatus()
        #expect(!status.available)
        #expect(status.detail?.contains("too large to run on an iPhone or iPad") == true)
    }

    @Test func notDownloadedSaysHowLargeTheDownloadIs() async {
        let status = await backend(.qwen3_0_6B).checkStatus()
        #expect(status == .unavailable("Qwen 3 0.6B is not downloaded yet. It is a 347 MB one-time download."))
    }

    @Test func readyOnceDownloaded() async throws {
        try await install()
        let status = await backend().checkStatus()
        #expect(status == .available("Fake fake-model, running on this device."))
    }

    @Test func tooLittleFreeMemoryToLoadOnIOS() async throws {
        try await install()
        let status = await backend(environment: Self.iPhone, appAvailable: 50).checkStatus()
        #expect(!status.available)
        #expect(status.detail?.contains("enough free memory") == true)
        #expect(await backend(environment: Self.iPhone, appAvailable: 4000).checkStatus().available)
    }

    @Test func unknownMemoryIsPermissive() async throws {
        try await install()
        #expect(await backend(memory: nil).checkStatus().available)
    }

    // MARK: - Generation refuses before touching MLX

    @Test func generatingInTheSimulatorFailsWithTheReason() async {
        await #expect(throws: InferenceError.self) {
            for try await _ in backend(environment: Self.simulator).generate(prompt: "Hi", system: nil) {}
        }
        do {
            for try await _ in backend(environment: Self.simulator).generate(prompt: "Hi", system: nil) {}
        } catch let error as InferenceError {
            #expect(error.message.contains("Simulator"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func generatingWithoutTheModelSaysToDownloadIt() async {
        await #expect(throws: InferenceError("Fake fake-model is not downloaded yet. Download it in Settings first.")) {
            for try await _ in backend().generate(prompt: "Hi", system: "Be brief.") {}
        }
    }

    @Test func deleteRemovesTheModel() async throws {
        try await install()
        let backend = backend()
        try await backend.delete()
        #expect(!store.isDownloaded(fake.model))
        #expect(await !backend.checkStatus().available)
    }

    @Test func aFreshRuntimeHoldsNothing() async {
        let runtime = LocalModelRuntime()
        #expect(await runtime.loadedModelID == nil)
        // Unloading nothing must not start MLX (no Metal shaders in a SwiftPM
        // test run).
        await runtime.unload()
        await runtime.unload(.qwen3_0_6B)
    }
}
