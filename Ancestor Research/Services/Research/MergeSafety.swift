import Foundation
import AncestorKit

/// The guard that stops a profile merge from re-creating a patronymic muddle.
///
/// "Possible duplicate" flags carry false positives — most dangerously
/// same-named **father/son** pairs (Ernest Cauldwell stub vs. Ernest b.1887).
/// Merging those collapses two real people into one — the exact Abraham
/// failure. So before any merge, assess whether the two profiles look like the
/// same person, a definite pair of different people, or something to verify.
///
/// Pure and nonisolated so it's unit-tested without a database.
nonisolated enum MergeSafety {
    enum Assessment: Equatable {
        /// Safe to merge without extra warning (e.g. matching birth years).
        case ok
        /// Mergeable, but the profiles diverge in a way that could mean
        /// different people — surface the reason and make the user confirm.
        case warn(String)
        /// Refuse: a structural impossibility (they're linked as parent/child).
        case blocked(String)
    }

    /// Two birth years within this are the same person; beyond it, different
    /// people (a father and son are ≥16 apart).
    static let sameBirthYearTolerance = 2

    static func assess(left: Profile, right: Profile, relationships: [Relationship]) -> Assessment {
        // Hard block: directly linked as parent and child. Merging a parent
        // into their child collapses two generations — never allowed.
        let directParentChild = relationships.contains { r in
            r.type == .parent &&
            ((r.from == left.id && r.to == right.id) || (r.from == right.id && r.to == left.id))
        }
        if directParentChild {
            return .blocked("These two are linked as parent and child — they can't be the same person.")
        }

        // Both dated: birth years are the strongest discriminator.
        if let lb = left.birthDate?.bestYear, let rb = right.birthDate?.bestYear {
            if abs(lb - rb) > sameBirthYearTolerance {
                return .warn("Birth years differ (\(lb) vs \(rb)) — likely different people (e.g. a father and son). Verify before merging.")
            }
            return .ok  // matching birth years — confident it's one person
        }

        // At least one has no birth year — can't confirm same person. Divergent
        // parents is a strong "different people" signal.
        let leftParents = Set(relationships.filter { $0.type == .parent && $0.to == left.id }.map(\.from))
        let rightParents = Set(relationships.filter { $0.type == .parent && $0.to == right.id }.map(\.from))
        if !leftParents.isEmpty, !rightParents.isEmpty, leftParents.isDisjoint(with: rightParents) {
            return .warn("These profiles have different parents — they may be different people. Verify before merging.")
        }

        // Neither dated and no contradiction → let it through (import stubs).
        if left.birthDate?.bestYear == nil && right.birthDate?.bestYear == nil {
            return .ok
        }

        // One dated, one not, nothing contradictory — still worth a caution.
        return .warn("One profile has no birth date — verify these are the same person, not e.g. a father and son, before merging.")
    }
}
