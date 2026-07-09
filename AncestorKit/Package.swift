// swift-tools-version:6.1
import PackageDescription

// AncestorKit — the portable domain core of Ancestor Research
// (ARCHITECTURE_REVIEW_2026-07.md Phase 2). Pure Foundation value
// types shared by the macOS app today and the iPad/tvOS viewers,
// CloudKit publisher, and MCP surface tomorrow. No UI, no GRDB,
// no scrapers, no MLX.
let package = Package(
    name: "AncestorKit",
    // iOS/tvOS added for the Phase 4 viewers (PHASE4_VIEWER_SPEC Change 1) —
    // the sources are Foundation/SwiftUI-pure, so no code changes needed.
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("26.0")],
    products: [
        .library(name: "AncestorKit", targets: ["AncestorKit"]),
        .library(name: "AncestorKitUI", targets: ["AncestorKitUI"])
    ],
    targets: [
        .target(name: "AncestorKit", path: "Sources/AncestorKit"),
        // SwiftUI-dependent shared rendering (Canvas tree renderer, display
        // metrics). Separate target so the Foundation-pure core stays clean;
        // Canvas is available on macOS/iOS/tvOS alike.
        .target(name: "AncestorKitUI", dependencies: ["AncestorKit"], path: "Sources/AncestorKitUI")
    ]
)
