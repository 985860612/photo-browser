// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBrowser",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoBrowser", targets: ["PhotoBrowser"]),
               .executable(name: "BrowserCoreChecks", targets: ["BrowserCoreChecks"]),
               .executable(name: "BrowserSmokeChecks", targets: ["BrowserSmokeChecks"]),
               .executable(name: "BrowserHDRChecks", targets: ["BrowserHDRChecks"]),
               .executable(name: "BrowserThumbnailChecks", targets: ["BrowserThumbnailChecks"]),
               .executable(name: "BrowserLocalizationChecks", targets: ["BrowserLocalizationChecks"]),
               .executable(name: "BrowserCullingChecks", targets: ["BrowserCullingChecks"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "BrowserCore", resources: [.process("Resources")]),
        .target(name: "CullingCore", dependencies: ["BrowserCore"]),
        .executableTarget(name: "PhotoBrowser", dependencies: ["BrowserCore", "CullingCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "BrowserCoreChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserCoreTests"),
        .executableTarget(name: "BrowserSmokeChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserSmokeChecks"),
        .executableTarget(name: "BrowserHDRChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserHDRChecks"),
        .executableTarget(name: "BrowserThumbnailChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserThumbnailChecks"),
        .executableTarget(name: "BrowserLocalizationChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserLocalizationChecks"),
        .executableTarget(name: "BrowserCullingChecks", dependencies: ["CullingCore"], path: "Tests/BrowserCullingChecks")
    ],
    swiftLanguageModes: [.v5]
)
