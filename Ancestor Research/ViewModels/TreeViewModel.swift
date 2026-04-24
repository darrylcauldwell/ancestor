import SwiftUI

/// View model for the interactive tree graph.
@MainActor @Observable
final class TreeViewModel {
    var layout: TreeLayout.LayoutResult = .init(nodes: [], edges: [], width: 0, height: 0, rootID: nil)
    var selectedProfileID: String?
    var rootProfileID: String?
    var viewMode: TreeViewMode = .pedigree
    var scale: Double = 1.0
    var offset: CGSize = .zero
    var searchText: String = ""
    var visibleGenerations: Int = 4

    // Navigation history for back/forward
    private var history: [String] = []
    private var historyIndex: Int = -1

    var canGoBack: Bool { historyIndex > 0 }

    /// Rebuild layout from the current snapshot.
    func rebuildLayout(snapshot: FamilyGraphSnapshot) {
        if let rootID = rootProfileID {
            switch viewMode {
            case .pedigree:
                layout = TreeLayout.pedigreeLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
            case .descendants:
                layout = TreeLayout.descendantLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
            case .overview:
                layout = TreeLayout.overviewLayout(snapshot: snapshot)
            }
        } else {
            layout = TreeLayout.overviewLayout(snapshot: snapshot)
        }
        // Auto-scale to fit tree in viewport, but keep nodes readable
        let viewportWidth: Double = 1400
        let viewportHeight: Double = 900
        let scaleX = layout.width > 0 ? viewportWidth / layout.width : 1.0
        let scaleY = layout.height > 0 ? viewportHeight / layout.height : 1.0
        scale = max(min(scaleX, scaleY, 1.0), 0.4)  // Min 0.4 to keep nodes legible

        offset = .zero
    }

    /// Recenter the view on a different person with history tracking.
    func recenter(on profileID: String, snapshot: FamilyGraphSnapshot) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(profileID)
        historyIndex = history.count - 1

        rootProfileID = profileID
        selectedProfileID = profileID
        rebuildLayout(snapshot: snapshot)
    }

    /// Navigate back in history.
    func goBack(snapshot: FamilyGraphSnapshot) {
        guard canGoBack else { return }
        historyIndex -= 1
        rootProfileID = history[historyIndex]
        selectedProfileID = rootProfileID
        rebuildLayout(snapshot: snapshot)
    }

    func selectProfile(_ id: String) {
        selectedProfileID = id
    }

    func setRoot(_ id: String, snapshot: FamilyGraphSnapshot) {
        recenter(on: id, snapshot: snapshot)
    }

    /// Zoom = show more/fewer generations from the focal person.
    func zoomIn(snapshot: FamilyGraphSnapshot) {
        visibleGenerations = max(visibleGenerations - 1, 2)
        rebuildLayout(snapshot: snapshot)
    }
    func zoomOut(snapshot: FamilyGraphSnapshot) {
        visibleGenerations = min(visibleGenerations + 1, 10)
        rebuildLayout(snapshot: snapshot)
    }
    func zoomToFit(snapshot: FamilyGraphSnapshot) {
        visibleGenerations = 4
        rebuildLayout(snapshot: snapshot)
    }

    /// Filtered profiles for search.
    func filteredNodes() -> [TreeLayout.LayoutNode] {
        guard !searchText.isEmpty else { return layout.nodes }
        let query = searchText.lowercased()
        return layout.nodes.filter {
            $0.profile.displayName.lowercased().contains(query)
        }
    }
}

nonisolated enum TreeViewMode: String, CaseIterable {
    case pedigree = "Pedigree"
    case descendants = "Descendants"
    case overview = "Overview"
}
