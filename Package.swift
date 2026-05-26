// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotifier",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotifier",
            path: "Sources/ClaudeNotifier"
        )
    ]
)
