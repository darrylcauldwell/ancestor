import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Env-gated LIVE probe — does FreeCen actually hold the census years the
/// dispatcher asks it for?
///
/// The question this exists to answer: George Land (`@I332160987010@`) has TWO
/// stored census records, both 1891, and none for 1871/1881/1901/1911 — yet
/// `yearRange(for: .census)` gives him 1864–1944, so `SearchDispatcher` emits a
/// query per year and 1901 is in the set. Static reading says the app asks. So
/// either FreeCen has no 1901 Derbyshire data to give, or the query is wrong.
/// Only the wire can say which.
///
/// One request per year probed, run deliberately (volunteer-source budget):
///
///   env TEST_RUNNER_RUN_FREECEN_YEAR_PROBE=1 xcodebuild test … \
///     -parallel-testing-enabled NO \
///     -only-testing:"Ancestor Research Tests/FreeCenYearCoverageProbeTests"
///
/// The surname/county pair is deliberately the owner's own known-present case:
/// LAND in Derbyshire, a family the 1891 transcription definitely contains, so
/// a zero result for another year is a statement about that YEAR's coverage
/// rather than about the name.
///
/// RESULT, 2026-08-21 (surname LAND, DBY):
///
///     1841    4    Appletree, Repton only
///     1851    0
///     1861  144    wide
///     1871    0
///     1881    2    Basford, Langley only
///     1891  165    wide
///     1901    0
///     1911    0
///
/// Every year answered `availability: .ok`, untruncated, unsuppressed — the
/// server responded properly and had nothing. With 144–165 Lands present in the
/// covered years, a zero is missing TRANSCRIPTION, not a missing family. So
/// FreeCen's Derbyshire holding is effectively **1861 and 1891 only**.
///
/// Two consequences. The owner's 1901 Wirksworth household (FamilySearch
/// ark:/61903/1:1:XSJR-3M6, piece/folio 74, household 4233241) is unreachable
/// by this app at all — no other registered source carries census returns. And
/// `SearchDispatcher` emits a FreeCen query per census year in the subject's
/// lifespan, so for a Derbyshire subject most of those are structurally
/// guaranteed empty — spend against a volunteer source that can never pay off.
/// A county×year coverage map would fix that; `negative_searches` cannot,
/// because it is per-profile and ages out at ~90 days, so every profile
/// re-learns the same emptiness.
@MainActor
struct FreeCenYearCoverageProbeTests {

    @Test func whichCensusYearsDoesFreeCenAnswerFor() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FREECEN_YEAR_PROBE"] == "1" else {
            return // gated off — no live traffic
        }
        let source = FreeCenSource()

        // 1891 is the control: the tree already holds a FreeCen 1891 Wirksworth
        // household for this exact surname and county. If the control returns
        // nothing, the probe itself is broken and no other row means anything.
        for year in [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911] {
            let query = RecordQuery(
                surname: "Land", givenName: nil, recordType: .census,
                yearFrom: year, yearTo: year, gender: nil, region: nil,
                sourceParams: .freeCen(FreeCenParams(
                    chapmanCode: "DBY",
                    chapmanCodes: nil,
                    censusYear: year,
                    birthYearRange: nil,
                    birthChapmanCode: nil
                ))
            )
            let envelope = await source.searchWithOutcome(query)
            let records = envelope.result.records
            let places = Set(records.compactMap { record -> String? in
                guard case .census(let c) = record else { return nil }
                return c.district
            })
            print("[freecen-probe] \(year): \(records.count) records, "
                  + "outcome=\(envelope.outcome), districts=\(places.sorted().prefix(12))")
        }
    }
}
