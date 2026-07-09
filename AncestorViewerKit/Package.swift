// swift-tools-version:6.1
import PackageDescription

// AncestorViewerKit — PHASE4_VIEWER_SPEC Change 1: the platform-neutral
// fetch/cache core shared by the tvOS and iOS viewers. Read-only by
// construction: it wraps only CloudKit FETCH operations (never a modify),
// caches rows in a disposable GRDB database, and rebuilds AncestorKit's
// FamilyGraphSnapshot for one manifest lineage. Deliberately NOT SQLiteData
// (decision log #2 — a viewer must be structurally unable to write).
let package = Package(
    name: "AncestorViewerKit",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("26.0")],
    products: [
        .library(name: "AncestorViewerKit", targets: ["AncestorViewerKit"])
    ],
    dependencies: [
        .package(path: "../AncestorKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        .target(
            name: "AncestorViewerKit",
            dependencies: [
                .product(name: "AncestorKit", package: "AncestorKit"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]),
        .testTarget(
            name: "AncestorViewerKitTests",
            dependencies: ["AncestorViewerKit"])
    ]
)
