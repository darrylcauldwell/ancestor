import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The married-surname temporal bound had no floor from the children.
///
/// DS-18 gates the married-surname axis on `recordYear >= marriedSurnameEffectiveFrom`
/// (in `RecordScorer.checkName`) — right, and it stops an 1891 census "Mary E
/// HOLMES" matching a woman who became Holmes by a 1915 marriage. But the bound
/// came from `marriageAliveYears.min()` alone: the RECORDED marriage date, and
/// nothing else, even though `childAliveYears` was being computed four lines
/// away for a different purpose.
///
/// A child carrying the married surname is proof she was under that name by
/// that child's birth. Live specimen: " Bown" (`@I_1564735723@`), spouse edge
/// dated Mar 1892, children William Ward b. 1870 and Mary Ward b. 1889 — 264
/// pre-1892 WARD census records that pass both the date and geography gates
/// were hard-failed on the name gate alone.
///
/// The floor may only LOWER an existing bound. Deriving a bound where none
/// existed would newly reject records between an undated marriage and the first
/// child — a narrowing, which is the failure class the replay harness exists to
/// catch.
@MainActor
struct MarriedSurnameFloorTests {

    private func woman(_ surname: String = "Bown") -> Profile {
        Profile(id: "subject", firstName: "Elizabeth", lastName: surname, gender: .female,
                birthDate: GenealogicalDate(parsing: "1850"),
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func person(_ id: String, _ surname: String, birth: String?) -> Profile {
        Profile(id: id, firstName: "X", lastName: surname, gender: .male,
                birthDate: birth.flatMap { GenealogicalDate(parsing: $0) },
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseEdge(_ spouseID: String, marriage: String?) -> Relationship {
        Relationship(
            id: UUID(), from: "subject", to: spouseID, type: .spouse,
            role: nil, subtype: .biological,
            marriageDate: marriage.flatMap { GenealogicalDate(parsing: $0) },
            marriageLocation: nil, divorceDate: nil)
    }

    private func childEdge(_ childID: String) -> Relationship {
        Relationship(
            id: UUID(), from: "subject", to: childID, type: .parent,
            role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func subject(
        spouse: (id: String, surname: String, marriage: String?)?,
        children: [(id: String, surname: String, birth: String?)] = []
    ) -> ResearchSubject {
        var profiles: [String: Profile] = ["subject": woman()]
        var rels: [Relationship] = []
        if let spouse {
            profiles[spouse.id] = person(spouse.id, spouse.surname, birth: nil)
            rels.append(spouseEdge(spouse.id, marriage: spouse.marriage))
        }
        for c in children {
            profiles[c.id] = person(c.id, c.surname, birth: c.birth)
            rels.append(childEdge(c.id))
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: profiles, relationships: rels, lifeEvents: [:])
        return ResearchSubject.fromProfile(
            profiles["subject"]!, snapshot: snapshot, homeChapmanCode: "DBY")
    }

    // MARK: - The floor

    /// THE SPECIMEN. Marriage recorded Mar 1892; a Ward child born 1870. The
    /// bound must move back to 1870.
    @Test func aChildCarryingTheMarriedSurnameLowersTheBound() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Ward", "1889"), ("c2", "Ward", "1870")])
        #expect(s.marriedSurnames.contains("Ward"))
        #expect(s.marriedSurnameEffectiveFrom == 1870,
                "the tree's own children date the name earlier than the spouse edge does")
    }

    /// A child born AFTER the marriage tells us nothing new — the bound holds.
    @Test func aLaterChildDoesNotRaiseOrLowerTheBound() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Ward", "1895")])
        #expect(s.marriedSurnameEffectiveFrom == 1892)
    }

    /// A child under the MAIDEN surname is not evidence of the married name.
    @Test func aChildUnderTheMaidenSurnameDoesNotMoveTheBound() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Bown", "1870")])
        #expect(s.marriedSurnameEffectiveFrom == 1892)
    }

    /// A child with an unrelated surname is not evidence either.
    @Test func anUnrelatedChildSurnameDoesNotMoveTheBound() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Holmes", "1870")])
        #expect(s.marriedSurnameEffectiveFrom == 1892)
    }

    @Test func anUndatedChildCannotMoveTheBound() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Ward", nil)])
        #expect(s.marriedSurnameEffectiveFrom == 1892)
    }

    // MARK: - It may only widen, never narrow

    /// THE INVARIANT. With no dated marriage there is no bound today and the
    /// axis is fully permissive. Children must NOT create one — that would
    /// newly reject records between the unknown marriage and the first child.
    @Test func childrenNeverCreateABoundWhereNoneExisted() {
        let s = subject(
            spouse: ("h", "Ward", nil),
            children: [("c1", "Ward", "1870")])
        #expect(s.marriedSurnames.contains("Ward"), "the axis itself is still present")
        #expect(s.marriedSurnameEffectiveFrom == nil,
                "an undated marriage means NO bound; deriving one from the children narrows")
    }

    @Test func withNoSpouseAtAllThereIsStillNoBound() {
        #expect(subject(spouse: nil, children: [("c1", "Ward", "1870")])
            .marriedSurnameEffectiveFrom == nil)
    }

    // MARK: - The gate consequence

    /// End to end: a pre-1892 census under WARD is no longer a name mismatch.
    @Test func aPreMarriageCensusUnderTheMarriedSurnameNowMatches() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Ward", "1870")])
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c1881", sourceID: "freecen", name: nil,
                                 surname: "WARD", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            censusYear: 1881, age: 31, birthYear: 1850, district: "Belper"))

        let name = RecordScorer.classify(record: record, subject: s, searchType: .census)
            .gates.first { $0.gate == .name }
        #expect(name?.outcome != .fail,
                "she was demonstrably a Ward in 1881 — her Ward children were born by then")
    }

    /// And the bound still does its job: a record before the EARLIEST evidence
    /// of the married name is still rejected.
    @Test func aCensusBeforeAnyEvidenceOfTheMarriedNameStillFails() {
        let s = subject(
            spouse: ("h", "Ward", "Mar 1892"),
            children: [("c1", "Ward", "1870")])
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c1861", sourceID: "freecen", name: nil,
                                 surname: "WARD", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            censusYear: 1861, age: 11, birthYear: 1850, district: "Belper"))

        let name = RecordScorer.classify(record: record, subject: s, searchType: .census)
            .gates.first { $0.gate == .name }
        #expect(name?.outcome == .fail,
                "1861 predates every scrap of evidence that she was a Ward — DS-18 still bites")
    }
}
