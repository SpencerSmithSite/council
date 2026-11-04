// swift-tools-version: 6.2
// 6.2 is the first tools version that knows the iOS/macOS 26 platform values.

import PackageDescription

let package = Package(
    name: "CouncilCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CouncilCore", targets: ["CouncilCore"]),
    ],
    dependencies: [
        // SQLite access on the system SQLite, which has FTS5 on Apple platforms.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
        // Runs the same model_quantized.onnx the Flutter app and
        // tools/build_embeddings.py use, so query vectors match the index built
        // from it. A Core ML conversion would drift by more than the golden
        // fixtures' tolerance (shared/golden/search/README.md).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2"),
        // The downloaded on-device model (Inference/Local). MLXLLM holds the
        // Qwen3 architecture, MLXLMCommon the loading and generation API. Exact
        // pins, because 3.x changes its API between minor releases and the
        // weights' chat template is exercised only by the opt-in smoke test.
        // Its other products (VLM, FoundationModels bridge, guided generation,
        // the Hugging Face macros) aren't linked, so they aren't built.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // The tokenizer for those weights. mlx-swift-lm 3 no longer bundles
        // one; this is the implementation its docs integrate with. Only the
        // `Tokenizers` product is used: the Hub downloader is replaced by
        // LocalModelDownloader, which pins revisions and checks hashes.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        // One target with a folder per area rather than one module per folder:
        // the areas share types (ids, the corpus handle) and splitting them into
        // separate modules now would only add access-control ceremony. Split
        // later if build times or boundaries ask for it.
        .target(
            name: "CouncilCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "CouncilCoreTests",
            dependencies: [
                "CouncilCore",
                // For the opt-in MLX smoke test's token count.
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
