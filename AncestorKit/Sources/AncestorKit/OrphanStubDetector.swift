import Foundation

/// IMPORT_DEDUPE_SPEC — detects orphan-stub duplicates: profiles with NO
/// relationship edges whose name matches an edge-bearing profile.
///
/// The motivating case is Ancestry.com's GEDCOM export: its tree-merge
/// tool leaves the pre-merge stub behind with its family links stripped,
/// producing a bare, dateless, edge-less copy of someone who already
/// exists (properly linked) elsewhere in the same file. The signal —
/// *zero edges* + *name-identical to a linked profile* — is stronger and
/// cheaper than fuzzy name+date similarity, and (unlike `DuplicateDetectionRule`)
/// catches the surname-only case where the stub has no given name at all.
///
/// Pure over a snapshot; the rule (surfacing) and `ProfileMergeEngine`
/// (execution) both consume it, so they can never disagree.
public nonisolated struct OrphanStubCandidate: Sendable, Equatable {
    public let stubID: String
    public let targetID: String
    /// Human-readable reason, carried into the audit message so the review
    /// surface explains itself ("bare surname-only match to a linked profile").
    public let matchBasis: String
    /// The stub carries NO distinguishing data beyond its name (no dates,
    /// no locations, no bio) — so removing it loses nothing. This is the
    /// safe-to-cleanse subset; non-empty stubs need a real field merge.
    public let stubIsEmpty: Bool
}

public nonisolated enum OrphanStubDetector {

    /// A profile is a *stub* when it has zero relationship edges. It is a
    /// *cleansable empty stub* when it additionally carries no dates,
    /// locations, or bio — just a name (and possibly gender).
    public static func isEdgeless(_ id: String, relationships: [Relationship]) -> Bool {
        !relationships.contains { $0.from == id || $0.to == id }
    }

    public static func isEmpty(_ p: Profile) -> Bool {
        p.birthDate == nil && p.deathDate == nil
            && (p.birthLocation ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (p.deathLocation ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (p.bio ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func norm(_ s: String?) -> String {
        (s ?? "").uppercased()
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    /// Every (stub, target) candidate pair. A stub may match multiple
    /// targets (the same name across generations) — each is its own
    /// candidate; the detector never guesses which is "right".
    public static func candidates(in snapshot: FamilyGraphSnapshot) -> [OrphanStubCandidate] {
        let rels = snapshot.relationships
        let profiles = Array(snapshot.profiles.values)

        // Edge-bearing profiles are the only valid targets.
        let edgeBearing = profiles.filter { !isEdgeless($0.id, relationships: rels) }

        var out: [OrphanStubCandidate] = []
        for stub in profiles where isEdgeless(stub.id, relationships: rels) {
            let stubSurname = norm(stub.lastName)
            let stubGiven = norm(stub.firstName)
            guard !stubSurname.isEmpty || !stubGiven.isEmpty else { continue }
            let empty = isEmpty(stub)

            for target in edgeBearing where target.id != stub.id {
                let tSurname = norm(target.lastName)
                let tGiven = norm(target.firstName)
                guard tSurname == stubSurname else { continue }

                let basis: String?
                if stubGiven.isEmpty {
                    // Surname-only stub (the Carter case) — the exact shape
                    // DuplicateDetectionRule's 0.7 threshold cannot reach.
                    basis = "surname-only stub matches linked profile '\(target.displayName)'"
                } else if tGiven == stubGiven {
                    basis = "identical name to linked profile '\(target.displayName)'"
                } else {
                    basis = nil
                }
                guard let matchBasis = basis else { continue }
                out.append(OrphanStubCandidate(
                    stubID: stub.id, targetID: target.id,
                    matchBasis: matchBasis, stubIsEmpty: empty))
            }
        }
        // Deterministic order for stable UI + tests.
        return out.sorted { ($0.stubID, $0.targetID) < ($1.stubID, $1.targetID) }
    }

    /// Distinct stub IDs that are empty AND have at least one target — the
    /// safe one-click cleanse set surfaced at import time.
    public static func cleansableEmptyStubIDs(in snapshot: FamilyGraphSnapshot) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for c in candidates(in: snapshot) where c.stubIsEmpty {
            if seen.insert(c.stubID).inserted { ordered.append(c.stubID) }
        }
        return ordered
    }
}
