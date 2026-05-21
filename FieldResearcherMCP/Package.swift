// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FieldResearcherMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FieldResearcherMCP",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "FieldResearcherMCPTests",
            dependencies: ["FieldResearcherMCP"],
            path: "Tests/FieldResearcherMCPTests"
        ),
    ]
)
