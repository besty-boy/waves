// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wave",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .executable(name: "WaveMCP", targets: ["WaveMCP"])
    ],
    targets: [
        .target(name: "WaveCore"),
        .target(name: "WaveEditor", dependencies: ["WaveCore"]),
        .executableTarget(name: "WaveMCP", dependencies: ["WaveCore"]),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"]),
        .testTarget(name: "WaveEditorTests", dependencies: ["WaveEditor"], path: "Tests/WaveEditorTests")
    ]
)
