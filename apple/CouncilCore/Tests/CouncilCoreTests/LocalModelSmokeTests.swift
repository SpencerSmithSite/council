import Darwin
import Foundation
import MLXLMCommon
import Testing
@testable import CouncilCore

/// The real thing on this Mac: download Qwen3 0.6B from Hugging Face into the
/// app's own model directory, load it with MLX and answer a theology
/// question. Opt-in, because it fetches 347 MB and needs a Metal GPU and
/// compiled MLX shaders, which only an Xcode build provides (SwiftPM on the
/// command line can't compile Metal). Run it with:
///
///     TEST_RUNNER_COUNCIL_MLX_SMOKE=1 xcodebuild test \
///       -project apple/Council.xcodeproj -scheme Council \
///       -destination 'platform=macOS' -derivedDataPath apple/.build/DerivedData \
///       CODE_SIGNING_ALLOWED=NO -only-testing:CouncilCoreTests/LocalModelSmokeTests
///
/// The model is left where the store put it, so the app finds it downloaded.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COUNCIL_MLX_SMOKE"] == "1"), .serialized)
struct LocalModelSmokeTests {
    static let system = """
        You are Council, a research assistant for Christian theology. Answer the question using only the \
        passages provided, and say which passage each point comes from.
        """
    static let prompt = """
        Passages:
        [1] Westminster Shorter Catechism, Q. 33: Justification is an act of God's free grace, wherein he \
        pardoneth all our sins, and accepteth us as righteous in his sight, only for the righteousness of \
        Christ imputed to us, and received by faith alone.
        [2] Romans 3:28: Therefore we conclude that a man is justified by faith without the deeds of the law.

        Question: What is justification, according to these passages?
        """

    /// Resuming depends on Hugging Face's CDN honouring `Range` after the
    /// redirect from /resolve/, which only the real network can show.
    @Test func theRealTransportResumesWithARangeRequest() async throws {
        let model = LocalModel.qwen3_0_6B
        // An LFS file, so the request is redirected to the CDN.
        let file = model.files.first { $0.path == "tokenizer.json" }!
        let offset = file.bytes - 1_000
        var status = 0
        var body = Data()
        for try await event in URLSessionModelTransport().get(model.url(for: file), from: offset) {
            switch event {
            case .response(let code): status = code
            case .data(let data): body.append(data)
            }
        }
        #expect(status == 206)
        #expect(Int64(body.count) == 1_000)
    }

    @Test(.timeLimit(.minutes(30))) func downloadsLoadsAndAnswersOnThisMac() async throws {
        let model = LocalModel.qwen3_0_6B
        // The app's own directory, not xctest's, so the app finds it downloaded.
        let store = LocalModelStore(root: try LocalModelStore.defaultRoot(bundleIdentifier: "site.spencersmith.council"))
        var lines = ["model directory: \(store.directory(for: model).path)"]

        if !store.isDownloaded(model) {
            let start = ContinuousClock.now
            var shown = -1
            for try await progress in store.download(model) where progress.percent / 10 > shown {
                shown = progress.percent / 10
                print("download \(progress.percent)% (\(progress.completedBytes) of \(progress.totalBytes) bytes)")
            }
            let seconds = (ContinuousClock.now - start).seconds
            lines.append(String(format: "downloaded %d bytes in %.1f s (%.1f MB/s)", model.downloadBytes, seconds,
                                Double(model.downloadBytes) / 1_000_000 / seconds))
        } else {
            lines.append("already downloaded")
        }
        #expect(store.isDownloaded(model))

        let runtime = LocalModelRuntime()
        let backend = LocalModelBackend(model: model, store: store, runtime: runtime)
        let status = await backend.checkStatus()
        #expect(status.available, "\(status.detail ?? "")")

        let before = Footprint.now()
        let loadStart = ContinuousClock.now
        let container = try await runtime.container(for: model, in: store.directory(for: model))
        lines.append(String(format: "load %.2f s", (ContinuousClock.now - loadStart).seconds))
        #expect(await runtime.loadedModelID == model.id)

        // The thinking switch reaches the template: Qwen3's opens the answer
        // with an empty think block when enable_thinking is false.
        let tokenizer = await container.tokenizer
        let rendered = tokenizer.decode(tokenIds: try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": Self.system], ["role": "user", "content": Self.prompt]],
            tools: nil, additionalContext: LocalModelBackend.thinkingContext(for: model)))
        #expect(rendered.hasPrefix("<|im_start|>system\nYou are Council"))
        #expect(rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), "\(rendered.suffix(80))")

        // The real path: the backend, streaming.
        let start = ContinuousClock.now
        var firstChunk: Duration?
        var answer = ""
        for try await chunk in backend.generate(prompt: Self.prompt, system: Self.system) {
            if firstChunk == nil { firstChunk = ContinuousClock.now - start }
            answer += chunk
        }
        let total = (ContinuousClock.now - start).seconds
        let ttft = firstChunk?.seconds ?? total
        let tokens = tokenizer.encode(text: answer, addSpecialTokens: false).count
        let after = Footprint.now()

        #expect(!answer.isEmpty)
        #expect(!answer.contains("<think>"), "thinking should be off")
        lines.append(String(format: "answer: %d tokens, first chunk %.2f s, %.1f tokens/s after it, %.2f s total",
                            tokens, ttft, Double(tokens) / max(total - ttft, 0.001), total))
        lines.append(String(format: "memory: footprint %.0f MB before load, %.0f MB after, process peak %.0f MB",
                            before.currentMB, after.currentMB, after.peakMB))

        // Cancelling the consumer stops generation promptly.
        let consumer = Task {
            var chunks = 0
            for try await _ in backend.generate(prompt: Self.prompt, system: Self.system) {
                chunks += 1
                if chunks == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return chunks
        }
        let cancelStart = ContinuousClock.now
        let chunks = try await consumer.value
        lines.append(String(format: "cancel: stream ended after %d chunks, %.2f s from start", chunks,
                            (ContinuousClock.now - cancelStart).seconds))
        #expect(chunks <= 6)

        await runtime.unload()
        #expect(await runtime.loadedModelID == nil)

        lines.append("answer text:\n\(answer)")
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["COUNCIL_MLX_SMOKE_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The process's physical footprint, which is what the OS measures an app
/// by (and on Apple silicon includes the GPU buffers MLX allocates).
private struct Footprint {
    let currentMB: Double
    let peakMB: Double

    static func now() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Footprint(currentMB: 0, peakMB: 0) }
        return Footprint(currentMB: Double(info.phys_footprint) / 1_048_576,
                         peakMB: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
