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
        .package(url: "https://github.com/bitcoindevkit/bdk-swift", exact: "1.2.0"),
        // secp256k1 primitives for BIP352 silent payments (sending): ECDH on
        // raw points, scalar tweaks, x-only keys. Pure Swift package over
        // the libsecp256k1 sources; no Rust FFI needed.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "WalletKit",
            dependencies: [
                .product(name: "BitcoinDevKit", package: "bdk-swift"),
                .product(name: "P256K", package: "swift-secp256k1"),
            ]
        ),
        .testTarget(
            name: "WalletKitTests",
            dependencies: ["WalletKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
