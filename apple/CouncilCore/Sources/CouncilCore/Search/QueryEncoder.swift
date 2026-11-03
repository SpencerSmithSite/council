// Port of lib/src/services/search/query_encoder.dart.
//
// Encodes a search query into the same vector space as the corpus. The corpus
// vectors were precomputed with all-MiniLM-L6-v2, quantized; this runs *that
// same model file* on the query. Document and query vectors must come from one
// model: a different, unquantized or Core ML-converted model would not error,
// it would just quietly rank worse. shared/golden/search/README.md
// ("Tolerances" and implementation note 3) is the spec this file is held to.
//
// Unlike the Dart class, this one takes token ids rather than a string, so it
// can be tested on its own against the fixture's recorded `tokenIds`. Search
// composes it with the WordPiece tokenizer.

import Foundation
import OnnxRuntimeBindings

/// Runs `model_quantized.onnx` on WordPiece token ids and returns the
/// L2-normalised, mean-pooled embedding.
///
/// ## Concurrency
///
/// A `final class` marked `@unchecked Sendable` rather than an actor, because:
///
/// - Every stored property is a `let` set in `init`, and nothing is mutated
///   afterwards. The only non-`Sendable` member is the `ORTSession`.
/// - ONNX Runtime documents `Run` as safe to call concurrently on one session
///   (the C API's `OrtApi::Run`). The Objective-C wrapper's
///   `runWithInputs:outputNames:runOptions:error:` touches nothing but its
///   immutable `Ort::Session` and per-call locals, creating fresh run options
///   when given none, as here.
/// - An actor would add no safety on top of that, but it would serialise
///   every encode and force `await` on callers. It would also run this
///   CPU-bound work on the cooperative pool, which a plain synchronous call
///   from a detached or background task does just as well.
///
/// `embed` blocks for a few milliseconds of inference, so callers should keep
/// it off the main actor.
///
/// ## Parity with the Flutter app
///
/// The Flutter `onnxruntime` 1.4.1 plugin bundles ORT 1.15.1; this package
/// links ORT 1.24.2. On this dynamically quantised model the two disagree by
/// far more than float noise with default options: up to 0.029 per component,
/// cosine as low as 0.982, enough to change every semantic result list in the
/// golden fixture. The cause is a graph fusion that is new since 1.15:
/// 1.24's `MatMulIntegerToFloatFusion` also absorbs the 36 bias `Add`s that
/// follow the quantised MatMuls, and the fused kernel rounds differently.
/// Each `DynamicQuantizeLinear` downstream then turns those last-bit
/// differences into whole quantisation steps.
///
/// Disabling that one fusion leaves the bias adds as separate ops, as 1.15.1
/// ran them. With it off, 35 of the 37 golden queries match Flutter to
/// within 1e-7, and the other two (`ent-catholic`, `edge-long`) stay above
/// cosine 0.99997. Those two are where a value sits on a quantisation
/// boundary, so a last-bit difference in an unfused op still flips one step.
/// Speed is unchanged. Exact parity for every query would need the same ORT
/// build on both sides.
public final class QueryEncoder: @unchecked Sendable {
    /// all-MiniLM-L6-v2 output width (`QueryEncoder.dims` in Dart).
    public static let dims = SearchConstants.vectorDims

    public enum Error: Swift.Error, CustomStringConvertible {
        /// No file at the model URL.
        case modelNotFound(URL)
        /// The model has no outputs, so there is nothing to pool.
        case modelHasNoOutputs
        /// `embed` was given no tokens. The tokenizer always emits at least
        /// `[CLS] [SEP]`, so this is a caller bug, and pooling zero tokens
        /// would divide by zero.
        case emptyInput
        /// The output tensor was not float32 `[1, tokens, dims]`.
        case unexpectedOutput(String)

        public var description: String {
            switch self {
            case .modelNotFound(let url): "No ONNX model at \(url.path(percentEncoded: false))"
            case .modelHasNoOutputs: "The ONNX model declares no outputs"
            case .emptyInput: "QueryEncoder.embed needs at least one token id"
            case .unexpectedOutput(let detail): "Unexpected model output: \(detail)"
            }
        }
    }

    /// The ONNX Runtime version linked in, e.g. "1.24.2". The parity notes
    /// above were measured against one version; the tests pin it so an
    /// upgrade is a deliberate re-check rather than a silent drift.
    public static var runtimeVersion: String { ORTVersion() ?? "unknown" }

    /// ORT graph optimisers to skip. Check the optimised graph before adding
    /// a second name: with ORT 1.24.2, a comma-separated pair
    /// (`BiasGeluFusion,MatMulIntegerToFloatFusion`) disabled neither.
    static let disabledOptimizers = "MatMulIntegerToFloatFusion"

    private let session: ORTSession
    /// The output that is pooled: the model's first, as in Dart, where
    /// `outputs.first` is the `[1, n, 384]` last hidden state.
    private let outputName: String

    /// Loads the model. Costs ~20 MB and a moment of startup, so load lazily
    /// and tolerate failure: semantic search being unavailable should leave
    /// lexical search working.
    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path(percentEncoded: false)) else {
            throw Error.modelNotFound(modelURL)
        }
        // The session keeps a strong reference to the env, so it needn't be
        // stored here. ORT shares one underlying OrtEnv per process however
        // many of these exist.
        let env = try ORTEnv(loggingLevel: .warning)
        // Dart's `OrtSessionOptions()` defaults (CPU execution provider only,
        // full graph optimisation, ORT's default intra-op thread count) with
        // one fusion turned off; see "Parity with the Flutter app" above.
        // Thread count doesn't change the result: tested at 1 and the default.
        // Appending the Core ML provider would move ops off the CPU kernels
        // the fixture's vectors came from.
        let options = try ORTSessionOptions()
        try options.addConfigEntry(
            withKey: "optimization.disable_specified_optimizers",
            value: Self.disabledOptimizers
        )
        session = try ORTSession(
            env: env,
            modelPath: modelURL.path(percentEncoded: false),
            sessionOptions: options
        )
        guard let first = try session.outputNames().first else {
            throw Error.modelHasNoOutputs
        }
        outputName = first
    }

    /// Encodes WordPiece ids (including `[CLS]` and `[SEP]`) to 384
    /// L2-normalised floats.
    ///
    /// Mirrors the Dart pipeline exactly: one batch of `n` tokens, attention
    /// mask all ones and token types all zeros, then mean-pool over *every*
    /// position. Because the mask is all ones, `[CLS]` and `[SEP]` are
    /// pooled too; that is what built the index, so it is what has to happen
    /// here.
    public func embed(tokenIds: [Int]) throws -> [Float] {
        let n = tokenIds.count
        guard n > 0 else { throw Error.emptyInput }

        // The pool drains the Objective-C temporaries each call creates (the
        // output dictionary, the no-copy NSMutableData over the output
        // buffer). Swift's concurrency threads give no promise about when an
        // enclosing pool would drain, so without this a burst of queries
        // could pile them up.
        return try autoreleasepool {
            let shape: [NSNumber] = [1, NSNumber(value: n)]
            // ORTValue wraps these buffers without copying and keeps a strong
            // reference to them, so they live exactly as long as the values.
            let inputs: [String: ORTValue] = [
                "input_ids": try Self.int64Tensor(tokenIds.map(Int64.init), shape: shape),
                "attention_mask": try Self.int64Tensor(Array(repeating: 1, count: n), shape: shape),
                "token_type_ids": try Self.int64Tensor(Array(repeating: 0, count: n), shape: shape),
            ]

            let outputs = try session.run(
                withInputs: inputs,
                outputNames: [outputName],
                runOptions: nil
            )
            guard let output = outputs[outputName] else {
                throw Error.unexpectedOutput("no \(outputName) in the results")
            }

            let info = try output.tensorTypeAndShapeInfo()
            let outShape = info.shape.map(\.intValue)
            guard info.elementType == .float, outShape == [1, n, Self.dims] else {
                throw Error.unexpectedOutput(
                    "\(outputName) is element type \(info.elementType.rawValue) shape \(outShape), " +
                    "expected float [1, \(n), \(Self.dims)]")
            }

            // tensorData() points into the ORTValue's own buffer without
            // copying, so `output` has to outlive the read.
            let data = try output.tensorData()
            return withExtendedLifetime(output) {
                Self.meanPoolAndNormalize(
                    UnsafeRawBufferPointer(start: data.bytes, count: data.length)
                        .assumingMemoryBound(to: Float.self),
                    tokens: n
                )
            }
        }
    }

    /// Mean-pools `[tokens, dims]` row-major hidden states and L2-normalises.
    ///
    /// The precision of each step matches Dart's, so the result is
    /// bit-identical given identical model output:
    /// - Dart's running sum and mean live in a `Float32List`. Adding two
    ///   float32 values in Double and rounding back to float32 gives exactly
    ///   Float addition (Double has more than 2 × 24 + 2 significand bits),
    ///   and likewise for the division by the token count, so plain `Float`
    ///   arithmetic reproduces it.
    /// - The norm accumulates in Double, sequentially over `d`, from the
    ///   float32 means widened before squaring.
    /// - Each float32 component is divided by the *Double* norm and the
    ///   quotient rounded to float32. Rounding the norm to Float first would
    ///   change low bits.
    static func meanPoolAndNormalize(_ hidden: UnsafeBufferPointer<Float>, tokens n: Int) -> [Float] {
        let dims = Self.dims
        var pooled = [Float](repeating: 0, count: dims)
        for t in 0..<n {
            let row = t * dims
            for d in 0..<dims {
                pooled[d] += hidden[row + d]
            }
        }

        let count = Float(n)  // exact: n is at most a few hundred
        var norm = 0.0
        for d in 0..<dims {
            pooled[d] /= count
            let p = Double(pooled[d])
            norm += p * p
        }
        norm = norm.squareRoot()
        if norm > 0 {
            for d in 0..<dims {
                pooled[d] = Float(Double(pooled[d]) / norm)
            }
        }
        return pooled
    }

    private static func int64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
    }
}
