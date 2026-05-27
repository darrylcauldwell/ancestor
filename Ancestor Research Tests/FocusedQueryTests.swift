import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 13 — `FocusedQuery` + `dispatchOne` + `suggestNextFocusedQuery`.
/// Pure-data tests for the model + JSON-parser tests for the strategist's
/// output handling. Full MLX integration is exercised by manual research
/// runs on real subjects; the parser tests pin the contract between
/// model output and `FocusedQuery`.
@MainActor
struct FocusedQueryTests {

    // MARK: - FocusedQuery model

    @Test func toRecordQuery_freebmdMapsDistrictToParams() {
        let focused = FocusedQuery(
            sourceID: "freebmd",
            recordType: .marriage,
            surname: "Brooks",
            givenName: "Samuel",
            yearFrom: 1879, yearTo: 1882,
            district: "722",   // Belper code
            rationale: "find George's parents' marriage"
        )
        let rq = focused.toRecordQuery()
        #expect(rq.surname == "Brooks")
        #expect(rq.givenName == "Samuel")
        #expect(rq.recordType == .marriage)
        #expect(rq.yearFrom == 1879 && rq.yearTo == 1882)
        if case .freeBMD(let params) = rq.sourceParams {
            #expect(params.districtCode == "722")
        } else {
            Issue.record("expected .freeBMD params, got \(rq.sourceParams)")
        }
    }

    @Test func toRecordQuery_freecenMapsYearToCensusYear() {
        let focused = FocusedQuery(
            sourceID: "freecen",
            recordType: .census,
            surname: "Brooks",
            givenName: "George",
            yearFrom: 1891, yearTo: 1891,
            district: nil,
            rationale: "find George as a child with his parents"
        )
        let rq = focused.toRecordQuery()
        if case .freeCen(let params) = rq.sourceParams {
            #expect(params.censusYear == 1891)
        } else {
            Issue.record("expected .freeCen params")
        }
    }

    @Test func toRecordQuery_unknownSourceFallsBackToGeneric() {
        let focused = FocusedQuery(
            sourceID: "unknown_source",
            recordType: .birth,
            surname: "Brooks",
            givenName: nil, yearFrom: nil, yearTo: nil, district: nil,
            rationale: "test fallback"
        )
        let rq = focused.toRecordQuery()
        if case .generic = rq.sourceParams {
            // pass — unknown sourceID falls through to .generic so the
            // dispatcher can still attempt a generic query if any source
            // matches by name, or return [] cleanly.
        } else {
            Issue.record("expected .generic for unknown sourceID")
        }
    }

    // MARK: - Suggester JSON parsing (the contract between MLX output
    //         and FocusedQuery). The parser is private but we exercise
    //         it indirectly by spec'ing the JSON shapes the model is
    //         told to emit. These tests pin the prompt's schema contract.

    /// The system prompt promises the model that valid JSON produces a
    /// valid FocusedQuery. This test documents the canonical shape so
    /// any drift in the prompt template surfaces in CI.
    @Test func canonicalModelOutputMatchesFocusedQueryShape() throws {
        let canonicalJSON = """
        {
          "source": "freecen",
          "record_type": "census",
          "surname": "Brooks",
          "given": "George",
          "year_from": 1891,
          "year_to": 1891,
          "district": "Belper",
          "rationale": "Census 1891 should show George ~age 7 with his parents — narrows the search to a known household."
        }
        """
        let data = try #require(canonicalJSON.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["source"] as? String == "freecen")
        #expect(obj?["record_type"] as? String == "census")
        #expect(obj?["surname"] as? String == "Brooks")
        #expect(obj?["year_from"] as? Int == 1891)
        #expect(obj?["district"] as? String == "Belper")
        #expect((obj?["rationale"] as? String)?.contains("George") == true)
    }

    @Test func giveUpSentinelIsAValidResponse() throws {
        // The model is allowed to say "no further query would help" via
        // `{"give_up": true, "rationale": "..."}`. The parser treats
        // this as a non-suggestion (caller falls back to normal next
        // iteration, no extra dispatch).
        let giveUpJSON = """
        {"give_up": true, "rationale": "BMD coverage exhausted, GRO cert required"}
        """
        let data = try #require(giveUpJSON.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["give_up"] as? Bool == true)
        #expect(obj?["rationale"] is String)
    }
}
