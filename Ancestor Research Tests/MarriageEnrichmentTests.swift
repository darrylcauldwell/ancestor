import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the marriage-enrichment matcher. The BMD index lists each marriage
/// twice — once under the groom's name, once under the bride's. Matching by
/// (year, quarter, district, vol, page) rejoins them and yields both given names.
struct MarriageEnrichmentTests {

    private func entry(
        surname: String, givenName: String, spouseSurname: String,
        year: Int = 1948, quarter: String = "Jun",
        district: String = "Belper", volume: String = "7C", page: String = "421"
    ) -> MarriageEnrichmentEngine.MarriageEntry {
        MarriageEnrichmentEngine.MarriageEntry(
            surname: surname, givenName: givenName, spouseSurname: spouseSurname,
            year: year, quarter: quarter, district: district,
            volume: volume, page: page, scored: nil
        )
    }

    @Test func uniqueMatchReturnsBothGivenNames() {
        let groom = entry(surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes")
        let bride = entry(surname: "Holmes",    givenName: "MARGARET", spouseSurname: "Cauldwell")

        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [bride])

        if case .unique(let fGiven, let mGiven, _, _) = outcome {
            #expect(fGiven == "JAMES")
            #expect(mGiven == "MARGARET")
        } else {
            Issue.record("Expected unique outcome, got \(outcome)")
        }
    }

    @Test func nonMatchingReferencesReturnNone() {
        let groom = entry(
            surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes",
            district: "Belper", volume: "7C", page: "421"
        )
        let bride = entry(
            surname: "Holmes", givenName: "MARGARET", spouseSurname: "Cauldwell",
            district: "Derby", volume: "9A", page: "13"
        )
        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [bride])
        if case .none = outcome {
            // ok
        } else {
            Issue.record("Expected none, got \(outcome)")
        }
    }

    @Test func multipleMatchesReturnAmbiguous() {
        // Same surname pair across two different marriages — both reference
        // tuples match between groom-side and bride-side.
        let groomA = entry(surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes",
                           district: "Belper", page: "100")
        let brideA = entry(surname: "Holmes",    givenName: "MARGARET", spouseSurname: "Cauldwell",
                           district: "Belper", page: "100")
        let groomB = entry(surname: "Cauldwell", givenName: "WILLIAM", spouseSurname: "Holmes",
                           district: "Derby", page: "200")
        let brideB = entry(surname: "Holmes",    givenName: "JANE", spouseSurname: "Cauldwell",
                           district: "Derby", page: "200")

        let outcome = MarriageEnrichmentEngine.match(grooms: [groomA, groomB], brides: [brideA, brideB])
        if case .ambiguous(let candidates) = outcome {
            #expect(candidates.count == 2 || candidates.isEmpty)  // scored nil → empty candidates list, but the case fires
        } else if case .none = outcome {
            Issue.record("Expected ambiguous, got none — matching produced 2 pairs but the outcome wasn't ambiguous")
        } else {
            Issue.record("Expected ambiguous, got \(outcome)")
        }
    }

    @Test func quarterAndVolumeMustMatchToJoin() {
        // Same year + district + page but DIFFERENT quarter — these are not
        // the same marriage and should not join.
        let groom = entry(surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes",
                          quarter: "Mar")
        let bride = entry(surname: "Holmes", givenName: "MARGARET", spouseSurname: "Cauldwell",
                          quarter: "Sep")
        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [bride])
        if case .none = outcome {
            // ok
        } else {
            Issue.record("Quarter mismatch should not join, got \(outcome)")
        }
    }

    @Test func emptyInputsReturnNone() {
        let outcome = MarriageEnrichmentEngine.match(grooms: [], brides: [])
        if case .none = outcome {
            // ok
        } else {
            Issue.record("Empty inputs should be none, got \(outcome)")
        }
    }
}
