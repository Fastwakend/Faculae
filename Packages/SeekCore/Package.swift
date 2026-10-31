// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeekCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SeekCore", targets: ["SeekCore"])],
    targets: [
        .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),
        .target(name: "SeekCore", dependencies: ["CZlib"]),
        .testTarget(name: "SeekCoreTests", dependencies: ["SeekCore"], resources: [.copy("Fixtures")])
    ]
)
