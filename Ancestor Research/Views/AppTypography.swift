import SwiftUI

/// Shared typography for consistent sizing across all views.
/// Built on SwiftUI's dynamic type — respects system font size preferences.
enum AppTypography {
    // MARK: - Card Content (Audit, Gaps, Popover, Inspector)

    /// Profile name in a card or list row
    static let cardTitle: Font = .callout.weight(.semibold)

    /// Secondary detail text (message, missing fields, dates)
    static let cardBody: Font = .callout

    /// Tertiary metadata (birth year inline, source origin)
    static let cardMeta: Font = .caption

    /// Small badges and labels (source badges, filter counts)
    static let badge: Font = .caption2

    // MARK: - Popover (larger context, standalone panel)

    /// Popover header — profile name
    static let popoverTitle: Font = .title3.weight(.bold)

    /// Popover field labels ("Born", "Died", "Gender")
    static let popoverLabel: Font = .caption

    /// Popover field values (dates, locations)
    static let popoverValue: Font = .callout

    // MARK: - Toolbar & Controls

    /// Generation counter, summary stats
    static let controlLabel: Font = .caption

    /// Breadcrumb trail entries
    static let breadcrumb: Font = .caption

    /// Toast messages, coach marks
    static let toast: Font = .caption

    // MARK: - Canvas Node (fixed sizes for Canvas rendering)
    // These use explicit point sizes because Canvas doesn't support dynamic type.
    // They scale with the canvas zoom (treeVM.scale) instead.

    /// Node name at full zoom
    static let canvasName: Font = .system(size: 13, weight: .medium)

    /// Node dates at full zoom
    static let canvasDates: Font = .system(size: 11)

    /// Node location at high zoom
    static let canvasLocation: Font = .system(size: 9)

    /// Node name at low zoom
    static let canvasNameSmall: Font = .system(size: 10)

    /// Completeness badge on node
    static let canvasBadge: Font = .system(size: 9, weight: .semibold)

    /// Info icon on selected node
    static let canvasInfoIcon: Font = .system(size: 16, weight: .semibold)

    /// Arrow indicator text ("▲ 2 parents")
    static let canvasArrow: Font = .system(size: 9, weight: .medium)

    /// Source badge text in popover/inspector
    static let sourceBadge: Font = .system(size: 8, weight: .bold)
}
