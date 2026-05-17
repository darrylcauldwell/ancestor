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

    // The matcher now groups by reference key across both sides — each
    // unique key is a candidate marriage. A groom at one ref and a bride
    // at a different ref therefore represent TWO distinct candidate
    // marriages and should surface as ambiguous (previously these returned
    // .none, which silently discarded valid one-sided data).
    @Test func nonMatchingReferencesProduceAmbiguous() {
        let groom = entry(
            surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes",
            district: "Belper", volume: "7C", page: "421"
        )
        let bride = entry(
            surname: "Holmes", givenName: "MARGARET", spouseSurname: "Cauldwell",
            district: "Derby", volume: "9A", page: "13"
        )
        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [bride])
        if case .ambiguous = outcome {
            // ok — two candidate marriages at two distinct reference tuples
        } else {
            Issue.record("Expected ambiguous, got \(outcome)")
        }
    }

    // MARK: - One-sided enrichment (FreeBMD returning incomplete results)

    // Empirically observed Cauldwell × Holmes 1969 BELPER: groom-side
    // returns the marriage but bride-side query comes back without it.
    // With the matcher grouping by reference key across both sides we
    // still produce a unique outcome — father gets enriched with the
    // groom's given name; mother stays surname-only (motherGiven == nil).
    @Test func groomSideOnlyEnrichesFatherOnly() {
        let groom = entry(surname: "Cauldwell", givenName: "DAVID N", spouseSurname: "Holmes")
        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [])
        if case .unique(let fGiven, let mGiven, let fEv, let mEv) = outcome {
            #expect(fGiven == "DAVID N")
            #expect(mGiven == nil)
            // Evidence: nil here because the helper uses scored:nil.
            // What matters is that fEv tracks the groom record and mEv is nil.
            #expect(fEv == nil)
            #expect(mEv == nil)
        } else {
            Issue.record("Expected unique outcome, got \(outcome)")
        }
    }

    @Test func brideSideOnlyEnrichesMotherOnly() {
        let bride = entry(surname: "Holmes", givenName: "JENNIFER M", spouseSurname: "Cauldwell")
        let outcome = MarriageEnrichmentEngine.match(grooms: [], brides: [bride])
        if case .unique(let fGiven, let mGiven, _, _) = outcome {
            #expect(fGiven == nil)
            #expect(mGiven == "JENNIFER M")
        } else {
            Issue.record("Expected unique outcome, got \(outcome)")
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

    @Test func quarterAndVolumeMismatchProducesAmbiguous() {
        // Same year + district + page but DIFFERENT quarter — these are
        // not the same marriage. Reference keys differ, so each side is
        // its own candidate. Under one-sided enrichment that's two
        // distinct candidate marriages → ambiguous, not .none.
        let groom = entry(surname: "Cauldwell", givenName: "JAMES", spouseSurname: "Holmes",
                          quarter: "Mar")
        let bride = entry(surname: "Holmes", givenName: "MARGARET", spouseSurname: "Cauldwell",
                          quarter: "Sep")
        let outcome = MarriageEnrichmentEngine.match(grooms: [groom], brides: [bride])
        if case .ambiguous = outcome {
            // ok — two candidates at different reference keys
        } else {
            Issue.record("Quarter mismatch should produce ambiguous, got \(outcome)")
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
