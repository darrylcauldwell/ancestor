import Testing
import Foundation
@testable import Ancestor_Research

/// DS-15 family extension: the "alive-as-of" signal that rejects a too-early
/// death must also come from the subject's own MARRIAGE and CHILDREN, not just
/// life events. Live case (owner report 2026-08-05): a CWGC naval death dated
/// 27 May 1915 was about to apply to Albert Beresford, who married in Dec 1915
/// and fathered Nora in 1920 — so he plainly outlived that death.
@MainActor
struct AliveFromFamilyTests {

    private func profile(_ id: String, _ given: String, gender: Gender, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: "Beresford",
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// Albert (b.1886) married Gertrude Dec 1915, child Nora b.1920.
    private func albertSnapshot() -> FamilyGraphSnapshot {
        let albert = profile("albert", "Albert", gender: .male, birthYear: 1886)
        let gertrude = profile("gertrude", "Gertrude", gender: .female, birthYear: nil)
        let nora = profile("nora", "Nora", gender: .female, birthYear: 1920)
        return FamilyGraphSnapshot(
            profiles: [albert.id: albert, gertrude.id: gertrude, nora.id: nora],
            relationships: [
                Relationship(id: UUID(), from: albert.id, to: gertrude.id,
                             type: .spouse, role: nil, subtype: .biological,
                             marriageDate: GenealogicalDate(parsing: "1915"),
                             marriageLocation: nil, divorceDate: nil),
                Relationship(id: UUID(), from: albert.id, to: nora.id,
                             type: .parent, role: .father, subtype: .biological,
                             marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            ])
    }

    @Test func aliveAsOfComesFromMarriageAndChildren() {
        let snap = albertSnapshot()
        let subject = ResearchSubject.fromProfile(snap.profiles["albert"]!, snapshot: snap)
        // Marriage 1915; child 1920 → parent alive at least 1919 (conception).
        // Max wins.
        #expect(subject.aliveAsOf == 1919)
    }

    @Test func aTooEarlyMilitaryDeathIsImpossible() {
        let snap = albertSnapshot()
        let subject = ResearchSubject.fromProfile(snap.profiles["albert"]!, snapshot: snap)
        let naval = SourceRecord.military(MilitaryRecord(
            common: RecordCommon(id: "cwgc_navy", sourceID: "cwgc",
                                 name: "Albert Beresford", surname: "Beresford", givenName: "Albert",
                                 detailURL: nil, rawFields: [:]),
            rank: "Stoker 1st Class", regiment: "Royal Navy",
            dateOfDeath: "27 May 1915", deathYear: 1915))
        let scored = RecordScorer.classify(record: naval, subject: subject, searchType: .death)
        #expect(scored.verdict == .impossible)
        #expect(scored.gates.first { $0.gate == .date }?.reason.contains("recorded alive") == true)
    }

    @Test func hisRealLaterDeathStillPasses() {
        let snap = albertSnapshot()
        let subject = ResearchSubject.fromProfile(snap.profiles["albert"]!, snapshot: snap)
        // Died Mar 1950 aged ~62 — well after 1919, must NOT be rejected.
        let death = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "fb_1950", sourceID: "freebmd",
                                 name: "Albert Beresford", surname: "Beresford", givenName: "Albert",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1950, deathDate: nil, age: 62, quarter: "Mar", district: "Chesterfield"))
        let scored = RecordScorer.classify(record: death, subject: subject, searchType: .death)
        #expect(scored.gates.first { $0.gate == .date }?.reason.contains("recorded alive") != true)
        #expect(scored.verdict != .impossible)
    }
}
