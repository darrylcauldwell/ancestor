import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Name-enrichment absorption (owner case 2026-07-21): Geoff Bonsall's applied
/// marriage record carried the fuller "Geoffrey W Bonsall", and the fuller
/// name evaporated on apply. The plan now emits the fuller first token
/// (through the string-overwrite policy — a user-authoritative "Geoff" lands
/// it as a cited alternative, never an overwrite) and the middle token(s) as a
/// middleName gap-fill. Name items are emitted ONLY when the profile is in
/// hand — legacy plan calls without one are byte-identical to before.
///
/// Adversarial-review hardening (same day): first-name emission requires an
/// ATTESTED fuller form (prefix expansion would rename JOSEPH→JOSEPHINE);
/// middle emission is directional ("W" never degrades a stored "William");
/// census names are excluded (household-HEAD fallback); compatible name
/// forms never open a dispute; re-apply doesn't stack alternative rows.
@MainActor
struct NameEnrichmentAbsorptionTests {

    // MARK: - Helpers

    private func common(_ given: String?, surname: String = "Bonsall") -> RecordCommon {
        RecordCommon(id: "m1", sourceID: "freebmd", surname: surname,
                     givenName: given, rawFields: [:])
    }

    private func marriage(_ given: String?, spouse: String? = "Twyford") -> SourceRecord {
        .marriage(MarriageRecord(
            common: common(given), marriageYear: 1955, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Bakewell", volume: nil, page: nil,
            spouseName: spouse))
    }

    private func profile(first: String?, middle: String? = nil) -> Profile {
        Profile(id: "geoff", externalIDs: [:], firstName: first, middleName: middle,
                lastName: "Bonsall", gender: .male, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func stringItems(_ plan: [Absorption]) -> [(field: ProfileField, value: String)] {
        plan.compactMap { if case .stringField(let f, let v) = $0 { (f, v) } else { nil } }
    }

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    /// Apply the record to the stored profile and return the reloaded profile.
    private func apply(_ record: SourceRecord, db: ProjectDatabase) throws -> Profile {
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        let subject = try #require(try db.loadProfile(id: "geoff"))
        _ = ApplyEngine.applyFactToSubject(scored, profile: subject, snapshot: try db.buildSnapshot(), db: db)
        return try #require(try db.loadProfile(id: "geoff"))
    }

    // MARK: - Predicates

    @Test func fullerFormPredicate() {
        #expect(ScoringRules.isFullerGivenForm(record: "GEOFFREY", profile: "Geoff"))
        #expect(ScoringRules.isFullerGivenForm(record: "Adelaide", profile: "Ada"),
                "known nickname family, longer form")
        #expect(!ScoringRules.isFullerGivenForm(record: "Geoff", profile: "Geoffrey"),
                "shorter is not fuller")
        #expect(!ScoringRules.isFullerGivenForm(record: "Geoffrey", profile: "Geoffrey"),
                "equality is not fuller")
        #expect(!ScoringRules.isFullerGivenForm(record: "John", profile: "Jo"),
                "a 2-char stored name can't claim every John/Joseph/Joan")
        #expect(!ScoringRules.isFullerGivenForm(record: "Herbert", profile: "Geoff"),
                "unrelated names never qualify")
    }

    /// Emission-grade predicate: raw prefix expansion is NOT attested — it
    /// blesses outright renames (JOSEPH→JOSEPHINE, ANN→ANNE).
    @Test func attestedFullerFormPredicate() {
        #expect(ScoringRules.isAttestedFullerGivenForm(record: "GEOFFREY", profile: "Geoff"))
        #expect(ScoringRules.isAttestedFullerGivenForm(record: "Adelaide", profile: "Ada"))
        #expect(!ScoringRules.isAttestedFullerGivenForm(record: "JOSEPHINE", profile: "Joseph"),
                "prefix-only expansion is a rename, not an enrichment")
        #expect(!ScoringRules.isAttestedFullerGivenForm(record: "ANNE", profile: "Ann"))
        #expect(!ScoringRules.isAttestedFullerGivenForm(record: "Geoff", profile: "Geoffrey"))
    }

    /// Middle expansion is directional: an initial expands to a full name,
    /// never the reverse.
    @Test func fullerMiddleFormPredicate() {
        #expect(ScoringRules.isFullerMiddleForm(record: "William", stored: "W"))
        #expect(ScoringRules.isFullerMiddleForm(record: "William Henry", stored: "W"))
        #expect(ScoringRules.isFullerMiddleForm(record: "William Henry", stored: "W H"))
        #expect(!ScoringRules.isFullerMiddleForm(record: "W", stored: "William"),
                "an initial never degrades a stored full middle")
        #expect(!ScoringRules.isFullerMiddleForm(record: "W", stored: "W"),
                "equality is not expansion")
        #expect(!ScoringRules.isFullerMiddleForm(record: "Henry", stored: "W"),
                "mismatched initial never qualifies")
    }

    /// The dispute carve-out's compatibility notion: refinements of one name
    /// are compatible; genuinely different names are not (and still dispute).
    @Test func compatibleNameFormPredicate() {
        #expect(ApplyEngine.isCompatibleNameForm(field: .firstName, existing: "Geoff", candidate: "Geoffrey"))
        #expect(ApplyEngine.isCompatibleNameForm(field: .firstName, existing: "Geoffrey", candidate: "Geoff"),
                "compatibility is bidirectional")
        #expect(ApplyEngine.isCompatibleNameForm(field: .firstName, existing: "Harry", candidate: "Henry"),
                "nickname family")
        #expect(ApplyEngine.isCompatibleNameForm(field: .middleName, existing: "William", candidate: "W"),
                "initial vs full middle is compatible either way")
        #expect(!ApplyEngine.isCompatibleNameForm(field: .firstName, existing: "Geoff", candidate: "Herbert"),
                "different names must still open a dispute")
        #expect(!ApplyEngine.isCompatibleNameForm(field: .birthLocation, existing: "Bakewell", candidate: "Bakewell"),
                "carve-out is name-fields only")
    }

    // MARK: - Plan emission

    /// The Geoff case end-to-end: "Geoffrey W" against profile "Geoff" (no
    /// middle) → fuller first name + middle gap-fill, both title-cased.
    @Test func fullerNameAndMiddleAreAbsorbed() {
        let plan = marriage("GEOFFREY W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff"))
        let strings = stringItems(plan)
        #expect(strings.contains { $0.field == .firstName && $0.value == "Geoffrey" })
        #expect(strings.contains { $0.field == .middleName && $0.value == "W" })
    }

    /// Identical first token, record carries a middle → middle only.
    @Test func middleAloneAbsorbsWhenFirstTokensEqual() {
        let plan = marriage("Geoff W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff"))
        let strings = stringItems(plan)
        #expect(!strings.contains { $0.field == .firstName })
        #expect(strings.contains { $0.field == .middleName && $0.value == "W" })
    }

    /// An incompatible first token (force-applied record may have bypassed
    /// the name gate) emits NO name items — neither first nor middle.
    @Test func incompatibleFirstTokenEmitsNothing() {
        let plan = marriage("Herbert W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff"))
        #expect(stringItems(plan).isEmpty)
    }

    /// Same name, no middle → nothing; a middle already recorded on the
    /// profile is not re-emitted.
    @Test func equalNamesEmitNothing() {
        let same = marriage("Geoff").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff"))
        #expect(stringItems(same).isEmpty)
        let middleKnown = marriage("Geoff W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff", middle: "W"))
        #expect(stringItems(middleKnown).isEmpty)
    }

    /// A record's middle INITIAL never degrades a stored full middle — but
    /// the reverse direction upgrades ("W" → "William").
    @Test func middleInitialNeverDegradesFullMiddle() {
        let degrade = marriage("GEOFFREY W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff", middle: "William"))
        #expect(!stringItems(degrade).contains { $0.field == .middleName },
                "record initial must not replace a stored full middle")
        let upgrade = marriage("Geoff William").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff", middle: "W"))
        #expect(stringItems(upgrade).contains { $0.field == .middleName && $0.value == "William" })
    }

    /// A raw prefix expansion is compatibility, not enrichment: "Josephine"
    /// against a stored "Joseph" must NOT emit a first-name rename.
    @Test func prefixOnlyExpansionDoesNotRename() {
        let plan = marriage("JOSEPHINE W").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Joseph"))
        #expect(!stringItems(plan).contains { $0.field == .firstName })
    }

    /// Census given names can fall back to the household HEAD when no target
    /// marker survives parsing — never treated as name evidence.
    @Test func censusRecordsEmitNoNameItems() {
        let census = SourceRecord.census(CensusRecord(
            common: common("GEOFFREY W"), censusYear: 1939, birthYear: 1930))
        let plan = census.absorptionPlan(profileID: "geoff", profile: profile(first: "Geoff"))
        #expect(!stringItems(plan).contains { $0.field == .firstName || $0.field == .middleName })
    }

    /// Shouty source values are re-cased; properly-cased interior capitals
    /// pass through untouched (no McKenzie → Mckenzie).
    @Test func recasingPreservesMixedCase() {
        let plan = marriage("Geoff McKenzie").absorptionPlan(
            profileID: "geoff", profile: profile(first: "Geoff"))
        #expect(stringItems(plan).contains { $0.field == .middleName && $0.value == "McKenzie" })
    }

    /// Legacy calls (no profile) emit no name items — the plan is
    /// byte-identical to the pre-feature shape.
    @Test func planWithoutProfileIsUnchanged() {
        let plan = marriage("GEOFFREY W").absorptionPlan(profileID: "geoff")
        #expect(stringItems(plan).isEmpty)
    }

    // MARK: - Preview labels

    /// The profile helper carries no field_sources, so the policy refuses the
    /// first-name overwrite (defensive default) — the preview must say so
    /// rather than promise a write. The middle gap-fill DOES write.
    @Test func previewLabelsNameItems() {
        let labels = marriage("GEOFFREY W").absorptionPreview(
            profileID: "geoff", profile: profile(first: "Geoff"))
        #expect(labels.contains("fuller given name Geoffrey (as cited alternative)"))
        #expect(labels.contains("middle name W"))
    }

    // MARK: - End-to-end apply (through the tier policy)

    /// Import-tier "Geoff" (gedcom) is upgraded outright by the research
    /// record's attested fuller form; the middle gap-fills.
    @Test func applyUpgradesImportTierName() throws {
        let db = try makeDB()
        try db.addProfile(profile(first: "Geoff"), source: .gedcom)
        let after = try apply(marriage("GEOFFREY W", spouse: nil), db: db)
        #expect(after.firstName == "Geoffrey")
        #expect(after.middleName == "W")
    }

    /// A user-authoritative "Geoff" is never displaced: the record's form
    /// lands as a cited alternative in field_sources, and NO dispute opens —
    /// compatible forms of one name are not a disagreement.
    @Test func applyKeepsUserNameAsAlternativeWithoutDispute() throws {
        let db = try makeDB()
        try db.addProfile(profile(first: "Geoff"), source: .manual)
        let after = try apply(marriage("GEOFFREY W", spouse: nil), db: db)
        #expect(after.firstName == "Geoff", "user-authoritative name stays")
        #expect(after.sources[.firstName]?.contains {
            $0.origin.identifier == "freebmd" && $0.raw == "Geoffrey"
        } == true, "the fuller form is preserved as a cited alternative")
        let disputes = try db.openDisputes(profileID: "geoff")
        #expect(disputes.isEmpty, "a name refinement must not open a dispute")
    }

    /// Re-applying the same record does not stack duplicate alternative rows.
    @Test func reapplyDoesNotDuplicateAlternativeRows() throws {
        let db = try makeDB()
        try db.addProfile(profile(first: "Geoff"), source: .manual)
        _ = try apply(marriage("GEOFFREY W", spouse: nil), db: db)
        let after = try apply(marriage("GEOFFREY W", spouse: nil), db: db)
        let rows = (after.sources[.firstName] ?? []).filter {
            $0.origin.identifier == "freebmd" && $0.raw == "Geoffrey"
        }
        #expect(rows.count == 1, "identical alternative recorded once, not per apply")
    }

    /// A stored full middle survives an apply carrying only the initial —
    /// the end-to-end proof of the plan-level directional gate.
    @Test func applyNeverDegradesFullMiddle() throws {
        let db = try makeDB()
        try db.addProfile(profile(first: "Geoff", middle: "William"), source: .gedcom)
        let after = try apply(marriage("GEOFFREY W", spouse: nil), db: db)
        #expect(after.middleName == "William")
    }
}
