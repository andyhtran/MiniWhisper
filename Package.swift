// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MiniWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MiniWhisper", targets: ["MiniWhisper"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1")
    ],
    targets: [
        .executableTarget(
            name: "MiniWhisper",
            dependencies: [
                "FluidAudio"
            ],
            path: "Sources/MiniWhisper",
            exclude: ["Resources"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MiniWhisperTests",
            dependencies: ["MiniWhisper"],
            path: "Tests/MiniWhisperTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
