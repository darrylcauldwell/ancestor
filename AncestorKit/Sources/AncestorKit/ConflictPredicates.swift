import Foundation

/// CONFLICT_LAYER_SPEC §4.2/§4.8 — shared deterministic predicates behind
/// the F3/F4a/T-D detection rules.
///
/// Both producers consume these: the app-side `ConflictSweep`/`ConflictDetector`
/// (writing dispute rows) and the AncestorKit `AuditRule` wrappers
/// (`ParentsPerRoleRule`, `RecordAfterDeathRule`). One predicate, two
/// surfaces — the audit pass and the sweep can never disagree (CL2 AC2).
public nonisolated enum ConflictPredicates {

    /// Life-event types that constitute alive-evidence: a person recorded
    /// by one of these was alive at the event date (F3, DS-15).
    public static let aliveEvidenceTypes: Set<LifeEventType> = [
        .census, .residence, .occupation, .militaryService, .religion,
    ]

    /// F3 — alive-evidence events strictly AFTER the given year.
    /// `year` is typically `deathDate.latest` (or a burial/probate year
    /// for the symmetric arm). Events without a parseable year never fire.
    public static func aliveEvidence(
        afterYear year: Int,
        in events: [LifeEvent]
    ) -> [(event: LifeEvent, year: Int)] {
        events.compactMap { event in
            guard aliveEvidenceTypes.contains(event.type),
                  let eventYear = event.date?.earliest,
                  eventYear > year else { return nil }
            return (event, eventYear)
        }
    }

    /// F4a — biological parent roles occupied by MORE than one distinct
    /// profile. One person has one biological father and one biological
    /// mother (DS-26); a role with ≥2 distinct occupants is a conflict.
    public static func duplicateBiologicalParentEdges(
        subjectID: String,
        relationships: [Relationship]
    ) -> [ParentRole: [Relationship]] {
        var byRole: [ParentRole: [Relationship]] = [:]
        for edge in relationships
        where edge.type == .parent
            && edge.to == subjectID
            && edge.subtype == .biological {
            guard let role = edge.role, role == .father || role == .mother else { continue }
            byRole[role, default: []].append(edge)
        }
        return byRole.filter { _, edges in
            Set(edges.map(\.from)).count >= 2
        }
    }

    /// T-D (tree-state arm) ⟨G13⟩ — census life-events grouped by year
    /// where one subject carries ≥2 events for the SAME census year. One
    /// person is enumerated once per census year; duplicates are an
    /// impossibility, never corroboration.
    public static func sameYearCensusDuplicates(
        in events: [LifeEvent]
    ) -> [Int: [LifeEvent]] {
        var byYear: [Int: [LifeEvent]] = [:]
        for event in events where event.type == .census {
            guard let year = event.date?.earliest else { continue }
            byYear[year, default: []].append(event)
        }
        return byYear.filter { $0.value.count >= 2 }
    }
}
