// Re-export the portable domain core so existing app and test sources
// keep referencing Profile / Relationship / GenealogicalDate etc.
// without per-file imports. New platform targets (viewers, publisher)
// import AncestorKit directly instead.
@_exported import AncestorKit
@_exported import AncestorKitUI
