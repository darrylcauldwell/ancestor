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

    /// How a ledger entry got onto the profile — and therefore which removal
    /// path can reverse it.
    ///
    /// `.sourceRecord` is the classic case: an `evidence_records` row that
    /// passed the 4-gate scorer, whose absorption `removeAppliedRecord` can
    /// re-derive and invert.
    ///
    /// `.appliedFact` is a fact that landed with NO evidence record — the
    /// pending-facts accept path, the MCP auto-approval commit, a promoted
    /// lead. All that survives is one `field_sources` row, so removal is keyed
    /// on its rowid. These never met the scorer, and the UI must not imply
    /// they did (owner dogfood 2026-08-21: three contradictory death dates
    /// accepted in review, with no way to take any of them off).
    enum Provenance: Sendable, Equatable {
        case sourceRecord(recordType: RecordType, verdict: RecordVerdict)
        case appliedFact(AppliedFactTarget)
    }

    /// One kept record OR one applied-but-unbacked fact, display-ready.
    struct Entry: Identifiable, Sendable, Equatable {
        /// `.sourceRecord` → the evidence `sourceRecordID`. `.appliedFact` →
        /// `"fs:<rowid>"`. Two disjoint namespaces, so a removal can never
        /// resolve one kind through the other kind's lookup.
        let id: String
        let sourceID: String
        let provenance: Provenance
        /// Full citation (falls back to the scorer summary if none was rendered).
        let citation: String
        let citationURL: String?
        /// What this entry lands on the profile ("birth date Dec 1883",
        /// "birth place Belper"). For a record it is the SAME `absorptionPlan`
        /// the write path executes, so the ledger can't claim a fact the apply
        /// didn't write; for an applied fact it is the single field and value
        /// its provenance row carries.
        let establishes: [String]

        /// nil for an applied fact, which has no scored record type or verdict.
        /// Existing `#expect(entry.recordType == .birth)` still compiles via
        /// Optional promotion.
        var recordType: RecordType? {
            if case .sourceRecord(let type, _) = provenance { return type }
            return nil
        }
        var verdict: RecordVerdict? {
            if case .sourceRecord(_, let verdict) = provenance { return verdict }
            return nil
        }
        var isSourceRecord: Bool {
            if case .sourceRecord = provenance { return true }
            return false
        }
        /// Stable secondary sort key across both kinds.
        var sortKey: String {
            switch provenance {
            case .sourceRecord(let type, _): type.rawValue
            case .appliedFact(let target): target.field
            }
        }
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
        /// Every underlying evidence source-record id collapsed into this row —
        /// the same entry can be saved more than once across runs (different
        /// scrape ids, same vol/page). Removal cleans them all.
        var duplicateIDs: [String]
        /// GRO registration identity (type|vol|page|year|district) when the
        /// record carries one — twin index rows of the same registration share
        /// it even when their transcriptions (and so citations) differ.
        var registrationKey: String?
        /// The census roster this record carries, when it has one. A CANDIDATE
        /// census's household is the evidence that picks it out of a namesake
        /// pile — a 14-year-old's parents and siblings are named on the page —
        /// so the ledger row carries it and can show it BEFORE the record is
        /// applied (owner dogfood 2026-08-22: three mutually-exclusive 1861
        /// Samuel Holmes censuses, and the only route to any household was to
        /// apply one first and read the evidence afterwards).
        var household: [HouseholdMember] = []
        /// A census with a detail page but no roster yet — the "Load household"
        /// affordance. Fetch-only: it changes no facts.
        var canLoadHousehold: Bool = false
        /// The census year this record belongs to, so its evidence can sit with
        /// the life event for that census rather than in a separate list.
        var censusYear: Int?
        /// A parish record whose EVENT is a marriage. FreeREG church marriages
        /// arrive typed `.parish`, so the spouse row's `.marriage` filter never
        /// showed them — Mary Stevenson's Youlgreave wedding (the record whose
        /// detail names both fathers) was invisible beside the very spouse
        /// edge it attests, while the civil index entry sat there alone
        /// (owner dogfood 2026-08-23).
        var isParishMarriage: Bool = false
        /// A parish baptism/christening — birth-context evidence, same hole
        /// one section over: the Birth expander accepted `.baptism` but
        /// FreeREG rows are typed `.parish`, so church baptisms never
        /// appeared beside the birth they date.
        var isParishBaptism: Bool = false
        /// A parish burial — death-context evidence, same hole again.
        var isParishBurial: Bool = false
        /// A parish record with a register-entry page not yet fetched — the
        /// "Details" affordance (twin of `canLoadHousehold`). Fetch-only:
        /// it changes no facts.
        var canLoadParishDetail: Bool = false
        /// The family this parish record names — "Father John STEPHENSON ·
        /// Mother Lydia" — so a CANDIDATE baptism's parents are readable
        /// BEFORE it is applied (the household-roster rationale, parish-side:
        /// the kin on the page is what picks one entry out of a namesake pile).
        var parishKinLine: String? = nil
    }

    /// Whether a parish record's event is a marriage (false for every other
    /// record type). Pure.
    nonisolated static func isParishMarriage(_ record: SourceRecord) -> Bool {
        parishEventContains(record, any: ["marriage"])
    }

    /// Whether a parish record's event is a baptism or christening. Pure.
    nonisolated static func isParishBaptism(_ record: SourceRecord) -> Bool {
        parishEventContains(record, any: ["bapt", "christen"])
    }

    /// Whether a parish record's event is a burial. Pure.
    nonisolated static func isParishBurial(_ record: SourceRecord) -> Bool {
        parishEventContains(record, any: ["burial", "buri"])
    }

    nonisolated private static func parishEventContains(_ record: SourceRecord, any needles: [String]) -> Bool {
        guard case .parish(let p) = record else { return false }
        let kind = (p.eventType ?? "").lowercased()
        return needles.contains { kind.contains($0) }
    }

    /// The census year a record belongs to (nil for every other type).
    nonisolated static func censusYear(of record: SourceRecord) -> Int? {
        guard case .census(let c) = record else { return nil }
        return c.censusYear > 0 ? c.censusYear : nil
    }

    /// A census whose household roster could still be fetched: a census record
    /// with a detail URL but no roster yet. Pure — testable without a database.
    /// FreeCen enriches only the TOP search hit at search time, so every other
    /// candidate arrives roster-less.
    nonisolated static func censusNeedsHousehold(_ record: SourceRecord) -> Bool {
        guard case .census(let c) = record else { return false }
        return (c.household ?? []).isEmpty && (c.common.detailURL?.isEmpty == false)
    }

    /// The roster a census record already carries (empty for every other type).
    nonisolated static func censusHousehold(_ record: SourceRecord) -> [HouseholdMember] {
        guard case .census(let c) = record else { return [] }
        return c.household ?? []
    }

    /// A parish record whose register-entry page could still be fetched: no
    /// typed `detail` payload yet, a detail URL present. Pure — testable
    /// without a database. FreeREG results-table rows carry no kin at all
    /// (parents live only on the entry page), so every search-row parish
    /// record arrives in this state.
    nonisolated static func parishNeedsDetail(_ record: SourceRecord) -> Bool {
        guard case .parish(let p) = record else { return false }
        return p.detail == nil && (p.common.detailURL?.isEmpty == false)
    }

    /// One line naming the family a parish record mentions — the typed detail
    /// first (role-resolved), the flat projection as fallback. Nil when the
    /// record names nobody, or isn't parish. Pure.
    nonisolated static func parishKinLine(_ record: SourceRecord) -> String? {
        guard case .parish(let p) = record else { return nil }
        var parts: [String] = []
        if let detail = p.detail {
            switch detail.event {
            case .baptism(let b):
                if let f = b.father?.displayName { parts.append("Father \(f)") }
                if let m = b.mother?.person.displayName { parts.append("Mother \(m)") }
            case .marriage(let m):
                if let gf = m.groomFather?.displayName { parts.append("Groom's father \(gf)") }
                if let bf = m.brideFather?.displayName { parts.append("Bride's father \(bf)") }
            case .burial(let b):
                if let r = b.relative?.displayName {
                    let rel = (b.relationship ?? "").trimmingCharacters(in: .whitespaces)
                    // First-letter only — `.capitalized` would render
                    // "wife of" as "Wife Of".
                    parts.append(rel.isEmpty ? "Relative \(r)"
                                 : "\(rel.prefix(1).uppercased() + rel.dropFirst()) \(r)")
                }
            }
        }
        // Flat fatherName/motherName are the lossy projection (baptisms only,
        // per the DS-10 producer guard) — used when no typed detail exists.
        if parts.isEmpty {
            if let f = p.fatherName, !f.isEmpty { parts.append("Father \(f)") }
            if let m = p.motherName, !m.isEmpty { parts.append("Mother \(m)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The profile's LIFE ANCHORS — the established facts a candidate record
    /// must be arithmetically consistent with. Built by the caller from the
    /// snapshot (the ledger itself has no graph access) so every candidate
    /// row can carry the cross-fact reasoning a researcher does in their
    /// head: "b.~1871 would mean she married at 44 and had Reginald at 45"
    /// (owner request 2026-07-31 — surface the cross-thinking).
    struct LifeAnchors: Sendable, Equatable {
        var marriageYears: [Int] = []
        var earliestChildBirthYear: Int? = nil
        var latestChildBirthYear: Int? = nil
        var childName: String? = nil
        var deathYear: Int? = nil
        var birthYear: Int? = nil

        static func build(for profileID: String, snapshot: FamilyGraphSnapshot) -> LifeAnchors {
            var anchors = LifeAnchors()
            let profile = snapshot.profiles[profileID]
            anchors.deathYear = profile?.deathDate?.bestYear
            anchors.birthYear = profile?.birthDate?.bestYear
            anchors.marriageYears = snapshot.relationships
                .filter { $0.type == .spouse && ($0.from == profileID || $0.to == profileID) }
                .compactMap { $0.marriageDate?.bestYear }
                .sorted()
            let children = snapshot.childrenOf(profileID)
                .compactMap { child in child.birthDate?.bestYear.map { (child.displayName, $0) } }
                .sorted { $0.1 < $1.1 }
            anchors.earliestChildBirthYear = children.first?.1
            anchors.latestChildBirthYear = children.last?.1
            anchors.childName = children.first?.0
            return anchors
        }
    }

    /// EVERY evidence record for the profile (applied, pending, rejected),
    /// classified by standing. The per-fact expander filters these by record
    /// type. Ordered by standing (applied first), then record type, then id.
    static func allRecords(for profileID: String, db: ProjectDatabase, profile: Profile? = nil,
                           anchors: LifeAnchors? = nil) throws -> [RecordDetail] {
        let details = try db.loadEvidenceForProfile(profileID)
            .map { rec in
                RecordDetail(
                    id: rec.sourceRecordID,
                    sourceID: rec.sourceID,
                    recordType: rec.recordType,
                    verdict: rec.verdict,
                    standing: standing(for: rec, profile: profile),
                    citation: (rec.citationFull?.isEmpty == false ? rec.citationFull! : rec.summary),
                    citationURL: rec.citationURL,
                    ageDetail: ageDetail(rec.record),
                    reconcileNote: [reconcileNote(rec.record, profile: profile),
                                    anchors.flatMap { crossAnchorNote(rec.record, anchors: $0) }]
                        .compactMap { $0 }
                        .joined(separator: " ")
                        .nilIfEmpty,
                    matchRank: matchRank(verdict: rec.verdict, gates: rec.gates),
                    duplicateIDs: [rec.sourceRecordID],
                    registrationKey: RecordScorer.registrationKey(for: rec.record),
                    household: censusHousehold(rec.record),
                    canLoadHousehold: censusNeedsHousehold(rec.record),
                    censusYear: censusYear(of: rec.record),
                    isParishMarriage: isParishMarriage(rec.record),
                    isParishBaptism: isParishBaptism(rec.record),
                    isParishBurial: isParishBurial(rec.record),
                    canLoadParishDetail: parishNeedsDetail(rec.record),
                    parishKinLine: parishKinLine(rec.record))
            }

        // Collapse the same underlying entry saved more than once across runs
        // (a re-scrape yields a new source-record id but an identical citation
        // bar the access date). One card per real record; removal cleans them all.
        var byIdentity: [String: RecordDetail] = [:]
        var order: [String] = []
        for d in details {
            let key = identityKey(d)
            if let existing = byIdentity[key] {
                var rep = existing.standing.sortOrder <= d.standing.sortOrder ? existing : d
                rep.duplicateIDs = existing.duplicateIDs + d.duplicateIDs
                // A roster is evidence, and only ONE of two re-scraped twins may
                // have been enriched with it. Whichever copy wins the standing
                // contest inherits it, so collapsing can never hide a household
                // the profile has already fetched.
                if rep.household.isEmpty {
                    let other = rep.id == existing.id ? d : existing
                    if !other.household.isEmpty {
                        rep.household = other.household
                        rep.canLoadHousehold = false
                    }
                }
                // Same for a fetched parish detail: only one twin may carry
                // the kin the page names, and collapsing must not hide it.
                if rep.parishKinLine == nil {
                    let other = rep.id == existing.id ? d : existing
                    if let kin = other.parishKinLine {
                        rep.parishKinLine = kin
                        rep.canLoadParishDetail = other.canLoadParishDetail
                    }
                }
                byIdentity[key] = rep
            } else {
                byIdentity[key] = d
                order.append(key)
            }
        }

        return order.compactMap { byIdentity[$0] }
            .sorted { a, b in
                if a.standing.sortOrder != b.standing.sortOrder { return a.standing.sortOrder < b.standing.sortOrder }
                if a.matchRank != b.matchRank { return a.matchRank > b.matchRank }  // best match first
                if a.recordType.rawValue != b.recordType.rawValue { return a.recordType.rawValue < b.recordType.rawValue }
                return a.id < b.id
            }
    }

    /// Identity of a record independent of the run that saved it. BMD records
    /// with a vol/page carry a REGISTRATION identity — the same GRO entry is
    /// often indexed as several rows whose transcriptions (and so citations)
    /// differ, and those twins are one real record, never two cards (the
    /// Elizabeth Keyworth 7b/920 specimen: the applied death and its twin
    /// showed as "1 applied + 1 researched"). Otherwise: source, type, and
    /// the citation with the trailing "; accessed <date>" trimmed off (the
    /// only part that differs between re-scrapes of the same entry).
    private static func identityKey(_ d: RecordDetail) -> String {
        if let reg = d.registrationKey {
            return "\(d.sourceID)|\(reg)"
        }
        let base = d.citation.range(of: "; accessed").map { String(d.citation[..<$0.lowerBound]) } ?? d.citation
        return "\(d.sourceID)|\(d.recordType.rawValue)|\(base.trimmingCharacters(in: .whitespaces))"
    }

    /// The cross-fact consistency line — deterministic arithmetic between a
    /// candidate record's year and the profile's OTHER anchors, so the row
    /// itself says what a researcher would work out on paper: "If hers:
    /// married at 30 (1915); Reginald born when she was 31." Hard
    /// contradictions lead with "Impossible if hers"; strained ones with
    /// "Unlikely if hers". Nil when the record implies no year or the
    /// profile has no anchors to check against. Pure — no AI, no lookups.
    static func crossAnchorNote(_ record: SourceRecord, anchors: LifeAnchors) -> String? {
        if let birthYear = impliedCandidateBirthYear(record) {
            return birthConsistency(birthYear, anchors: anchors)
        }
        if let deathYear = impliedCandidateDeathYear(record) {
            return deathConsistency(deathYear, anchors: anchors)
        }
        if case .marriage(let m) = record, let year = m.marriageYear {
            return marriageConsistency(year, anchors: anchors)
        }
        return nil
    }

    private static func birthConsistency(_ year: Int, anchors: LifeAnchors) -> String? {
        var clauses: [String] = []
        var severity = 0   // 0 fine · 1 unlikely · 2 impossible
        if let marriage = anchors.marriageYears.first {
            let age = marriage - year
            if age < 0 {
                clauses.append("born after the \(marriage) marriage")
                severity = 2
            } else if age < 16 {
                clauses.append("married at \(age) (\(marriage))")
                severity = max(severity, 1)
            } else {
                clauses.append("married at \(age) (\(marriage))")
            }
        }
        if let child = anchors.earliestChildBirthYear {
            let age = child - year
            let name = anchors.childName ?? "the first child"
            if age < 0 {
                clauses.append("born after \(name)'s \(child) birth")
                severity = 2
            } else if age < 14 || age > 50 {
                clauses.append("\(name) born when they were \(age)")
                severity = max(severity, 1)
            } else {
                clauses.append("\(name) born when they were \(age)")
            }
        }
        if let death = anchors.deathYear {
            let lifespan = death - year
            if lifespan < 0 {
                clauses.append("born after the recorded \(death) death")
                severity = 2
            } else if lifespan > 105 {
                clauses.append("a \(lifespan)-year lifespan")
                severity = max(severity, 1)
            }
        }
        guard !clauses.isEmpty else { return nil }
        return prefixed(clauses, severity: severity)
    }

    private static func deathConsistency(_ year: Int, anchors: LifeAnchors) -> String? {
        var clauses: [String] = []
        var severity = 0
        if let child = anchors.latestChildBirthYear {
            let name = anchors.childName ?? "the youngest child"
            if year < child {
                clauses.append("died before \(name)'s \(child) birth")
                severity = 2
            } else {
                clauses.append("alive for \(name)'s \(child) birth")
            }
        }
        if let marriage = anchors.marriageYears.last {
            if year < marriage {
                clauses.append("died before the \(marriage) marriage")
                severity = 2
            } else if clauses.isEmpty {
                clauses.append("after the \(marriage) marriage")
            }
        }
        if let birth = anchors.birthYear {
            let age = year - birth
            if age < 0 {
                clauses.append("before the recorded \(birth) birth")
                severity = 2
            } else if age > 105 {
                clauses.append("aged \(age)")
                severity = max(severity, 1)
            }
        }
        guard !clauses.isEmpty else { return nil }
        return prefixed(clauses, severity: severity)
    }

    private static func marriageConsistency(_ year: Int, anchors: LifeAnchors) -> String? {
        var clauses: [String] = []
        var severity = 0
        if let birth = anchors.birthYear {
            let age = year - birth
            if age < 0 {
                clauses.append("married before the recorded \(birth) birth")
                severity = 2
            } else if age < 16 {
                clauses.append("married at \(age)")
                severity = max(severity, 1)
            } else {
                clauses.append("married at \(age)")
            }
        }
        if let death = anchors.deathYear, year > death {
            clauses.append("after the recorded \(death) death")
            severity = 2
        }
        guard !clauses.isEmpty else { return nil }
        return prefixed(clauses, severity: severity)
    }

    private static func prefixed(_ clauses: [String], severity: Int) -> String {
        let body = clauses.joined(separator: "; ")
        switch severity {
        case 2: return "Impossible if theirs: \(body)."
        case 1: return "Unlikely if theirs: \(body)."
        default: return "If theirs: \(body)."
        }
    }

    /// The birth year a candidate record implies (for the consistency line).
    private static func impliedCandidateBirthYear(_ record: SourceRecord) -> Int? {
        switch record {
        case .birth(let b): return b.birthYear
        case .census(let c): return c.birthYear ?? c.age.map { c.censusYear - $0 }
        default: return nil
        }
    }

    /// The death year a candidate record implies.
    private static func impliedCandidateDeathYear(_ record: SourceRecord) -> Int? {
        switch record {
        case .death(let d): return d.deathYear
        case .burial(let b): return b.deathYear
        case .probate(let p): return p.deathYear
        default: return nil
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
                // #32: `place` is the PROFILE's applied location, not anything
                // this index row records — a birth index carries no place
                // beyond the district. Calling it "the recorded place" made
                // every namesake candidate read as consistent with the tree
                // (owner dogfood 2026-08-24: nine John Wheeldon birth rows,
                // every one captioned "the recorded place is Cromford").
                parts.append("The index records only the registration district (\(d)); your tree's \(kind)place is \(place) — shown for comparison, not from this record.")
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

    /// `.applied` requires the apply ACTION to have run (v56 `applied_at`,
    /// with the citation-fingerprint fallback for pre-v56 rows) — a record
    /// merely kept via "Save as lead" is `.researched`, never "Applied"
    /// (owner dogfood 2026-07-31: Mary Ellen Thompson's saved census showed
    /// a green Applied pill while her Birth stayed empty).
    private static func standing(for rec: EvidenceRecord, profile: Profile?) -> Standing {
        if rec.userStatus == .discarded { return .userRejected }   // user's call wins
        if rec.wasApplied(to: profile) { return .applied }
        if rec.verdict == .impossible { return .scorerRejected }
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
        let kept = try db.loadEvidenceForProfile(profileID)
            .filter { $0.userStatus == .savedAsLead }

        let recordEntries = kept.map { rec in
            Entry(
                id: rec.sourceRecordID,
                sourceID: rec.sourceID,
                provenance: .sourceRecord(recordType: rec.recordType, verdict: rec.verdict),
                citation: (rec.citationFull?.isEmpty == false ? rec.citationFull! : rec.summary),
                citationURL: rec.citationURL,
                establishes: rec.record.absorptionPlan(profileID: profileID, profile: profile).compactMap(\.reviewLabel))
        }

        // The (field|raw|origin) triples a record entry's own bin ALREADY
        // deletes — the exact key `removeAppliedRecord` matches on. "Covered"
        // therefore means literally "another row in this list removes it", so
        // a provenance row is either reachable through its record or listed
        // with its own bin. No double-listing, and no third state.
        let covered: Set<String> = Set(kept.flatMap { rec in
            ProjectDatabase.removalTargetKeys(for: rec.record, profileID: profileID)
                .map { "\($0)|\(rec.sourceID)" }
        })

        let factEntries = try db.appliedFactProvenanceRows(profileID: profileID)
            .filter { row in
                // The user's own data is off limits. GEDCOM/WikiTree imports and
                // anything manual have no re-apply route if deleted, and Edit
                // already covers them — a bin next to them would be a one-way
                // destroy button on hand-entered work.
                let origin = SourceOrigin(identifier: row.origin)
                guard origin.tier != .initialImport, !origin.isManual else { return false }
                return !covered.contains("\(row.field)|\(row.raw)|\(row.origin)")
            }
            // Two identical accepts write two byte-identical rows with distinct
            // rowids. Collapse for display, keeping the newest, so one click
            // removes one row rather than the list showing a phantom duplicate.
            .reduce(into: [AppliedFactTarget]()) { acc, row in
                let key = "\(row.field)|\(row.raw)|\(row.origin)"
                if !acc.contains(where: { "\($0.field)|\($0.raw)|\($0.origin)" == key }) {
                    acc.append(row)
                }
            }
            .map { target in
                Entry(
                    id: "fs:\(target.rowID)",
                    sourceID: target.origin,
                    provenance: .appliedFact(target),
                    citation: target.sourceTitle ?? target.origin,
                    citationURL: target.citationURL,
                    establishes: ["\(Self.fieldLabel(target.field)) \(target.value)"])
            }

        // Records first, so the weaker-provenance block reads as an appendix
        // rather than being interleaved with scored evidence.
        return (recordEntries + factEntries).sorted { lhs, rhs in
            (lhs.isSourceRecord ? 0 : 1, lhs.sortKey, lhs.id)
                < (rhs.isSourceRecord ? 0 : 1, rhs.sortKey, rhs.id)
        }
    }

    /// "deathDate" → "death date". Display only.
    static func fieldLabel(_ field: String) -> String {
        field.reduce(into: "") { out, ch in
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(Character(ch.lowercased()))
        }
    }
}

private extension String {
    /// "" → nil, so an all-empty join never renders a blank note line.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
