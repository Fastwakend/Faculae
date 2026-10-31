// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeekWebP",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SeekWebP", targets: ["SeekWebP"])],
    targets: [.target(name: "SeekWebP", path: ".", sources: ["src/dec", "src/enc", "src/dsp", "src/utils", "sharpyuv"],
        publicHeadersPath: "include", cSettings: [.headerSearchPath("."), .define("WEBP_DISABLE_SIMD")])]
)
