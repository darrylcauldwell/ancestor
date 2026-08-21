import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The geography gate could not see a parish record's location.
///
/// `checkGeography` extracts a district for `.birth/.death/.marriage/.census`
/// and a free-text county for those plus `.burial/.probate`. `.parish` was in
/// NEITHER switch, so every `ParishRecord` fell through to
/// `softFail "no location data"` regardless of what it carried — 108 of 108 in
/// a replay of the live store, including plainly-Derbyshire Youlgreave and
/// Dronfield entries.
///
/// That was dormant while it only cost a softFail. Two commits on 2026-08-17
/// woke it up: DS-12P passes `familyContext` on a parish marriage when a
/// party's SURNAME ALONE matches a known spouse, and Fix B.3 cancels a
/// geography softFail whose reason is exactly `"no location data"` once
/// familyContext has passed. Together they promoted a **Nottinghamshire**
/// marriage to `.fact` for a Derbyshire subject — the gate never evaluated the
/// county because it could not read it.
@MainActor
struct ParishGeographyGateTests {

    private func subject(home: String = "DBY", spouseSurname: String? = nil) -> ResearchSubject {
        ResearchSubject(
            surname: "HOLMES", givenName: "WILLIAM",
            birthYearFrom: 1882, birthYearTo: 1882,
            gender: .male, mode: .extend,
            familyContext: spouseSurname.map { s in
                FamilyContext(
                    spouseName: "MARY \(s)", spouseSurname: s, spouseGivenName: "MARY",
                    spouseFatherSurname: nil, childNames: [],
                    fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                    motherName: nil, motherSurname: nil, motherGivenName: nil)
            },
            homeChapmanCode: home)
    }

    /// `coPersons` mirrors what `FreeREGSource` puts in `rawFields` from the
    /// results row's `<br>`-separated principals cell — the flat path DS-12P
    /// reads when there is no enriched detail page. Without it the
    /// familyContext gate SKIPS and any test of Fix B.3 passes vacuously.
    private func parish(
        _ id: String = "p1", parish: String?, county: String?,
        event: String = "Marriage", year: Int = 1898,
        coPersons: String? = "WILLIAM HOLMES;ELIZABETH THOMPSON"
    ) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(id: id, sourceID: "freereg",
                                 name: "WILLIAM HOLMES", surname: "HOLMES",
                                 givenName: "WILLIAM", detailURL: nil,
                                 rawFields: coPersons.map { ["co_persons": $0] } ?? [:]),
            eventType: event, eventDate: "\(year)", eventYear: year,
            parish: parish, county: county))
    }

    private func geography(_ record: SourceRecord, _ s: ResearchSubject) -> GateResult? {
        RecordScorer.classify(record: record, subject: s, searchType: .parish)
            .gates.first { $0.gate == .geography }
    }

    // MARK: - The gate can now read a parish record at all

    @Test func aLocalParishRecordPassesInsteadOfReadingAsNoLocationData() {
        let gate = geography(parish(parish: "Youlgreave", county: "Derbyshire"), subject())
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason != "no location data")
    }

    /// A bare parish with no county still resolves, through the parish
    /// catalogue on the leading token — the same path a census birthplace uses.
    @Test func aBareLocalParishNameResolvesWithoutACounty() {
        let gate = geography(parish(parish: "Dronfield", county: nil), subject())
        #expect(gate?.outcome != .softFail || gate?.reason != "no location data",
                "whatever it decides, it must not claim there is no location data")
    }

    /// THE ONE THAT MATTERS. An out-of-county parish must not read as absent.
    @Test func anOutOfCountyParishRecordSoftFailsWithItsActualLocation() {
        let gate = geography(
            parish(parish: "Sutton-in-Ashfield", county: "Nottinghamshire"), subject())
        #expect(gate?.outcome == .softFail)
        #expect(gate?.reason != "no location data")
        #expect(gate?.reason.lowercased().contains("nottinghamshire") == true,
                "the reason must name the county the gate rejected it for")
    }

    /// A record that genuinely carries no place still says so — the fix must
    /// not manufacture a location.
    @Test func aPlacelessParishRecordStillReadsAsNoLocationData() {
        let gate = geography(parish(parish: nil, county: nil), subject())
        #expect(gate?.reason == "no location data")
    }

    @Test func emptyStringsAreTreatedAsAbsentNotAsAPlace() {
        let gate = geography(parish(parish: "", county: "  "), subject())
        #expect(gate?.reason == "no location data")
    }

    // MARK: - The false fact this closes

    /// The live specimen: William Holmes (b. 29 Oct 1882, Derbyshire), a 1898
    /// Sutton-in-Ashfield marriage naming an "Elizabeth THOMPSON" against a
    /// spouse surnamed Thompson. DS-12P passes familyContext on the surname
    /// alone; Fix B.3 then excused the geography softFail because its reason
    /// was exactly "no location data". All gates effectively passed → `.fact`.
    ///
    /// With the county visible, the softFail reason is no longer whitelisted,
    /// so the record can no longer reach `.fact` on a family-context pass.
    @Test func aForeignCountyParishMarriageCannotReachFactOnFamilyContextAlone() {
        let s = subject(spouseSurname: "THOMPSON")
        let record = parish(parish: "Sutton-in-Ashfield", county: "Nottinghamshire")
        let scored = RecordScorer.classify(record: record, subject: s, searchType: .parish)

        // Pin Fix B.3's PRECONDITION first. Without this the test could pass
        // vacuously — if familyContext merely soft-failed, geography would be
        // irrelevant and the fix would be unproven.
        #expect(scored.gates.contains { $0.gate == .familyContext && $0.outcome == .pass },
                "DS-12P must still pass on the spouse surname — that is the whole setup")

        #expect(scored.verdict != .fact,
                "a Nottinghamshire record must not be a fact for a Derbyshire subject")
        let geo = scored.gates.first { $0.gate == .geography }
        #expect(geo?.reason != "no location data",
                "and Fix B.3's whitelist must no longer apply to it")
    }

    /// The counterpart, so the fix is not just "reject everything": a LOCAL
    /// parish marriage with a real family-context match still reaches fact.
    /// Four of the five parish records that score fact on the live store are
    /// of exactly this shape and must survive.
    @Test func aLocalParishMarriageWithFamilyContextStillReachesFact() {
        let s = subject(spouseSurname: "THOMPSON")
        let record = parish(parish: "Youlgreave", county: "Derbyshire")
        let scored = RecordScorer.classify(record: record, subject: s, searchType: .parish)
        let geo = scored.gates.first { $0.gate == .geography }
        #expect(geo?.outcome == .pass, "a local parish now passes on its own merit")
        #expect(scored.verdict == .fact)
    }

    /// An overseas parish record is now reachable by the foreign check, which
    /// it never was before — it used to read as "no location data" and soft-fail.
    @Test func anObviouslyForeignParishRecordIsRejected() {
        let gate = geography(parish(parish: "Toronto", county: "Ontario, Canada"), subject())
        #expect(gate?.outcome == .fail)
    }
}
