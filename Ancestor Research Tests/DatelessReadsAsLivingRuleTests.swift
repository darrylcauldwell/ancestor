import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Owner dogfood 2026-07-30: the dateless sister Elizabeth Keyworth showed
/// "(living)" though her brother was born 1875 — an unbounded birth defaults
/// `potentiallyLiving = true`, distorting privacy treatment and research.
/// The rule infers "born no later than" from family anchors and flags
/// dateless profiles that are certainly historical.
@MainActor
struct DatelessReadsAsLivingRuleTests {

    private func profile(_ id: String, _ given: String, _ surname: String,
                         birthYear: Int? = nil) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: given, lastName: surname,
                gender: .unknown, attributes: nil,
                birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
                birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentRel(_ p: String, _ c: String) -> Relationship {
        Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                     subtype: .biological, marriageDate: nil,
                     marriageLocation: nil, divorceDate: nil)
    }

    @Test func datelessSisterWithVictorianBrotherFires() {
        let father = profile("father", "George", "Keyworth", birthYear: 1838)
        let sister = profile("sister", "Elizabeth", "Keyworth")          // no dates
        let brother = profile("brother", "William Henry", "Keyworth", birthYear: 1875)
        let snapshot = FamilyGraphSnapshot(
            profiles: [father.id: father, sister.id: sister, brother.id: brother],
            relationships: [parentRel("father", "sister"), parentRel("father", "brother")])

        let results = DatelessReadsAsLivingRule().evaluate(profile: sister, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.message.contains("born no later than ~1895") == true)
        #expect(results.first?.severity == .warning)
    }

    @Test func modernDatelessProfileDoesNotFire() {
        // A dateless person whose sibling was born recently could genuinely
        // be living — never flag them.
        let parent = profile("parent", "Sam", "Modern", birthYear: 1980)
        let dateless = profile("dateless", "Alex", "Modern")
        let sibling = profile("sibling", "Jo", "Modern", birthYear: 2010)
        let snapshot = FamilyGraphSnapshot(
            profiles: [parent.id: parent, dateless.id: dateless, sibling.id: sibling],
            relationships: [parentRel("parent", "dateless"), parentRel("parent", "sibling")])

        #expect(DatelessReadsAsLivingRule().evaluate(profile: dateless, snapshot: snapshot).isEmpty)
    }

    @Test func noDatedRelativesMeansNoFinding() {
        let loner = profile("loner", "Mary", "Unknown")
        let snapshot = FamilyGraphSnapshot(profiles: [loner.id: loner], relationships: [])
        #expect(DatelessReadsAsLivingRule().evaluate(profile: loner, snapshot: snapshot).isEmpty)
    }

    @Test func anyDateOnTheProfileSilencesTheRule() {
        // The rule is strictly for DATELESS profiles — a recorded birth means
        // the ordinary living heuristic already has what it needs.
        let father = profile("father", "George", "Keyworth", birthYear: 1838)
        var dated = profile("dated", "Jane", "Keyworth", birthYear: 1880)
        dated.deathDate = nil
        let snapshot = FamilyGraphSnapshot(
            profiles: [father.id: father, dated.id: dated],
            relationships: [parentRel("father", "dated")])
        #expect(DatelessReadsAsLivingRule().evaluate(profile: dated, snapshot: snapshot).isEmpty)
    }

    @Test func childAnchorBoundsTheBirthTightest() {
        // A child born 1900 → parent born no later than 1886 — fires even
        // when a sibling bound alone wouldn't.
        let dateless = profile("mother", "Ann", "Ward")
        let child = profile("child", "Tom", "Ward", birthYear: 1900)
        let snapshot = FamilyGraphSnapshot(
            profiles: [dateless.id: dateless, child.id: child],
            relationships: [parentRel("mother", "child")])
        let results = DatelessReadsAsLivingRule().evaluate(profile: dateless, snapshot: snapshot)
        #expect(results.first?.message.contains("born no later than ~1886") == true)
    }
}
