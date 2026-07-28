import Foundation
import AncestorKit

/// CENSUS_PARENT_UNLOCK_SPEC Change 2 — surfaces a parentless ancestor whose
/// childhood census (them as a child in the parental home) is already among
/// their research leads but was never promoted, because the scorer confirms via
/// a family match it cannot make (the parents aren't on the tree yet).
///
/// Pure over one profile's census evidence + its tree facts. `AppState` scans the
/// tree and feeds each parentless profile's rows in. The fix ranks the census
/// leads with `ChildhoodCensusRanker` (county then age, no family match) and
/// applies the winner — whereupon the shipped `CensusRelationshipReconciler`
/// "Add census relatives" flow lifts its Head + Wife as the parents.
nonisolated enum CensusParentUnlockAudit {
    static let ruleID = "censusParentUnlock"

    /// Ranker candidates from a profile's census evidence. Each census records
    /// where the person was *born*, so the census-stated birth county is the
    /// county-match signal (fall back to birthplace, then residence). The implied
    /// birth year comes from the census's own birth year or `censusYear − age`.
    ///
    /// Records the scorer already ruled `.impossible` (wrong sex/era/geography
    /// namesakes — the bulk of a frontier ancestor's census leads) are excluded:
    /// the ranker disambiguates among the *survivors*, it does not re-litigate
    /// what the four-gate scorer already killed.
    static func candidates(from evidence: [EvidenceRecord]) -> [ChildhoodCensusRanker.Candidate] {
        evidence.compactMap { e in
            guard e.verdict != .impossible, case .census(let c) = e.record else { return nil }
            let implied = c.birthYear ?? c.age.map { c.censusYear - $0 }
            let place = c.birthCounty ?? c.birthPlace ?? c.district ?? c.parish
            return ChildhoodCensusRanker.Candidate(
                id: e.id, censusYear: c.censusYear, impliedBirthYear: implied, place: place)
        }
    }

    /// The finding for a parentless profile with a rankable childhood census, else
    /// nil. `hasParents` and the subject's own `birthYear`/`birthLocation` come
    /// from the tree; `evidence` is that profile's census rows (applied or lead).
    /// `relatedProfileIDs` carries the winning census evidence id for the fix.
    static func finding(profileID: String, profileName: String,
                        birthYear: Int?, birthLocation: String?,
                        hasParents: Bool, evidence: [EvidenceRecord]) -> AuditResult? {
        guard !hasParents, let year = birthYear else { return nil }
        let cands = candidates(from: evidence)
        guard let best = ChildhoodCensusRanker.best(
            subjectBirthYear: year, subjectCounty: birthLocation, candidates: cands)
        else { return nil }

        let where_ = ChildhoodCensusRanker.normalizeCounty(best.place)
            .map { " in \($0.capitalized)" } ?? ""
        let message = "\(profileName) has no parents on the tree, but their "
            + "\(best.censusYear) childhood census\(where_) is already found — "
            + "apply it to name their parents from the household."

        // Naming a parentless ancestor's parents is the highest-value unlock a
        // tree offers — a whole new generation of real people — so it's an
        // actionable warning, never cosmetic info.
        return AuditResult(
            profileID: profileID, profileName: profileName,
            severity: .warning, category: .gap,
            ruleID: ruleID, message: message,
            relatedProfileIDs: [best.id])
    }
}
