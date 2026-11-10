// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Tally",
            path: "Sources/Tally",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
