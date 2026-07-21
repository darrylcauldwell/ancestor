import Testing
import Foundation
@testable import Ancestor_Research

/// DS-21 — GPS Criterion 2 (complete citations) checked only that a fact's
/// sourceID was non-empty, which every plugin stamps by construction, so the
/// criterion degenerated to "has any confirmed fact". It now requires a
/// resolvable locator: a detail URL or the source's structured reference.
struct GPSCitationCompletenessTests {

    @Test func detailURLAlwaysCounts() {
        // Even with no structured fields, a direct link is a complete citation.
        #expect(GPSScorer.hasCompleteCitation(birth(volume: nil, page: nil, district: nil, url: "https://www.freebmd.org.uk/rec/123")))
    }

    @Test func bmdVolumeAndPageCount() {
        #expect(GPSScorer.hasCompleteCitation(birth(volume: "19", page: "438", district: nil, url: nil)))
    }

    @Test func bmdDistrictAloneCounts() {
        #expect(GPSScorer.hasCompleteCitation(birth(volume: nil, page: nil, district: "Belper", url: nil)))
    }

    @Test func bareBmdWithNoLocatorIsIncomplete() {
        // The finding's example: a FreeBMD hit missing volume/page/district
        // and with no detail URL must NOT count as completely cited.
        #expect(!GPSScorer.hasCompleteCitation(birth(volume: nil, page: nil, district: nil, url: nil)))
    }

    @Test func volumeWithoutPageIsIncomplete() {
        // A half-reference (volume but no page) is not a resolvable locator.
        #expect(!GPSScorer.hasCompleteCitation(birth(volume: "19", page: nil, district: nil, url: nil)))
    }

    @Test func burialMemorialIDCounts() {
        let rec = SourceRecord.burial(BurialRecord(
            common: common(sourceID: "findagrave", url: nil),
            deathDate: nil, deathYear: 1980, birthDate: nil, birthYear: nil,
            birthPlace: nil, deathPlace: nil, burialLocation: nil, cemetery: nil,
            memorialID: 12345, inscription: nil, bio: nil, isVeteran: false))
        #expect(GPSScorer.hasCompleteCitation(rec))
    }

    // MARK: - Fixtures

    private func common(sourceID: String, url: String?) -> RecordCommon {
        RecordCommon(id: "r1", sourceID: sourceID, name: nil, surname: "Cauldwell",
                     givenName: "Ernest", detailURL: url, rawFields: [:])
    }

    private func birth(volume: String?, page: String?, district: String?, url: String?) -> SourceRecord {
        .birth(BirthRecord(
            common: common(sourceID: "freebmd", url: url),
            birthYear: 1845, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: district, volume: volume, page: page,
            mothersMaidenName: nil))
    }
}
