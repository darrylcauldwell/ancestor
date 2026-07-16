import Foundation

/// EVIDENCE_ABSORPTION_SPEC Change 4 — the single declarative enumeration of
/// everything a record absorbs into a profile, each fact routed to its home.
///
/// Before this, the routing lived in three hand-written places that had to be
/// kept in lockstep by hand: `ApplyEngine.applyFactToSubject`'s per-type switch
/// (identity fields + spouse edge), its corroboration tail (implied dates), and
/// `SourceRecord.projectToLifeEvents` (typed events). `absorptionPlan` folds all
/// three into one ordered list so:
///   - the write path (`applyFactToSubject`) *executes* the plan, and
///   - the review preview (Change 5) *displays* the same plan,
/// which is why the two can never drift — the drift bug the firewall/absorption
/// design exists to prevent (see the spec's "Why 4 before 5" note).
///
/// This is a behaviour-preserving refactor: the plan reproduces the exact set
/// and order of writes the old switch+tail produced, so the test suite stays
/// identically green.
enum Absorption {
    /// A date field (`.birthDate` / `.deathDate`) — executed through the
    /// directional overwrite policy (`ApplyEngine.applyDateField`).
    case dateField(ProfileField, GenealogicalDate)
    /// A string field (`.birthLocation` / `.deathLocation`) — executed through
    /// `ApplyEngine.applyStringField`.
    case stringField(ProfileField, String)
    /// A subject-side marriage → spouse-edge fill (the relationship home, with
    /// its own conflict detection).
    case spouseEdge(MarriageRecord)
    /// A typed timeline event (census / occupation / residence / burial / …).
    /// Executed by the caller via `addLifeEventIfAbsent`, not by
    /// `applyFactToSubject`.
    case lifeEvent(LifeEvent)
}

nonisolated extension SourceRecord {

    /// The complete, ordered absorption plan for this record. Order matches the
    /// legacy write sequence exactly: primary identity fields / spouse edge
    /// first, then the implied-date corroboration tail (Change 3), then the
    /// typed life events (Change 2/3 fan-out). Only present values appear —
    /// a nil/empty candidate was a no-op in the old code and is simply omitted
    /// here, which is also what the review preview wants to show.
    func absorptionPlan(profileID: String) -> [Absorption] {
        var items: [Absorption] = []

        // 1. Primary identity fields + spouse edge (was the per-type switch).
        switch self {
        case .birth(let r):
            if let date = ApplyEngine.bmdDate(year: r.birthYear, quarter: r.quarter, exact: r.birthDate) {
                items.append(.dateField(.birthDate, date))
            }
            if let loc = nonEmpty(r.birthPlace ?? r.district) {
                items.append(.stringField(.birthLocation, loc))
            }
        case .death(let r):
            if let date = ApplyEngine.bmdDate(year: r.deathYear, quarter: r.quarter, exact: r.deathDate) {
                items.append(.dateField(.deathDate, date))
            }
            if let loc = nonEmpty(r.deathPlace ?? r.district) {
                items.append(.stringField(.deathLocation, loc))
            }
        case .marriage(let m):
            items.append(.spouseEdge(m))
        case .census(let r):
            if let loc = ApplyEngine.censusBirthLocation(r) {
                items.append(.stringField(.birthLocation, loc))
            }
        case .burial, .military, .probate, .parish, .pedigree:
            break  // no primary field write — corroboration below may still fire
        }

        // 2. Implied-date corroboration (Change 3). impliedBirthDate/DeathDate
        //    return nil precisely for the type whose primary case already wrote
        //    that field (.birth / .death), so a field is never written twice.
        if let birth = ApplyEngine.impliedBirthDate(for: self) {
            items.append(.dateField(.birthDate, birth))
        }
        if let death = ApplyEngine.impliedDeathDate(for: self) {
            items.append(.dateField(.deathDate, death))
        }

        // 3. Typed life events (Change 2/3 fan-out + primary event).
        items.append(contentsOf: projectToLifeEvents(profileID: profileID).map(Absorption.lifeEvent))

        return items
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}
