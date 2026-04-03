// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MiniWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MiniWhisper", targets: ["MiniWhisper"]),
        .executable(name: "MiniWhisperDebug", targets: ["MiniWhisperDebug"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1")
    ],
    targets: [
        .executableTarget(
            name: "MiniWhisper",
            dependencies: [
                "FluidAudio",
                "whisper"
            ],
            path: "Sources/MiniWhisper",
            exclude: ["Resources"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MiniWhisperDebug",
            dependencies: [
                "FluidAudio",
                "whisper"
            ],
            path: "Sources/MiniWhisperDebug",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/andyhtran/MiniWhisper/releases/download/whisper-xcframework-1.0/whisper.xcframework.zip",
            checksum: "866b43e4a3f31d1f898c7300d36e786841723e7be5a0fcdaa5879daea2f4389d"
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
