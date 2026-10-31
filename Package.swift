// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The Linux linker otherwise writes the deployment target (17.0) as the SDK
// version, opting native menus and controls into the older system appearance.
// build_wsl.sh reads this value from the actual Apple SDK being used.
#if os(Linux)
guard let seekSDKVersion = ProcessInfo.processInfo.environment["SEEK_IOS_SDK_VERSION"],
      seekSDKVersion.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil else {
    fatalError("Build the iOS app using scripts/build_wsl.sh to select the installed Apple SDK.")
}
let nativeAppearanceLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios",
                  "-Xlinker", "17.0", "-Xlinker", seekSDKVersion], .when(platforms: [.iOS]))
]
#else
// Xcode supplies the correct SDK metadata itself, including for Simulator.
let nativeAppearanceLinkerSettings: [LinkerSetting] = []
#endif

// xtool links this library's SwiftUI @main entry point into an iOS application.
let package = Package(
    name: "SeekAPI",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SeekAPI", targets: ["SeekAPI"])],
    dependencies: [.package(path: "Packages/SeekCore"), .package(path: "Packages/SeekWebP")],
    targets: [
        .target(
            name: "SeekAPI",
            dependencies: [.product(name: "SeekCore", package: "SeekCore"), .product(name: "SeekWebP", package: "SeekWebP")],
            path: "SeekAPI",
            exclude: ["Resources"],
            linkerSettings: nativeAppearanceLinkerSettings
        )
    ],
    swiftLanguageVersions: [.v5]
)
