import Foundation

/// Pure planning for the "excess / placeholder parents" repair (audit rule
/// `excessParentEdges`, `ExcessParentEdgesRule`). Kept free of AppState and the
/// database so it is unit-testable against a `FamilyGraphSnapshot`.
/// `AppState.repairExcessPlaceholderParents` applies the returned plan through
/// its transactional mutators.
///
/// Background: the sibling-shortcut direction bug (owner report 2026-07-16)
/// wired an orphan's blank *placeholder* parents onto established profiles that
/// already had real parents — three Twyford sisters each ended up with the same
/// two blank stubs as extra parents. The repair absorbs those stubs into the
/// child's real parents: every sibling that shared a stub is re-homed onto the
/// real parents, then the stubs are unlinked and deleted.
///
/// Junk is identified by `Profile.isAnonymousStub` — the SAME predicate
/// `ExcessParentEdgesRule` uses — so the finding and the repair can never
/// disagree about what to strip. Dangling parent edges (pointing at a profile
/// that no longer exists) also count as junk to remove.
nonisolated enum PlaceholderParentRepair {

    nonisolated struct Plan: Equatable {
        /// Parent edges to add: each sibling gets re-homed onto every real parent.
        var rehome: [Rehome]
        /// Junk parent edges to remove (every edge from every junk/stub parent).
        var removeEdgeIDs: [UUID]
        /// Junk stub profiles to soft-delete once unlinked. Excludes dangling
        /// IDs that have no profile.
        var deleteStubIDs: [String]

        nonisolated struct Rehome: Equatable {
            let parentID: String
            let role: ParentRole?
            let childID: String
        }
    }

    /// The repair plan for `childID`, or nil when there's nothing to do: no junk
    /// stub parents, or no *named* parent to absorb into (the legitimate
    /// unknown-couple case, not this bug). Dedupe is computed against the
    /// original snapshot, so a re-home that already exists is never emitted.
    static func plan(childID: String, snapshot: FamilyGraphSnapshot) -> Plan? {
        let parentEdges = snapshot.relationships.filter { $0.type == .parent && $0.to == childID }

        // Junk parents: anonymous stubs, plus dangling edges to a missing profile.
        let junkParentIDs = Set(parentEdges.map(\.from).filter {
            snapshot.profiles[$0]?.isAnonymousStub ?? true
        })
        guard !junkParentIDs.isEmpty else { return nil }

        // Named parents of the child, with their roles — the absorb targets.
        let realParentEdges: [(id: String, role: ParentRole?)] = parentEdges
            .filter { !junkParentIDs.contains($0.from) }
            .map { (id: $0.from, role: $0.role) }
        guard !realParentEdges.isEmpty else { return nil }

        // Everyone who shares a junk parent (the siblings to re-home) and every
        // edge from a junk parent (to remove).
        var siblingIDs = Set<String>()
        var removeEdgeIDs = Set<UUID>()
        for edge in snapshot.relationships
        where edge.type == .parent && junkParentIDs.contains(edge.from) {
            siblingIDs.insert(edge.to)
            removeEdgeIDs.insert(edge.id)
        }

        var rehome: [Plan.Rehome] = []
        for sib in siblingIDs.sorted() {
            for parent in realParentEdges {
                let already = snapshot.relationships.contains {
                    $0.type == .parent && $0.from == parent.id && $0.to == sib
                }
                guard !already else { continue }
                rehome.append(.init(parentID: parent.id, role: parent.role, childID: sib))
            }
        }

        // Only real profiles can be deleted; dangling IDs have nothing to delete.
        let deleteStubIDs = junkParentIDs.filter { snapshot.profiles[$0] != nil }

        return Plan(
            rehome: rehome,
            removeEdgeIDs: removeEdgeIDs.sorted { $0.uuidString < $1.uuidString },
            deleteStubIDs: deleteStubIDs.sorted()
        )
    }
}
