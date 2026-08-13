// swift-tools-version:5.5
import PackageDescription

// Locally vendored bdk-swift 1.2.0 whose bdkFFI.xcframework has been patched to
// add a Mac Catalyst (ios-arm64-maccatalyst) slice — the upstream release ships
// only iOS / iOS-sim / native-macOS, which blocks Messages-on-Mac (Catalyst).
// The Swift sources are byte-for-byte the upstream 1.2.0; only the binary target
// changed from a remote URL to the local patched xcframework. See
// reference_orangebubbles_mac_catalyst.
let package = Package(
    name: "bdk-swift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "BitcoinDevKit",
            targets: ["bdkFFI", "BitcoinDevKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "bdkFFI",
            path: "bdkFFI.xcframework"),
        .target(
            name: "BitcoinDevKit",
            dependencies: ["bdkFFI"]),
    ]
)
