// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBrowser",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoBrowser", targets: ["PhotoBrowser"]),
               .executable(name: "BrowserCoreChecks", targets: ["BrowserCoreChecks"]),
               .executable(name: "BrowserSmokeChecks", targets: ["BrowserSmokeChecks"]),
               .executable(name: "BrowserHDRChecks", targets: ["BrowserHDRChecks"])],
    targets: [
        .target(name: "BrowserCore"),
        .executableTarget(name: "PhotoBrowser", dependencies: ["BrowserCore"]),
        .executableTarget(name: "BrowserCoreChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserCoreTests"),
        .executableTarget(name: "BrowserSmokeChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserSmokeChecks"),
        .executableTarget(name: "BrowserHDRChecks", dependencies: ["BrowserCore"], path: "Tests/BrowserHDRChecks")
    ],
    swiftLanguageModes: [.v5]
)
