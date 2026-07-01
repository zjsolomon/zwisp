// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zwhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0")
    ],
    targets: [
        // Pure domain logic: no external dependencies, so it (and its tests)
        // compile fast and stay unit-testable without pulling in WhisperKit/CoreML.
        .target(
            name: "ZwhisperCore",
            path: "Sources/ZwhisperCore"
        ),
        // The app itself: system-framework and WhisperKit glue on top of the core.
        .executableTarget(
            name: "Zwhisper",
            dependencies: [
                "ZwhisperCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Zwhisper"
        ),
        .testTarget(
            name: "ZwhisperCoreTests",
            dependencies: ["ZwhisperCore"],
            path: "Tests/ZwhisperCoreTests"
        )
    ]
)
