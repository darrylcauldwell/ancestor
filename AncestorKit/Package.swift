// swift-tools-version:6.1
import PackageDescription

// AncestorKit — the portable domain core of Ancestor Research
// (ARCHITECTURE_REVIEW_2026-07.md Phase 2). Pure Foundation value
// types shared by the macOS app today and the iPad/tvOS viewers,
// CloudKit publisher, and MCP surface tomorrow. No UI, no GRDB,
// no scrapers, no MLX.
let package = Package(
    name: "AncestorKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AncestorKit", targets: ["AncestorKit"])
    ],
    targets: [
        .target(name: "AncestorKit", path: "Sources/AncestorKit")
    ]
)
