// swift-tools-version: 6.2
// 6.2 is the first tools version that knows the iOS/macOS 26 platform values.

import PackageDescription

let package = Package(
    name: "CouncilCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CouncilCore", targets: ["CouncilCore"]),
    ],
    targets: [
        // One target with a folder per area rather than one module per folder:
        // the areas share types (ids, the corpus handle) and splitting them into
        // separate modules now would only add access-control ceremony. Split
        // later if build times or boundaries ask for it.
        .target(name: "CouncilCore"),
        .testTarget(name: "CouncilCoreTests", dependencies: ["CouncilCore"]),
    ],
    swiftLanguageModes: [.v6]
)
