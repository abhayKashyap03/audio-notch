// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AudioNotch",
            path: "Sources/AudioNotch"
        )
    ]
)
