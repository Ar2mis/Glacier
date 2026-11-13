// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Glacier",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [
        .library(name: "GlacierCore", type: .static, targets: ["GlacierCore"]),
        .executable(name: "Glacier", targets: ["GlacierApp"]),
        .executable(name: "GlacierCoreVerify", targets: ["GlacierCoreVerify"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .target(name: "GlacierCore", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")], path: "Core"),
        .executableTarget(name: "GlacierApp", dependencies: ["GlacierCore"], path: "Sources"),
        .executableTarget(name: "GlacierCoreVerify", dependencies: ["GlacierCore"], path: "CoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
