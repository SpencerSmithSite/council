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
            ]
        ),
        .testTarget(name: "CouncilCoreTests", dependencies: ["CouncilCore"]),
    ],
    swiftLanguageModes: [.v6]
)
