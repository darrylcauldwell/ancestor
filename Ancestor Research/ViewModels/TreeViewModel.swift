import SwiftUI

/// View model for the interactive tree graph.
@MainActor @Observable
final class TreeViewModel {
    var layout: TreeLayout.LayoutResult = .init(nodes: [], edges: [], width: 0, height: 0)
    var selectedProfileID: String?
    var rootProfileID: String?
    var viewMode: TreeViewMode = .pedigree
    var scale: Double = 1.0
    var offset: CGSize = .zero
    var searchText: String = ""

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
    }

    /// Select a profile and optionally make it the root.
    func selectProfile(_ id: String) {
        selectedProfileID = id
    }

    func setRoot(_ id: String, snapshot: FamilyGraphSnapshot) {
        rootProfileID = id
        rebuildLayout(snapshot: snapshot)
    }

    func clearRoot(snapshot: FamilyGraphSnapshot) {
        rootProfileID = nil
        rebuildLayout(snapshot: snapshot)
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
