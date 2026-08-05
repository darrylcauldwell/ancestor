import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// TEMPLATED_NARRATIVE_SOURCE_SPEC Stage 2 — the live MI RecordSource, driven with
/// a fixture page (no network) so the full search → template → parse → burial-map
/// path is exercised end-to-end. `@MainActor` because the actor's init is
/// MainActor-isolated under this project's default-isolation setting.
@MainActor
struct MemorialInscriptionRecordSourceTests {

    // Real Youlgreave HOLMES inscriptions (in-test only; never republished).
    private let fixture = """
    A67: John HOLMES, of Stanton, 10 May 1876, 89; Ellen, w, 25 Oct 1857, 73; Ann, grand-daughter, 14 July 1853, 15
    D77: Antoney HOLMES of Stanton, 12 Jan 1806, 56
    D121: John, s/o Samuel & Mary HOLMES, Of Stanton, 16 March 1833, 8yrs
    """

    private func query(surname: String, chapman: String = "DBY", parish: String = "Youlgreave") -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: nil, recordType: .burial,
            yearFrom: nil, yearTo: nil, gender: nil, region: .englandAndWales,
            sourceParams: .memorialInscription(MemorialInscriptionParams(chapmanCode: chapman, parish: parish)))
    }

    @Test func searchFetchesTheParishPageAndReturnsBurialRecordsWithBirthYears() async throws {
        let source = MemorialInscriptionRecordSource(fetchPage: { [fixture] _ in fixture })
        let result = await source.search(query(surname: "Holmes"))

        // Unwrap the .burial records inside the app module (avoids a spurious
        // cross-module cast under the duplicate-AncestorKit test-link quirk).
        let burials = MemorialInscriptionRecordSource.burials(in: result)
        #expect(burials.count == 5)                                   // all five HOLMES stones
        #expect(burials.allSatisfy { $0.burialLocation == "Youlgreave" })
        #expect(burials.allSatisfy { $0.common.sourceID == "wishful-thinking-mi" })
        // The discriminator BMD can't give: a death year + age → a birth year.
        #expect(burials.contains { $0.birthYear == 1787 })            // John, d.1876 aged 89
        #expect(burials.contains { $0.birthYear == 1825 })            // child, d.1833 aged 8
        // Facts only — the verbatim inscription is never copied into the record.
        #expect(burials.allSatisfy { $0.inscription == nil })
    }

    @Test func filtersToTheQueriedSurname() async throws {
        let source = MemorialInscriptionRecordSource(fetchPage: { [fixture] _ in fixture })
        let result = await source.search(query(surname: "Twyford"))   // not on these stones
        #expect(result.records.isEmpty)
    }

    @Test func outsideCoverageWithoutChapmanAndParishParams() async throws {
        let source = MemorialInscriptionRecordSource(fetchPage: { _ in "" })
        let q = RecordQuery(
            surname: "Holmes", givenName: nil, recordType: .burial,
            yearFrom: nil, yearTo: nil, gender: nil, region: .englandAndWales,
            sourceParams: .generic)
        if case .outsideCoverage = await source.search(q) {} else {
            Issue.record("expected .outsideCoverage without memorial-inscription params")
        }
    }

    // MARK: - Parish extraction (what the dispatcher slots into the template)

    @Test func extractsParishFromASubjectLocation() {
        typealias S = MemorialInscriptionRecordSource
        #expect(S.parish(fromLocation: "Alport, Youlgreave, Derbyshire, England") == "Youlgreave")
        #expect(S.parish(fromLocation: "Wirksworth, Derbyshire (DBY)") == "Wirksworth")
        #expect(S.parish(fromLocation: "Youlgreave") == "Youlgreave")
        #expect(S.parish(fromLocation: nil) == nil)
        // County + country only — no specific parish remains.
        #expect(S.parish(fromLocation: "Derbyshire, England") == nil)
        // A death abroad must NOT become a parish (William Holmes died in France).
        #expect(S.parish(fromLocation: "France") == nil)
        #expect(S.parish(fromLocation: "Ypres, Belgium") == nil)
    }

    // MARK: - Home parish (burial/death → else home-county residence)

    @Test func fallsBackToAHomeCountyResidenceParish() {
        typealias S = MemorialInscriptionRecordSource
        // No burial/death place; a died-abroad soldier who lived in Youlgreave
        // (the William Holmes shape) still gets his HOME parish looked up.
        #expect(S.homeParish(
            burialPlace: nil, deathLocation: "France",
            residences: [("Youlgreave", "DBY"), ("Bakewell", "DBY")],
            homeChapman: "DBY") == "Youlgreave")

        // Burial place wins when present.
        #expect(S.homeParish(
            burialPlace: "Wirksworth, Derbyshire", deathLocation: nil,
            residences: [("Youlgreave", "DBY")], homeChapman: "DBY") == "Wirksworth")

        // A residence in ANOTHER county is skipped — the parish must pair with the
        // home Chapman code, never /DBY/<Notts-parish>/.
        #expect(S.homeParish(
            burialPlace: nil, deathLocation: nil,
            residences: [("Mansfield", "NTT")], homeChapman: "DBY") == nil)

        // Unknown-county residence (bare village) is allowed as a candidate.
        #expect(S.homeParish(
            burialPlace: nil, deathLocation: nil,
            residences: [("Youlgreave", nil)], homeChapman: "DBY") == "Youlgreave")

        // Nothing resolvable → nil (dispatcher emits no query).
        #expect(S.homeParish(
            burialPlace: nil, deathLocation: nil, residences: [], homeChapman: "DBY") == nil)
    }
}
