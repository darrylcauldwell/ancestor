import Testing
import Foundation
@testable import Ancestor_Research

/// A spouse lookup names itself, rather than claiming to be a national sweep.
///
/// Owner dogfood 2026-08-23, mid-run on a district-scoped profile: *"FreeBMD
/// seems to be doing national marriage search"* — with an activity feed reading
/// `FreeBMD national marriages: 1877 — 16 results`.
///
/// It wasn't. `ResearchPipeline`'s volume/page query asks *"who else is
/// registered on this page?"* — the same technique that found Mary STEVENSON on
/// 19/331 by hand. It carries no district and no county because it needs
/// neither: the reference names one register page. But `activitySummary`
/// derived its label purely from the ABSENCE of a district, so the most
/// targeted query the app makes announced itself as the broadest.
struct PageLookupIsNotNationalTests {

    private func query(volume: String?, page: String?,
                       surname: String = "", district: String? = nil) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: nil, recordType: .marriage,
            yearFrom: 1877, yearTo: 1877, gender: nil, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: district, countyCode: nil, wildcardSurname: false,
                motherSurname: nil, spouseSurname: nil,
                volume: volume, page: page)))
    }

    /// THE SPECIMEN: a volume/page query must not call itself national.
    @Test func aPageLookupDoesNotClaimToBeNational() {
        let summary = FreeBMDSource.activitySummary(
            query: query(volume: "19", page: "331"), surname: "")
        #expect(!summary.contains("national"),
                "a one-page lookup announced as a national sweep: \(summary)")
        #expect(summary.contains("19/331"), "it should name the page it is reading: \(summary)")
    }

    /// It says what it is FOR — the reader should understand why a nameless
    /// query is running at all.
    @Test func aPageLookupExplainsItself() {
        let summary = FreeBMDSource.activitySummary(
            query: query(volume: "19", page: "331"), surname: "")
        #expect(summary.localizedCaseInsensitiveContains("other party"),
                "got: \(summary)")
        #expect(summary.contains("1877"), "the year still bounds it: \(summary)")
    }

    /// A genuine national query is still labelled national — this must not
    /// become a blanket rename that hides real broad searches.
    @Test func aRealNationalQueryStillSaysNational() {
        let summary = FreeBMDSource.activitySummary(
            query: query(volume: nil, page: nil, surname: "Holmes"), surname: "Holmes")
        #expect(summary.contains("national"), "got: \(summary)")
        #expect(summary.contains("Holmes"))
    }

    /// A district query is unaffected.
    @Test func aDistrictQueryIsUnchanged() {
        let summary = FreeBMDSource.activitySummary(
            query: query(volume: nil, page: nil, surname: "Holmes", district: "12"),
            surname: "Holmes")
        #expect(!summary.contains("national"), "got: \(summary)")
    }

    /// Half a reference is not a reference — a volume with no page falls back
    /// to the ordinary labelling rather than printing "19/".
    @Test func aPartialReferenceIsNotTreatedAsAPageLookup() {
        let volumeOnly = FreeBMDSource.activitySummary(
            query: query(volume: "19", page: nil, surname: "Holmes"), surname: "Holmes")
        #expect(!volumeOnly.contains("19/"), "got: \(volumeOnly)")
    }
}
