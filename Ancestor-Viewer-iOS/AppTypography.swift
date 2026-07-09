import SwiftUI
import AncestorKitUI

/// Typography tokens for the iOS viewer. SwiftUI views use dynamic-type
/// tokens; the canvas theme uses fixed sizes (Canvas has no dynamic type)
/// — text scales with canvas zoom instead.
enum AppTypography {
    // Dynamic-type tokens
    static let cardTitle = Font.headline
    static let cardBody = Font.body
    static let cardMeta = Font.callout
    static let badge = Font.caption.weight(.medium)
    static let controlLabel = Font.callout.weight(.medium)
    static let toast = Font.callout

    // Screen-level
    static let screenTitle = Font.largeTitle.weight(.bold)
    static let panelName = Font.title3.weight(.semibold)
    static let panelVitals = Font.callout
    static let panelBio = Font.body
    static let timelineYear = Font.callout.weight(.semibold)

    // Canvas theme — fixed sizes, phone/tablet scale
    static let treeCanvasTheme = TreeCanvasTheme(
        name: .system(size: 13, weight: .semibold),
        nameSmall: .system(size: 11, weight: .medium),
        dates: .system(size: 11),
        location: .system(size: 10),
        badge: .system(size: 10, weight: .medium),
        infoIcon: .system(size: 14),
        arrow: .system(size: 11, weight: .medium),
        controlAccent: .accentColor)
}
