import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// EV1 (owner dogfood 2026-08-25) — an `.impossible` verdict is an EXCLUSION:
/// the record leaves every pool, silently. It may therefore only rest on a
/// fact the tree is actually sure of.
///
/// The specimen: FreeBMD "Emma KEYWORTH, Jun q 1909, Chesterfield 7b/407, age
/// 35" scored impossible — "age at death 35 impossible for birth ~1867 — a
/// different person" — against an APPLIED birthDate of Dec 1867 which itself
/// carried an OPEN dispute. A contested fact excluded a probably-correct
/// record and the profile lost its death registration.
struct ContestedPremiseScorerTests {

    private func emma(contested: Bool = false, derivedAnchor: Bool = false) -> ResearchSubject {
        var subject = ResearchSubject(
            profileID: "emma", surname: "Keyworth", givenName: "Emma",
            birthYearFrom: 1867, birthYearTo: 1867,
            birthAnchorIsDerived: derivedAnchor,
            birthDateOriginal: "Dec 1867",
            gender: .female, region: .county("Derbyshire"),
            mode: .all, familyContext: nil, homeChapmanCode: "DBY")
        if contested { subject.contestedFields = [.birthDate] }
        return subject
    }

    private func deathRecord() -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: "freebmd_death_7b_407_1", sourceID: "freebmd",
                surname: "Keyworth", givenName: "Emma", rawFields: [:]),
            deathYear: 1909, age: 35, quarter: "Jun",
            district: "Chesterfield", volume: "7b", page: "407"))
    }

    private func dateGate(_ scored: ScoredRecord) -> GateResult? {
        scored.gates.first { $0.gate == .date }
    }

    /// Control: with a firm birth date the exclusion still fires. The gate is
    /// not weakened — only its premise is checked.
    @Test func firmBirthDateStillExcludesTheNamesake() {
        let scored = RecordScorer.classify(
            record: deathRecord(), subject: emma(), searchType: .death)
        #expect(dateGate(scored)?.outcome == .impossible)
        #expect(scored.verdict == .impossible)
    }

    /// THE SPECIMEN: the same record against the same window, but the birth
    /// date is under argument — the record must survive as a reviewable lead.
    @Test func disputedBirthDateDemotesTheExclusionToALead() {
        let scored = RecordScorer.classify(
            record: deathRecord(), subject: emma(contested: true), searchType: .death)
        #expect(scored.verdict == .lead,
                "Emma's death registration was excluded by a fact under dispute: \(scored.gates)")
        let gate = dateGate(scored)
        #expect(gate?.outcome == .fail)
        #expect(gate?.reason.contains("birthDate Dec 1867") == true,
                "the reason must name what the demotion hangs on: \(String(describing: gate?.reason))")
        #expect(gate?.reason.contains("itself disputed") == true)
    }

    /// A birth year that rests only on a derived anchor (a census age, an
    /// `ABT` estimate) is the same shape of unsound premise — Jacob Holmes's
    /// census age was out by five.
    @Test func derivedBirthAnchorDemotesTheExclusionToALead() {
        let scored = RecordScorer.classify(
            record: deathRecord(), subject: emma(derivedAnchor: true), searchType: .death)
        #expect(scored.verdict == .lead)
        #expect(dateGate(scored)?.outcome == .fail)
        #expect(dateGate(scored)?.reason.contains("only an estimate") == true)
    }

    /// The birth axis too: a record years outside the window is normally
    /// `.impossible`, and that is exactly the exclusion a disputed birth date
    /// must not be allowed to make.
    @Test func disputedBirthDateAlsoHoldsAnOutOfWindowBirthRecord() {
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: "freebmd_birth_7b_515_1", sourceID: "freebmd",
                surname: "Keyworth", givenName: "Emma", rawFields: [:]),
            birthYear: 1878, quarter: "Dec", district: "Chesterfield",
            volume: "7b", page: "515"))
        let firm = RecordScorer.classify(record: record, subject: emma(), searchType: .birth)
        #expect(firm.verdict == .impossible)

        let contested = RecordScorer.classify(
            record: record, subject: emma(contested: true), searchType: .birth)
        #expect(contested.verdict == .lead)
        #expect(dateGate(contested)?.reason.contains("itself disputed") == true)
    }

    // MARK: - Where the flag comes from

    private func profile(dispute: FieldDispute?) -> Profile {
        Profile(
            id: "emma", externalIDs: [:],
            firstName: "Emma", lastName: "Keyworth", gender: .female,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "DEC 1867"), birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:],
            disputes: dispute.map { [.birthDate: $0] } ?? [:])
    }

    private func dispute(resolution: DisputeResolution?) -> FieldDispute {
        FieldDispute(
            field: .birthDate, reason: .valueMismatch, competingSources: [],
            detectedAt: Date(), resolution: resolution)
    }

    @Test func openDisputeReachesTheSubjectAsAContestedField() {
        let subject = ResearchSubject.fromProfile(
            profile(dispute: dispute(resolution: nil)),
            snapshot: FamilyGraphSnapshot(profiles: ["emma": profile(dispute: nil)], relationships: []))
        #expect(subject.contestedFields.contains(.birthDate))
    }

    /// A deferred dispute is still open — the user explicitly declined to pick
    /// a winner, which is the strongest possible statement that the value is
    /// not settled.
    @Test func deferredDisputeCountsAsContested() {
        let subject = ResearchSubject.fromProfile(
            profile(dispute: dispute(resolution: .deferred)),
            snapshot: FamilyGraphSnapshot(profiles: ["emma": profile(dispute: nil)], relationships: []))
        #expect(subject.contestedFields.contains(.birthDate))
    }

    @Test func resolvedDisputeIsNotContested() {
        let settled = dispute(resolution: .manual("Dec 1867 confirmed from the GRO index"))
        let subject = ResearchSubject.fromProfile(
            profile(dispute: settled),
            snapshot: FamilyGraphSnapshot(profiles: ["emma": profile(dispute: nil)], relationships: []))
        #expect(subject.contestedFields.isEmpty)
    }

    @Test func aProfileWithNoDisputesContestsNothing() {
        let subject = ResearchSubject.fromProfile(
            profile(dispute: nil),
            snapshot: FamilyGraphSnapshot(profiles: ["emma": profile(dispute: nil)], relationships: []))
        #expect(subject.contestedFields.isEmpty)
    }
}
