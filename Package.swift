// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Glacier",
    platforms: [.macOS("26.0"), .iOS("18.0")],
    products: [
        .library(name: "GlacierCore", type: .static, targets: ["GlacierCore"]),
        .executable(name: "Glacier", targets: ["GlacierApp"]),
        .executable(name: "GlacierCoreVerify", targets: ["GlacierCoreVerify"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // ASR only: omit TTS, diarization and the unrelated NeMo binary runtime.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: [])
    ],
    targets: [
        .target(name: "GlacierCore", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ], path: "Core"),
        .executableTarget(name: "GlacierApp", dependencies: ["GlacierCore"], path: "Sources"),
        .executableTarget(name: "GlacierCoreVerify", dependencies: ["GlacierCore", .product(name: "WhisperKit", package: "WhisperKit")], path: "CoreTests")
    ],
    swiftLanguageModes: [.v5]
)
