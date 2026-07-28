import Foundation
import AncestorKit

/// PROFILE_SOURCES_LEDGER_SPEC Change 2 — the read-only per-profile evidence
/// ledger: the records a user has kept for a person (accepted facts / saved
/// leads), read straight from `evidence_records` with **no research run**. This
/// is what closes the "applied facts show only as field values; you must re-run
/// research to re-see the records" gap.
///
/// Pure over the DB read — the view renders `entries`; a later change adds the
/// per-entry removal action on top of the same list.
enum ProfileSourcesLedger {

    /// One kept record, display-ready.
    struct Entry: Identifiable, Sendable, Equatable {
        /// The source record id — stable, and the handle a later removal change
        /// uses to reject the record.
        let id: String
        let sourceID: String
        let recordType: RecordType
        let verdict: RecordVerdict
        /// Full citation (falls back to the scorer summary if none was rendered).
        let citation: String
        let citationURL: String?
        /// What this record lands on the profile ("birth date Dec 1883",
        /// "birth place Belper") — the SAME `absorptionPlan` the write path
        /// executes, so the ledger can't claim a fact the apply didn't write.
        let establishes: [String]
    }

    /// Where a record stands relative to the profile, for the per-fact
    /// evidence expander: `applied` (written to the profile), `rejected`
    /// (user-discarded or scored impossible), or `pending` (researched and
    /// awaiting review). Lets one profile show the whole evidence picture per
    /// fact without re-running research.
    /// Four standings so a fact can show its applied record on top and the
    /// research trail beneath it in three buckets:
    ///   applied         — written to the profile (savedAsLead)
    ///   researched      — found, not yet applied (unreviewed, still scorable)
    ///   userRejected    — the user discarded it
    ///   scorerRejected  — the scorer ruled it impossible
    enum Standing: String, Sendable, Equatable {
        case applied, researched, userRejected, scorerRejected
        var sortOrder: Int {
            switch self {
            case .applied: 0; case .researched: 1; case .userRejected: 2; case .scorerRejected: 3
            }
        }
    }

    /// One evidence record in any standing, display-ready for the per-fact
    /// expander. Distinct from `Entry` (which is applied-only) — this surfaces
    /// rejected and pending records too, with the age→birth-year a death/census
    /// record implies (the field that cracks a namesake birth year).
    struct RecordDetail: Identifiable, Sendable, Equatable {
        let id: String
        let sourceID: String
        let recordType: RecordType
        let verdict: RecordVerdict
        let standing: Standing
        let citation: String
        let citationURL: String?
        /// e.g. "age 44 → b. ~1865" for records that carry an age.
        let ageDetail: String?
        /// Plain-English "why this matches / what it adds" for a BMD index
        /// record vs the applied value — e.g. "Registered in the Jul–Sep
        /// quarter — consistent with 21 Jul 1916. Index district: Bakewell."
        let reconcileNote: String?
        /// Higher = stronger match. Ranks a bucket best-first so a capped
        /// "Showing 20 of 486" shows the plausible candidates, not a random slice.
        let matchRank: Int
    }

    /// EVERY evidence record for the profile (applied, pending, rejected),
    /// classified by standing. The per-fact expander filters these by record
    /// type. Ordered by standing (applied first), then record type, then id.
    static func allRecords(for profileID: String, db: ProjectDatabase, profile: Profile? = nil) throws -> [RecordDetail] {
        try db.loadEvidenceForProfile(profileID)
            .map { rec in
                RecordDetail(
                    id: rec.sourceRecordID,
                    sourceID: rec.sourceID,
                    recordType: rec.recordType,
                    verdict: rec.verdict,
                    standing: standing(userStatus: rec.userStatus, verdict: rec.verdict),
                    citation: (rec.citationFull?.isEmpty == false ? rec.citationFull! : rec.summary),
                    citationURL: rec.citationURL,
                    ageDetail: ageDetail(rec.record),
                    reconcileNote: reconcileNote(rec.record, profile: profile),
                    matchRank: matchRank(verdict: rec.verdict, gates: rec.gates))
            }
            .sorted { a, b in
                if a.standing.sortOrder != b.standing.sortOrder { return a.standing.sortOrder < b.standing.sortOrder }
                if a.matchRank != b.matchRank { return a.matchRank > b.matchRank }  // best match first
                if a.recordType.rawValue != b.recordType.rawValue { return a.recordType.rawValue < b.recordType.rawValue }
                return a.id < b.id
            }
    }

    /// Plain-English reconciliation for a BMD-index record against the applied
    /// value: the quarter↔exact-date relationship (a July birth is registered
    /// in the Jul–Sep quarter) and the registration district (often more precise
    /// than a recorded county). Nil for record types without a quarter/district.
    private static func reconcileNote(_ record: SourceRecord, profile: Profile?) -> String? {
        switch record {
        case .birth(let b):
            return bmdReconcile(quarter: b.quarter, district: b.district, kind: "birth",
                                appliedDate: profile?.birthDate?.original, appliedPlace: profile?.birthLocation)
        case .death(let d):
            return bmdReconcile(quarter: d.quarter, district: d.district, kind: "death",
                                appliedDate: profile?.deathDate?.original, appliedPlace: profile?.deathLocation)
        default:
            return nil
        }
    }

    private static func bmdReconcile(quarter: String?, district: String?, kind: String,
                                     appliedDate: String?, appliedPlace: String?) -> String? {
        var parts: [String] = []
        if let q = quarter, let (range, months) = quarterInfo(q) {
            if let applied = appliedDate, let m = monthToken(applied), months.contains(m) {
                parts.append("Registered in the \(range) quarter — consistent with the \(kind) of \(applied).")
            } else {
                parts.append("Registered in the \(range) quarter.")
            }
        }
        if let d = district?.trimmingCharacters(in: .whitespaces), !d.isEmpty {
            if let place = appliedPlace?.trimmingCharacters(in: .whitespaces), !place.isEmpty,
               !place.localizedCaseInsensitiveContains(d) {
                parts.append("The index gives the registration district (\(d)); the recorded place is \(place) — applying adds the more precise district.")
            } else if appliedPlace?.isEmpty ?? true {
                parts.append("Registration district: \(d).")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Maps a BMD quarter month ("Mar"/"Jun"/"Sep"/"Dec") to its month range
    /// label and the set of month tokens it covers.
    private static func quarterInfo(_ quarter: String) -> (range: String, months: Set<String>)? {
        switch quarter.lowercased().prefix(3) {
        case "mar": ("Jan–Mar", ["jan", "feb", "mar"])
        case "jun": ("Apr–Jun", ["apr", "may", "jun"])
        case "sep": ("Jul–Sep", ["jul", "aug", "sep"])
        case "dec": ("Oct–Dec", ["oct", "nov", "dec"])
        default:     nil
        }
    }

    private static func monthToken(_ text: String) -> String? {
        let lower = text.lowercased()
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            .first { lower.contains($0) }
    }

    /// Rank a record within its bucket: fact over lead over impossible, then by
    /// how many scoring gates it cleared.
    private static func matchRank(verdict: RecordVerdict, gates: [GateResult]) -> Int {
        let base = switch verdict { case .fact: 1000; case .lead: 500; case .impossible: 0 }
        return base + gates.filter { $0.outcome == .pass }.count
    }

    private static func standing(userStatus: UserReviewStatus, verdict: RecordVerdict) -> Standing {
        if userStatus == .savedAsLead { return .applied }
        if userStatus == .discarded { return .userRejected }   // user's call wins over verdict
        if verdict == .impossible { return .scorerRejected }
        return .researched
    }

    /// The age → implied birth year a record carries, if any. Death and census
    /// records state an age; the birth year they imply is the independent
    /// discriminator between same-named people (a namesake soup tie-breaker).
    private static func ageDetail(_ record: SourceRecord) -> String? {
        switch record {
        case .death(let d):
            guard let age = d.age else { return nil }
            if let y = d.deathYear { return "age \(age) → b. ~\(y - age)" }
            return "age \(age)"
        case .census(let c):
            guard let age = c.age else { return nil }
            if let y = c.birthYear { return "age \(age) → b. ~\(y)" }
            return "age \(age) → b. ~\(c.censusYear - age)"
        default:
            return nil
        }
    }

    /// The kept records backing a profile, ordered deterministically (record
    /// type, then id). "Kept" = `savedAsLead` — the status both the apply path
    /// and "Save as lead" write; discarded/unreviewed rows are excluded.
    static func entries(for profileID: String, db: ProjectDatabase, profile: Profile? = nil) throws -> [Entry] {
        try db.loadEvidenceForProfile(profileID)
            .filter { $0.userStatus == .savedAsLead }
            .map { rec in
                Entry(
                    id: rec.sourceRecordID,
                    sourceID: rec.sourceID,
                    recordType: rec.recordType,
                    verdict: rec.verdict,
                    citation: (rec.citationFull?.isEmpty == false ? rec.citationFull! : rec.summary),
                    citationURL: rec.citationURL,
                    establishes: rec.record.absorptionPlan(profileID: profileID, profile: profile).compactMap(\.reviewLabel))
            }
            .sorted { ($0.recordType.rawValue, $0.id) < ($1.recordType.rawValue, $1.id) }
    }
}
