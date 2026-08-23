import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Two ways to give a person a birth anchor when nobody wrote one down.
///
/// Owner dogfood 2026-08-23. Four people arrived on the tree in one evening with
/// names and nothing else — John Holmes and Sophia from Jacob's 1817 baptism,
/// John Stephenson and Lydia from Mary's 1823 one. Every search window is built
/// from the birth year, so a person without one is not merely hard to research
/// but impossible to.
///
///  1. A subject's OWN baptism dates their birth, approximately.
///  2. A parent is bounded by their children, even with no record of their own.
struct BaptismAndParentAnchorTests {

    private func baptism(year: Int?, kind: String = "baptism") -> ParishRecord {
        ParishRecord(
            common: RecordCommon(id: "b", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: nil, rawFields: [:]),
            eventType: kind, eventDate: "10 Aug \(year ?? 0)", eventYear: year,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: "John HOLMES", motherName: "Sophia")
    }

    private func profile(birth: String?) -> Profile {
        Profile(id: "p", firstName: "Jacob", lastName: "Holmes", gender: .male,
                birthDate: birth.flatMap { GenealogicalDate.parsePreview($0).parsed },
                isDeleted: false, sources: [:], disputes: [:])
    }

    // MARK: - A baptism dates a birth

    @Test func aBaptismGivesADatelessSubjectAnApproximateBirth() throws {
        let date = try #require(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817), profile: profile(birth: nil)))
        #expect(date.earliest == 1815)
        #expect(date.latest == 1817, "birth is at or BEFORE baptism, never after")
        #expect(date.qualifier == .calculated, "it is an inference and must say so")
        #expect(date.isApproximate)
    }

    /// It fills a gap; it never argues with a recorded date.
    @Test func aRecordedBirthDateIsNeverDisplaced() {
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817), profile: profile(birth: "1817")) == nil)
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817), profile: profile(birth: "1823")) == nil,
            "even a WRONG recorded date is the human's to change, not ours")
    }

    /// Baptisms and christenings only — a burial dates nothing about a birth.
    @Test func onlyBaptismShapedEventsInferABirth() {
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817, kind: "burial"), profile: profile(birth: nil)) == nil)
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817, kind: "marriage"), profile: profile(birth: nil)) == nil)
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817, kind: "Christening"), profile: profile(birth: nil)) != nil)
    }

    /// No year means no guess. No PROFILE means candidate enumeration — the
    /// removal path walks the plan without one, and omitting the candidate
    /// there meant un-applying a baptism left its inferred birth behind
    /// forever (2026-08-23 sweep). A candidate that was never written is
    /// harmless: removal matches against actual field_sources rows.
    @Test func missingInputsBehaveByPath() {
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: 1817), profile: nil) != nil,
            "nil profile = removal-candidate enumeration, which must see the target")
        #expect(SourceRecord.baptismInferredBirthDate(
            record: baptism(year: nil), profile: profile(birth: nil)) == nil)
    }

    /// The inference reaches the absorption plan, so both the preview and the
    /// write path see it — one declarative truth, not two.
    @Test func theInferenceAppearsInTheAbsorptionPlan() {
        let plan = SourceRecord.parish(baptism(year: 1817))
            .absorptionPlan(profileID: "p", profile: profile(birth: nil))
        let birthDates = plan.compactMap { item -> GenealogicalDate? in
            if case .dateField(.birthDate, let d) = item { return d }
            return nil
        }
        #expect(birthDates.count == 1)
        #expect(birthDates.first?.latest == 1817)
    }

    /// A baptism says almost nothing about WHERE someone was born — Jacob was
    /// baptised at Youlgreave and born at Stanton Lees. No place is inferred.
    @Test func noBirthPlaceIsInferredFromTheParish() {
        let plan = SourceRecord.parish(baptism(year: 1817))
            .absorptionPlan(profileID: "p", profile: profile(birth: nil))
        let places = plan.contains { item in
            if case .stringField(.birthLocation, _) = item { return true }
            return false
        }
        #expect(!places, "the font is not the cradle")
    }

    // MARK: - A parent is bounded by their children

    /// A family context carrying only the children's birth years — the one
    /// field these tests care about.
    static func context(_ childYears: [Int]) -> FamilyContext {
        FamilyContext(
            spouseName: nil, spouseSurname: nil, spouseGivenName: nil, spouseFatherSurname: nil,
            childNames: [],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil,
            childBirthYears: childYears)
    }

    private func parent(childYears: [Int]) -> ResearchSubject {
        ResearchSubject(
            profileID: "john", surname: "Holmes", givenName: "John",
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: Self.context(childYears),
            homeChapmanCode: "DBY")
    }

    /// THE SPECIMEN: John Holmes, known only as Jacob's father (b. 1817), must
    /// become searchable.
    @Test func aFatherKnownOnlyByHisChildGetsAWindow() throws {
        let range = parent(childYears: [1817]).yearRange(for: .baptism)
        let from = try #require(range.from)
        let to = try #require(range.to)
        #expect(from == 1767, "at most 50 years older than his eldest child")
        #expect(to == 1801, "and at least 16 older")
        #expect(from < to)
    }

    /// The ELDEST child bounds it — a later child would put the window too late.
    @Test func theEldestChildSetsTheBound() throws {
        let range = parent(childYears: [1855, 1817, 1849]).yearRange(for: .baptism)
        #expect(try #require(range.to) == 1801)
    }

    /// With no children and no birth year there is genuinely nothing to say —
    /// an unbounded window would trawl the whole index.
    @Test func noChildrenAndNoBirthYearMeansNoWindow() {
        let range = ResearchSubject(
            profileID: "x", surname: "Holmes", givenName: "John",
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
            .yearRange(for: .baptism)
        #expect(range.from == nil)
        #expect(range.to == nil)
    }

    /// A known birth year still wins — the child-derived window is a fallback,
    /// never an override.
    @Test func aKnownBirthYearOutranksTheChildDerivedWindow() throws {
        let subject = ResearchSubject(
            profileID: "j", surname: "Holmes", givenName: "Jacob",
            birthYearFrom: 1817, birthYearTo: 1817,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: Self.context([1847]),
            homeChapmanCode: "DBY")
        #expect(try #require(subject.yearRange(for: .baptism).from) == 1815)
    }
}
