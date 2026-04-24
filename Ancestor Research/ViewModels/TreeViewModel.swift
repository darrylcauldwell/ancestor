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

    // Navigation history for back/forward
    private var history: [String] = []
    private var historyIndex: Int = -1

    var canGoBack: Bool { historyIndex > 0 }

    /// Rebuild layout from the current snapshot.
    func rebuildLayout(snapshot: FamilyGraphSnapshot) {
        if let rootID = rootProfileID {
            switch viewMode {
            case .pedigree:
                layout = TreeLayout.pedigreeLayout(rootID: rootID, snapshot: snapshot)
            case .descendants:
                layout = TreeLayout.descendantLayout(rootID: rootID, snapshot: snapshot)
            case .overview:
                layout = TreeLayout.overviewLayout(snapshot: snapshot)
            }
        } else {
            layout = TreeLayout.overviewLayout(snapshot: snapshot)
        }
        offset = .zero
        scale = 1.0
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

    /// Zoom controls.
    func zoomIn() { scale = min(scale * 1.25, 4.0) }
    func zoomOut() { scale = max(scale / 1.25, 0.1) }
    func zoomToFit() { scale = 1.0; offset = .zero }

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
