// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioNotch",
    platforms: [.macOS("14.4")],   // process taps are 14.2+, the rest of the API 14.4
    targets: [
        .executableTarget(
            name: "AudioNotch",
            path: "Sources/AudioNotch"
        )
    ]
)
