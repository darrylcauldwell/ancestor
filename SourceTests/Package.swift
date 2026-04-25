// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceTests",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SourceTests",
            path: "Sources"
        ),
    ]
)
