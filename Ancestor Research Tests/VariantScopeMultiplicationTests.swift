import Testing
import Foundation
@testable import Ancestor_Research

/// Spelling breadth and geographic breadth must not compound.
///
/// Owner dogfood 2026-08-23, watching one profile research:
///
///     FreeBMD STS county deaths: JACK tomson 1816–1906 (variant)
///
/// Three widenings in one line — a neighbouring county, a surname variant and a
/// nickname. "Jack Tomson of Staffordshire" is a person who never existed, and
/// proving it costs a volunteer-run server a request. Multiply seven counties
/// by six spellings by three nicknames and one record type becomes 126 queries.
///
/// The two are ALTERNATIVE hypotheses — "recorded under another spelling" OR
/// "registered in another county" — so when the geography is already wide, the
/// spelling budget is spent sparingly.
@MainActor
struct VariantScopeMultiplicationTests {

    private func freebmd() -> (any RecordSource)? {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        return registry.allSources().first { $0.sourceID == "freebmd" }
    }

    /// `queries` carries one entry per geographic axis, so its count is the
    /// geographic breadth the tier is about to fan out across.
    private func queries(axes: Int, givenName: String?) -> [RecordQuery] {
        (0..<axes).map { i in
            RecordQuery(
                surname: "Thompson", givenName: givenName, recordType: .death,
                yearFrom: 1816, yearTo: 1906, gender: .male, region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: nil, countyCode: "C\(i)", wildcardSurname: false,
                    motherSurname: nil, spouseSurname: nil)))
        }
    }

    /// A NARROW geography keeps the full spelling fan-out — this is where
    /// variants earn their keep, and the fix must not gut them.
    @Test func narrowGeographyKeepsTheFullFanOut() throws {
        let source = try #require(freebmd())
        let result = SearchDispatcher.applyStrictness(
            queries(axes: 1, givenName: "John"), strictness: .variant, source: source)
        let surnames = Set(result.compactMap(\.surname).map { $0.lowercased() })
        let givens = Set(result.compactMap(\.givenName).map { $0.lowercased() })
        #expect(surnames.count > 3, "one county should still try many spellings")
        #expect(givens.count > 1, "…and nickname variants too")
    }

    /// THE SPECIMEN: a WIDE geography trims the spelling axis hard.
    @Test func wideGeographyTrimsTheSpellingAxis() throws {
        let source = try #require(freebmd())
        let narrow = SearchDispatcher.applyStrictness(
            queries(axes: 1, givenName: "John"), strictness: .variant, source: source)
        let wide = SearchDispatcher.applyStrictness(
            queries(axes: 7, givenName: "John"), strictness: .variant, source: source)

        let narrowSurnames = Set(narrow.compactMap(\.surname).map { $0.lowercased() }).count
        let wideSurnames = Set(wide.compactMap(\.surname).map { $0.lowercased() }).count
        #expect(wideSurnames < narrowSurnames,
                "seven counties must not each get the full spelling fan-out")
        #expect(wideSurnames <= 3, "original plus at most two variants; got \(wideSurnames)")
    }

    /// The nickname axis drops first — it is the weakest of the three
    /// hypotheses and the one that produced "JACK tomson".
    @Test func wideGeographyDropsTheNicknameAxis() throws {
        let source = try #require(freebmd())
        let wide = SearchDispatcher.applyStrictness(
            queries(axes: 7, givenName: "John"), strictness: .variant, source: source)
        let givens = Set(wide.compactMap(\.givenName).map { $0.lowercased() })
        #expect(givens == ["john"], "no nickname fan-out across a wide geography; got \(givens)")
    }

    /// The product stays bounded rather than merely smaller.
    @Test func theTotalQueryCountStaysBounded() throws {
        let source = try #require(freebmd())
        let wide = SearchDispatcher.applyStrictness(
            queries(axes: 7, givenName: "John"), strictness: .variant, source: source)
        #expect(wide.count <= 7 * 3,
                "7 counties x (original + 2 spellings) is the ceiling; got \(wide.count)")
    }

    /// Every geographic axis is still searched — the cap trims spellings, it
    /// never drops a county the user asked for.
    @Test func noGeographicAxisIsLost() throws {
        let source = try #require(freebmd())
        let wide = SearchDispatcher.applyStrictness(
            queries(axes: 7, givenName: "John"), strictness: .variant, source: source)
        let counties: Set<String> = Set(wide.compactMap { q in
            guard case .freeBMD(let p) = q.sourceParams else { return nil }
            return p.countyCode
        })
        #expect(counties.count == 7, "lost a county: \(counties.sorted())")
    }

    /// The original spelling survives at any breadth — it is the one spelling
    /// we actually have evidence for.
    @Test func theOriginalSpellingIsNeverTrimmed() throws {
        let source = try #require(freebmd())
        for axes in [1, 4, 7, 20] {
            let result = SearchDispatcher.applyStrictness(
                queries(axes: axes, givenName: "John"), strictness: .variant, source: source)
            let surnames = Set(result.compactMap(\.surname).map { $0.lowercased() })
            #expect(surnames.contains("thompson"), "lost the real spelling at \(axes) axes")
        }
    }
}
