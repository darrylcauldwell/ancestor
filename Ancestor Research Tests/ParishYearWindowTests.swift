import Testing
import Foundation
@testable import Ancestor_Research

/// The `.parish` search window spans the whole life, because a parish register
/// does — baptism at the start, marriage in the middle, burial at the end.
///
/// Owner dogfood 2026-08-23, the last blocker in the Mary Stephenson hunt.
/// `.parish` fell through `yearRange`'s default arm, `(birthYearFrom,
/// deathYearTo ?? birthYearTo)` — so for a subject with NO death date the
/// window collapsed to the birth year alone, as if a person's parish records
/// end the year they were born. Mary's FreeREG searches went to the wire as
/// `start_year=1825&end_year=1825`; her 1823 Youlgreave baptism could not be
/// returned by ANY spelling of any name, while the ladder, the variant
/// fan-out and the timeout retry above it were all — by then — working.
/// Every FreeREG record ever fetched for her was dated exactly 1825: that
/// uniformity was the bug's signature, visible in her evidence list for days.
///
/// The cautionary half: the fix that "resolved" this the first time
/// (86674fd) widened `.baptism`, and its acceptance test TESTED `.baptism` —
/// while the live FreeREG dispatch sends `.parish`. The test passed; the wire
/// was unchanged. These tests therefore pin the WIRE, not just the helper.
@MainActor
struct ParishYearWindowTests {

    /// Mary as the tree holds her: birth CAL 1825 derived from a census age,
    /// no death date, Derbyshire.
    private func mary(derived: Bool = true, deathFrom: Int? = nil, deathTo: Int? = nil) -> ResearchSubject {
        ResearchSubject(
            profileID: "mary", surname: "Stevenson", givenName: "Mary",
            birthYearFrom: 1825, birthYearTo: 1825,
            birthAnchorIsDerived: derived,
            deathYearFrom: deathFrom, deathYearTo: deathTo,
            gender: .female, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    // MARK: - The window itself

    /// THE SPECIMEN: her 1823 baptism must be inside the parish window.
    @Test func theParishWindowContainsHerBaptism() throws {
        let range = mary().yearRange(for: .parish)
        let from = try #require(range.from)
        let to = try #require(range.to)
        #expect(from <= 1823, "1823 excluded — window starts \(from)")
        #expect(to >= 1823)
    }

    /// No death date → the death side falls back to birth + 95, exactly as
    /// death-shape searches already probe. Never again a one-year window.
    @Test func noDeathDateMeansLongevityFallbackNotCollapse() throws {
        let range = mary().yearRange(for: .parish)
        #expect(try #require(range.to) >= 1900,
                "a life's parish records do not end the year it began; got to=\(String(describing: range.to))")
    }

    /// A FIRM 1825 anchor still reaches 1823 — the ±2 birth pad alone covers
    /// a two-year baptism gap, independent of the derived-anchor widening.
    @Test func evenAFirmAnchorReachesTheBaptism() throws {
        let range = mary(derived: false).yearRange(for: .parish)
        #expect(try #require(range.from) <= 1823)
    }

    /// A recorded death bounds the window instead of the fallback.
    @Test func aKnownDeathBoundsTheWindow() throws {
        let range = mary(deathFrom: 1883, deathTo: 1883).yearRange(for: .parish)
        #expect(try #require(range.to) <= 1890, "death known → no +95 tail; got \(String(describing: range.to))")
        #expect(try #require(range.from) <= 1823)
    }

    /// A parent known only through children (John Stephenson: no dates, child
    /// b. 1823) inherits the child-derived window — searchable, not silent.
    @Test func aParentWithOnlyChildrenGetsAParishWindow() throws {
        let john = ResearchSubject(
            profileID: "john", surname: "Stephenson", givenName: "John",
            birthYearFrom: nil, birthYearTo: nil,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: BaptismAndParentAnchorTests.context([1823]),
            homeChapmanCode: "DBY")
        let range = john.yearRange(for: .parish)
        #expect(range.from != nil && range.to != nil,
                "a parent bounded by children must be searchable in parish registers")
    }

    // MARK: - The wire

    /// The queries the dispatcher ACTUALLY BUILDS for FreeREG carry a window
    /// containing 1823 — pinning the wire, not the helper, so a record-type
    /// mismatch between fix and dispatch can never pass again.
    @Test func everyFreeRegQueryOnTheWireContainsHerBaptismYear() {
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
        let queries = dispatcher.buildQueriesForTest(
            source: FreeREGSource(), subject: mary(),
            recordType: .parish, scope: .county)
        #expect(!queries.isEmpty, "FreeREG built no parish queries at all")
        for q in queries {
            let from = q.yearFrom ?? Int.min
            let to = q.yearTo ?? Int.max
            #expect(from <= 1823 && to >= 1823,
                    "query window \(from)–\(to) excludes the 1823 baptism")
        }
    }
}
