import Foundation

/// Defines capturable screens for App Store screenshots.
/// Launch arguments: --screenshot-mode --screenshot-screen <name>
nonisolated enum ScreenshotScreen: String, CaseIterable {
    case treePedigree = "tree-pedigree"
    case treeDescendants = "tree-descendants"
    case audit = "audit"
    case research = "research"

    static var isScreenshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
    }

    static func fromLaunchArguments() -> ScreenshotScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--screenshot-screen"),
              index + 1 < args.count else {
            return nil
        }
        return ScreenshotScreen(rawValue: args[index + 1])
    }
}
