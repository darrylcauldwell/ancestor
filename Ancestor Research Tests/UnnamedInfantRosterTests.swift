import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV20 (2026-08-26) — an unnamed infant is a census ROW, not a malformed one.
///
/// A schedule that enumerates "female, 0, daughter" with no forename is
/// recording a real person, and that row is the strongest missing-child signal
/// a census gives (a GRO birth registration that quarter, often a death within
/// the year). The firewall used to delete it on submit AND again on accept.
///
/// The principle the fix holds: a roster is EVIDENCE, so every enumerated row
/// is stored — but a row that cannot NAME a person is structurally barred from
/// creating one. `CensusFamilyLinker.familyLinks` is that guard and must not be
/// relaxed; the tests below pin both halves.
@MainActor
struct UnnamedInfantRosterTests {

    // MARK: - The refutation half, pinned so it cannot regress into a defect

    /// The in-app FreeCEN path was never the defect: `name` is the JOIN of the
    /// Surname and Forenames cells, and FreeCEN transcribes a surname on every
    /// member row, so a blank Forenames cell still yields a non-empty name.
    @Test func freeCenKeepsARowWhoseForenameCellIsBlank() throws {
        let html = """
        <table>
        <tr><th>Census</th><th>County</th><th>District</th></tr>
        <tr><td>1891</td><td>Derbyshire</td><td>Chesterfield</td></tr>
        </table>
        <table>
        <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Sex</th><th>Age</th></tr>
        <tr><td>GLADWIN</td><td>William</td><td>Head</td><td>M</td><td>34</td></tr>
        <tr><td>GLADWIN</td><td></td><td>Dau</td><td>F</td><td>0</td></tr>
        </table>
        """
        guard case .census(let c)? = FreeCenSource.parseHouseholdDetail(
            html, recordURL: "https://www.freecen.org.uk/search_records/64ev20") else {
            Issue.record("household must parse")
            return
        }
        #expect(c.household?.count == 2, "a blank FORENAME is not a blank NAME")
        let infant = try #require(c.household?.last)
        #expect(infant.name == "GLADWIN")
        #expect(infant.relationship == "Dau")
    }

    // MARK: - A bare surname must not become a forename

    @Test func aBareSurnameRowIsNotGivenTheSurnameAsAForename() {
        let household = [
            HouseholdMember(name: "William GLADWIN", relationship: "Head", age: 34, sex: "M"),
            HouseholdMember(name: "GLADWIN", relationship: "Dau", age: 0, sex: "F"),
        ]
        let parts = AppState.censusMemberNameParts(household[1], household: household)
        #expect(parts.first == nil, "the family surname is not a forename")
        #expect(parts.surname == "Gladwin")
    }

    @Test func aLoneTokenNoOtherMemberCarriesStaysAGivenName() {
        // A FamilySearch persona's bare given name ("Mary", a servant) has to
        // behave exactly as it did before EV20 — nothing in this household
        // says the token is a surname, so it is not treated as one.
        let household = [
            HouseholdMember(name: "William GLADWIN", relationship: "Head", age: 34),
            HouseholdMember(name: "Mary", relationship: "Serv", age: 19),
        ]
        let parts = AppState.censusMemberNameParts(household[1], household: household)
        #expect(parts.first == "Mary")
        #expect(parts.surname == nil, "pre-EV20 behaviour is unchanged for a bare given name")
    }

    @Test func aFullNameStillSplitsIntoGivenMiddleAndSurname() {
        let household = [HouseholdMember(name: "Sarah Jane KENWORTHY", relationship: "Wife")]
        let parts = AppState.censusMemberNameParts(household[0], household: household)
        #expect(parts.first == "Sarah")
        #expect(parts.middle == "Jane")
        #expect(parts.surname == "Kenworthy")
    }

    // MARK: - Accept path: evidence kept, artefact still refused

    @Test func acceptPathCarriesAnUnnamedInfantAndStillRefusesAnEmptyRow() {
        let payload: [String: Any] = ["household": [
            ["name": "William Gladwin", "relationship": "Head", "age": 34],
            ["name": "", "relationship": "Dau", "age": 0, "sex": "F"],
            ["name": "", "relationship": ""],
        ]]
        let members = ProjectDatabase.pendingFactHousehold(
            payload: payload, subjectName: "William Gladwin")
        #expect(members.count == 2, "an unnamed infant is evidence; a wholly empty row is not")
        let infant = members.last
        #expect(infant?.name == "")
        #expect(infant?.relationship == "Dau")
        #expect(infant?.age == 0)
    }

    // MARK: - The guard that must NOT be relaxed: identity refused

    @Test func aNamelessRowIsNeverProposedAsAFamilyLink() {
        let household = [
            HouseholdMember(name: "William Gladwin", relationship: "Head", age: 34, isTarget: true),
            HouseholdMember(name: "", relationship: "Dau", age: 0, sex: "F"),
        ]
        #expect(CensusFamilyLinker.familyLinks(household: household).isEmpty,
                "a nameless row can never become a profile")
    }

    /// The second route to profile creation. Every discovery on this path ends
    /// in "Add … to tree", so a nameless row must raise none — and skipping it
    /// also keeps the name-keyed discovery ids unique now that nameless rows
    /// can reach the extractor at all.
    @Test func anUnnamedRosterRowRaisesNoAddAPersonDiscovery() {
        let subject = Profile(
            id: "s", externalIDs: [:], firstName: "William", middleName: nil,
            lastName: "Gladwin", gender: .male, isDeleted: false, sources: [:], disputes: [:])
        let result = ResearchResult(
            confirmedFacts: [], leads: [], allScoredRecords: [], clusters: [],
            discrepancies: [],
            householdMembers: [
                // Spelled in full deliberately. `Discovery.addKind` matches on
                // "son"/"daughter" and is blind to the census abbreviations
                // ("Dau", "Daur", "Daug") that FreeCen actually transcribes, so
                // an abbreviated row yields personAdd == nil and this control
                // would pass vacuously. That blindness is real and filed as
                // EV39; it is NOT what this test is about, which is that a
                // NAMELESS row is never offered as a person to add.
                HouseholdMember(name: "Emma Gladwin", relationship: "Daughter", age: 7, sex: "F"),
                HouseholdMember(name: "", relationship: "Daughter", age: 0, sex: "F"),
            ],
            searchHistory: [])
        let found = DiscoveryExtractor.extract(
            from: result, profile: subject,
            snapshot: FamilyGraphSnapshot(profiles: ["s": subject], relationships: []))
        #expect(found.contains { $0.personAdd?.name == "Emma Gladwin" },
                "the named sibling is still offered")
        #expect(!found.contains { ($0.personAdd?.name ?? "unset").isEmpty },
                "a nameless row is never offered as a person to add")
    }

    // MARK: - Rendered honestly

    @Test func aNamelessRowSaysSoInsteadOfReadingAsBroken() {
        let m = HouseholdMember(name: "", relationship: "Dau", age: 0, sex: "F")
        let line = CensusHouseholdFixRow.householdLine(m)
        #expect(line.contains("(no name recorded)"))
        #expect(line.contains("dau"))
        #expect(!line.hasPrefix("•  —"), "no leading em-dash where a name should be")
    }

    @Test func aNamedRowIsUnchanged() {
        let m = HouseholdMember(name: "Emma Gladwin", relationship: "Dau", age: 7)
        #expect(CensusHouseholdFixRow.householdLine(m) == "• Emma Gladwin — dau · age 7")
    }
}
