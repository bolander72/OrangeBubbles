// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WalletKit",
    platforms: [
        .iOS("17.5"), // matches bdk-swift 1.2.0's binary minimum
        .macOS(.v13), // lets `swift test` run the non-UI core on CI/dev Macs
    ],
    products: [
        .library(name: "WalletKit", targets: ["WalletKit"])
    ],
    dependencies: [
        .package(path: "vendor/bdk-swift")
    ],
    targets: [
        .binaryTarget(
            name: "OBFrostFFI",
            path: "OBFrostFFI.xcframework"
        ),
        .target(
            name: "OBFrost",
            dependencies: ["OBFrostFFI"]
        ),
        .target(
            name: "WalletKit",
            dependencies: [
                .product(name: "BitcoinDevKit", package: "bdk-swift"),
                "OBFrost"
            ]
        ),
        .testTarget(
            name: "WalletKitTests",
            dependencies: ["WalletKit"]
        ),
    ]
)
