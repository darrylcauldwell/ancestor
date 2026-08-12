import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FINDAGRAVE_DEATH_SEARCH_SPEC Fix 2 — the pure hop that turns a fetched
/// memorial's parsed Family Members block into the partner's memorial id, so the
/// pipeline can recover a spouse's memorial that a name+year search missed
/// (dogfood: Mary 216193100 → Ernest 216193076, birth "unknown", invisible to
/// his own search). The two `fetchDetail` calls around it mirror the already-
/// tested `enrichFagBridge` network pattern.
struct FindAGraveSpouseLinkTests {

    private func maryWithLinks(_ links: [FindAGraveSource.FamilyLink]) -> SourceRecord {
        var raw: [String: String] = [:]
        if let enc = FindAGraveSource.encodeFamilyLinks(links) { raw["familyLinks"] = enc }
        return .burial(BurialRecord(
            common: RecordCommon(id: "findagrave_216193100", sourceID: "findagrave",
                                 name: "Mary Cauldwell", surname: "Cauldwell", givenName: "Mary",
                                 detailURL: "https://www.findagrave.com/memorial/216193100", rawFields: raw),
            deathDate: nil, deathYear: 1962, birthDate: nil, birthYear: 1889,
            birthPlace: nil, deathPlace: nil, burialLocation: "Kirk Ireton",
            cemetery: "Holy Trinity Churchyard", memorialID: 216193100,
            inscription: nil, bio: nil, isVeteran: false))
    }

    @Test func followsSpouseLinkToPartnerMemorial() {
        let rec = maryWithLinks([
            .init(relation: "spouse", name: "Ernest Cauldwell", memorialID: 216193076, years: "unknown–1959"),
            .init(relation: "child", name: "George Cauldwell", memorialID: 111, years: "1915–1986"),
        ])
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: rec, matchingSurname: "Cauldwell") == 216193076)
        // A single spouse link resolves even with no surname to match on.
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: rec) == 216193076)
    }

    @Test func multiSpouseUsesSurnameOrDeclines() {
        let rec = maryWithLinks([
            .init(relation: "spouse", name: "Ernest Cauldwell", memorialID: 216193076, years: nil),
            .init(relation: "spouse", name: "Someone Else", memorialID: 999, years: nil),
        ])
        // Surname picks the right spouse out of two.
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: rec, matchingSurname: "Cauldwell") == 216193076)
        // Two spouses, no surname to disambiguate → decline (never guess).
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: rec) == nil)
    }

    @Test func noSpouseLinkOrNonBurialYieldsNil() {
        // Only a child link → no spouse target.
        let onlyChild = maryWithLinks([.init(relation: "child", name: "George Cauldwell", memorialID: 111, years: nil)])
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: onlyChild) == nil)
        // A non-burial record carries no family links.
        let bmd = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b", sourceID: "freebmd", name: "Ernest Cauldwell",
                                 surname: "Cauldwell", givenName: "Ernest", rawFields: [:]),
            birthYear: 1886, birthDate: nil, birthPlace: nil, quarter: nil,
            district: nil, volume: nil, page: nil, mothersMaidenName: nil))
        #expect(FindAGraveSource.spouseLinkedMemorialID(fromRecord: bmd) == nil)
    }
}
