// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppVolume",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AppVolume",
            path: "Sources/AppVolume",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
