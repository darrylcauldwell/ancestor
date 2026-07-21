import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch client — Slice 1. The `q.*`/`f.*` query emission is pinned so a
/// drift back to the retired free-text `q=` grammar (or a mis-encoded axis)
/// fails loudly. Grammar oracle: the official Record Persona Search resource +
/// the FamilySearch Bruno tree-search examples.
struct FamilySearchQueryTests {

    /// Group query items by name → values, for order-independent assertions.
    private func items(_ query: FamilySearchQuery) -> [String: [String]] {
        Dictionary(grouping: query.queryItems(), by: \.name)
            .mapValues { $0.compactMap(\.value) }
    }

    @Test func emitsStructuredPersonAndDateRangeTerms() {
        var q = FamilySearchQuery()
        q.givenName = "Ernest"
        q.surname = "Cauldwell"
        q.birthDateRange = 1880...1890
        let m = items(q)
        #expect(m["q.givenName"] == ["Ernest"])
        #expect(m["q.surname"] == ["Cauldwell"])
        #expect(m["q.birthLikeDate.from"] == ["1880"])
        #expect(m["q.birthLikeDate.to"] == ["1890"])
        #expect(m["count"] == ["20"])
        #expect(m["offset"] == ["0"])
        // Never the retired free-text form the probe guessed.
        #expect(m["q"] == nil)
    }

    @Test func omitsEmptyTermsAndSurnameExactWithoutSurname() {
        var q = FamilySearchQuery()
        q.givenName = ""            // empty → omitted
        q.surnameExact = true       // no surname → no exact flag
        let m = items(q)
        #expect(m["q.givenName"] == nil)
        #expect(m["q.surname"] == nil)
        #expect(m["q.surname.exact"] == nil)
    }

    @Test func surnameExactEmitsOnModifier() {
        var q = FamilySearchQuery()
        q.surname = "Cauldwell"
        q.surnameExact = true
        #expect(items(q)["q.surname.exact"] == ["on"])
    }

    @Test func emitsRelativeSpouseSexAndExactFilterAxes() {
        var q = FamilySearchQuery()
        q.surname = "Marshall"
        q.spouseGivenName = "Margaret"
        q.fatherSurname = "Marshall"
        q.sex = .female
        q.treeId = "TREE1"
        q.collectionId = "COL42"
        let m = items(q)
        #expect(m["q.spouseGivenName"] == ["Margaret"])
        #expect(m["q.fatherSurname"] == ["Marshall"])
        #expect(m["q.sex"] == ["Female"])
        #expect(m["f.treeId"] == ["TREE1"])
        #expect(m["f.collectionId"] == ["COL42"])
    }

    @Test func emitsEachLifeEventDateAxisAndPlace() {
        var q = FamilySearchQuery()
        q.deathDateRange = 1960...1965
        q.deathPlace = "Derbyshire, England"
        q.residenceDateRange = 1911...1911
        q.residencePlace = "Youlgreave"
        let m = items(q)
        #expect(m["q.deathLikeDate.from"] == ["1960"])
        #expect(m["q.deathLikeDate.to"] == ["1965"])
        #expect(m["q.deathLikePlace"] == ["Derbyshire, England"])
        #expect(m["q.residenceDate.from"] == ["1911"])
        #expect(m["q.residenceDate.to"] == ["1911"])
        #expect(m["q.residencePlace"] == ["Youlgreave"])
    }
}
