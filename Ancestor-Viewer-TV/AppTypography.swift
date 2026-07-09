import SwiftUI
import AncestorKitUI

/// Typography tokens for the tvOS viewer. SwiftUI views use dynamic-type
/// tokens; the canvas theme uses fixed sizes (Canvas has no dynamic type)
/// sized up for 10-ft viewing.
enum AppTypography {
    // Dynamic-type tokens
    static let cardTitle = Font.title3.weight(.semibold)
    static let cardBody = Font.body
    static let cardMeta = Font.callout
    static let badge = Font.caption.weight(.medium)
    static let controlLabel = Font.callout.weight(.medium)
    static let toast = Font.callout

    // Screen-level
    static let screenTitle = Font.largeTitle.weight(.bold)
    static let panelName = Font.title2.weight(.semibold)
    static let panelVitals = Font.callout
    static let panelBio = Font.body
    static let timelineYear = Font.callout.weight(.semibold)

    // Canvas theme — fixed sizes, 10-ft scale
    static let treeCanvasTheme = TreeCanvasTheme(
        name: .system(size: 22, weight: .semibold),
        nameSmall: .system(size: 17, weight: .medium),
        dates: .system(size: 16),
        location: .system(size: 14),
        badge: .system(size: 14, weight: .medium),
        infoIcon: .system(size: 20),
        arrow: .system(size: 16, weight: .medium),
        controlAccent: .accentColor)
}
