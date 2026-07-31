import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Census corroborate-in-place (owner dogfood 2026-07-31): the gap-fill
/// sweep skips relatives who already carry a birth year — so George
/// Keyworth jr's gedcom-only 1877 stayed uncited even though his father's
/// applied 1881 household roster (George, Son, age 4) agrees with it. The
/// corroboration mode targets UNSOURCED years the roster confirms (±1);
/// absorbing changes no value, it evidences the existing one. Fixtures
/// mirror the live Keyworth shape.
struct CensusCorroborationTests {

    private func profile(_ id: String, first: String, last: String,
                         birth: String? = nil,
                         birthSources: [FieldSource] = []) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: birthSources.isEmpty ? [:] : [.birthDate: birthSources],
            disputes: [:])
    }

    private func source(_ origin: SourceOrigin) -> FieldSource {
        FieldSource(origin: origin, raw: "1877", addedAt: Date(timeIntervalSince1970: 0))
    }

    private func member(_ name: String, _ rel: String, age: Int? = nil) -> HouseholdMember {
        HouseholdMember(name: name, relationship: rel, age: age, birthYear: nil)
    }

    private let keyworthHousehold = [
        HouseholdMember(name: "George KEYWORTH", relationship: "Head", age: 43, birthYear: nil),
        HouseholdMember(name: "George KEYWORTH", relationship: "Son", age: 4, birthYear: nil),
        HouseholdMember(name: "William Henry KEYWORTH", relationship: "Son", age: 6, birthYear: nil),
    ]

    @Test func unsourcedMatchingYearIsProposedForCorroboration() {
        // Son George: gedcom-only 1877; roster Son age 4 in 1881 → ~1877 ✓.
        let son = profile("george-jr", first: "George", last: "Keyworth",
                          birth: "1877", birthSources: [source(.gedcom)])
        let proposals = CensusAgeEnrichment.corroborations(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(proposals.map(\.targetProfileID) == ["george-jr"])
        #expect(proposals.first?.estimatedBirthYear == 1877)
    }

    @Test func evidenceBackedYearIsNeverReProposed() {
        // Already cited to a research source → nothing to corroborate.
        let son = profile("george-jr", first: "George", last: "Keyworth",
                          birth: "1877", birthSources: [source(.gedcom), source(.freecen)])
        let proposals = CensusAgeEnrichment.corroborations(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(proposals.isEmpty)
    }

    @Test func rosterDisagreementIsNeverCited() {
        // Recorded 1874 vs roster ~1877: a 3-year gap is namesake territory —
        // the mismatch must never be silently evidenced.
        let son = profile("george-jr", first: "George", last: "Keyworth",
                          birth: "1874", birthSources: [source(.gedcom)])
        let proposals = CensusAgeEnrichment.corroborations(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(proposals.isEmpty)
    }

    @Test func offByOneRosterAgeStillCorroborates() {
        // A census age straddles the birthday — recorded 1876 vs ~1877 cites.
        let son = profile("george-jr", first: "George", last: "Keyworth",
                          birth: "1876", birthSources: [source(.gedcom)])
        let proposals = CensusAgeEnrichment.corroborations(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(proposals.count == 1)
    }

    @Test func gapRelativesBelongToGapFillNotCorroboration() {
        // No recorded year at all → that's the existing backfill's case.
        let son = profile("george-jr", first: "George", last: "Keyworth")
        let corroborations = CensusAgeEnrichment.corroborations(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(corroborations.isEmpty)
        let gaps = CensusAgeEnrichment.proposals(
            subjectID: "george-sr", household: keyworthHousehold, censusYear: 1881,
            linkedRelatives: [son], sourceID: "freecen",
            relations: ["george-jr": .child])
        #expect(gaps.map(\.targetProfileID) == ["george-jr"])
    }

    @Test func endToEndThroughCensusBackfillWithSnapshot() {
        let father = profile("george-sr", first: "George", last: "Keyworth", birth: "1838")
        let son = profile("george-jr", first: "George", last: "Keyworth",
                          birth: "1877", birthSources: [source(.gedcom)])
        let rel = Relationship(id: UUID(), from: "george-sr", to: "george-jr",
                               type: .parent, role: nil, subtype: .biological,
                               marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        let snapshot = FamilyGraphSnapshot(
            profiles: [father.id: father, son.id: son], relationships: [rel])
        let census = CensusRecord(
            common: RecordCommon(id: "freecen_1881_worksop", sourceID: "freecen",
                                 name: "George KEYWORTH", surname: nil, givenName: nil,
                                 detailURL: nil, rawFields: [:]),
            censusYear: 1881, age: 43, birthYear: 1838, district: "Worksop",
            household: keyworthHousehold)
        let proposals = CensusBackfill.corroborations(
            censuses: [.init(subjectID: "george-sr", record: census)], snapshot: snapshot)
        #expect(proposals.map(\.targetProfileID) == ["george-jr"])
        // The member record absorbing this proposal carries the SON's roster
        // row (age 4 → 1877), so the same-value apply cites, never rewrites.
        #expect(proposals.first?.memberRecord.birthYear == 1877)
        #expect(proposals.first?.memberRecord.censusYear == 1881)
    }
}
