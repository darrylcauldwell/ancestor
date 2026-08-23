import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// The search window widens in proportion to how the birth anchor was
/// established.
///
/// Owner dogfood 2026-08-22. Jacob Holmes sat at b.~1823, taken from a census
/// age of 38. His real baptism is 1817. The birth window was 1821–1825 and
/// `start_year`/`end_year` go to FreeREG **server-side**, so the record that
/// would have corrected the anchor was never returned. Editing the year by hand
/// to 1817 made it appear instantly — same register, same query, one number
/// different. A wrong anchor hides its own correction.
///
/// A census age is the least reliable number in genealogy; a baptism is not.
struct AnchorProvenanceWindowTests {

    private func subject(from: Int, to: Int, derived: Bool) -> ResearchSubject {
        ResearchSubject(
            profileID: "p", surname: "Holmes", givenName: "Jacob",
            birthYearFrom: from, birthYearTo: to,
            birthAnchorIsDerived: derived,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    // MARK: - The window

    /// THE SPECIMEN: Jacob's 1817 baptism must be inside the window his
    /// census-derived 1823 anchor produces.
    @Test func aCensusDerivedAnchorReachesTheBaptismThatCorrectsIt() throws {
        let range = subject(from: 1823, to: 1823, derived: true).yearRange(for: .baptism)
        let from = try #require(range.from)
        let to = try #require(range.to)
        #expect(from <= 1817,
                "the 1817 baptism must be reachable from a 1823 census anchor; window starts \(from)")
        #expect(to >= 1823)
    }

    /// A firm anchor stays tight — this must not become a licence to trawl.
    @Test func aFirmAnchorKeepsTheNarrowWindow() throws {
        let range = subject(from: 1823, to: 1823, derived: false).yearRange(for: .baptism)
        #expect(range.from == 1821)
        #expect(range.to == 1825)
    }

    /// The widening is bounded — a namesake a decade adrift stays out.
    @Test func theWidenedWindowStillExcludesADistantNamesake() throws {
        let range = subject(from: 1823, to: 1823, derived: true).yearRange(for: .baptism)
        let from = try #require(range.from)
        #expect(from > 1805, "±8, not unbounded — got a window starting \(from)")
    }

    /// Death-shape windows are untouched: this is about the BIRTH anchor's
    /// reliability, not about widening everything.
    @Test func deathWindowsAreUnaffected() {
        let derived = subject(from: 1823, to: 1823, derived: true).yearRange(for: .death)
        let firm = subject(from: 1823, to: 1823, derived: false).yearRange(for: .death)
        #expect(derived.from == firm.from)
        #expect(derived.to == firm.to)
    }

    // MARK: - Detecting a derived anchor

    private func profile(_ date: String?, sources: [FieldSource]) -> Profile {
        Profile(id: "p", firstName: "Jacob", lastName: "Holmes", gender: .male,
                birthDate: date.flatMap { GenealogicalDate.parsePreview($0).parsed },
                isDeleted: false,
                sources: sources.isEmpty ? [:] : [.birthDate: sources],
                disputes: [:])
    }

    private func source(_ origin: String) -> FieldSource {
        FieldSource(origin: SourceOrigin(identifier: origin), raw: "1823", addedAt: Date())
    }

    /// "CAL 1823" says outright that it was calculated — Jacob's actual value.
    @Test func anApproximateDateIsADerivedAnchor() {
        #expect(ResearchSubject.birthAnchorIsDerived(for: profile("CAL 1823", sources: [])))
        #expect(ResearchSubject.birthAnchorIsDerived(for: profile("ABT 1823", sources: [])))
    }

    /// A year backed only by censuses is derived, however it is written.
    @Test func aCensusOnlyAnchorIsDerived() {
        #expect(ResearchSubject.birthAnchorIsDerived(
            for: profile("1823", sources: [source("freecen"), source("census.1861")])))
    }

    /// One birth-shape or hand-entered source is enough to call it firm — the
    /// user knowing something we can't see is not a weak anchor.
    @Test func aRecordBackedOrManualAnchorIsFirm() {
        #expect(!ResearchSubject.birthAnchorIsDerived(
            for: profile("1817", sources: [source("freereg"), source("freecen")])))
        #expect(!ResearchSubject.birthAnchorIsDerived(
            for: profile("1817", sources: [source("manual.memory")])))
        #expect(!ResearchSubject.birthAnchorIsDerived(
            for: profile("1817", sources: [source("freebmd")])))
    }

    /// No sources at all is not evidence of weakness — stay firm rather than
    /// silently trawling for every dateless person in the tree.
    @Test func noSourcesMeansNotDerived() {
        #expect(!ResearchSubject.birthAnchorIsDerived(for: profile("1817", sources: [])))
    }

    // MARK: - The gate

    /// Fetching is only half of it: a record pulled in by the wider window must
    /// not then be rejected by the same bad anchor.
    @Test func theDateGateAllowsForADerivedAnchorToo() {
        let record = SourceRecord.parish(ParishRecord(
            common: RecordCommon(id: "b", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: nil, rawFields: [:]),
            eventType: "baptism", eventDate: "10 Aug 1817", eventYear: 1817,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: "John HOLMES", motherName: "Sophia"))

        let derived = RecordScorer.classify(
            record: record, subject: subject(from: 1823, to: 1823, derived: true),
            searchType: .parish)
        #expect(derived.verdict != .impossible,
                "a census-derived anchor must not rule out the baptism that corrects it")

        let firm = RecordScorer.classify(
            record: record, subject: subject(from: 1823, to: 1823, derived: false),
            searchType: .parish)
        #expect(firm.gates.contains { $0.gate == .date },
                "control: a firm anchor still applies the tight date gate")
    }
}
