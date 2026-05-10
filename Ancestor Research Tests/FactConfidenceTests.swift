import Testing
import Foundation
@testable import Ancestor_Research

/// Pure-data coverage of `FactConfidence` and the file-scope
/// `effectiveConfidence(_:)` helper that drives the M12 visual indicators.
/// The helper deliberately collapses standard / mixed / unset to nil so the
/// inspector and tree node render unchanged in those (common) cases.
struct FactConfidenceTests {

    // MARK: - Helpers

    private func makeSource(
        confidence: FactConfidence?,
        identifier: String = "test",
        raw: String = UUID().uuidString
    ) -> FieldSource {
        FieldSource(
            origin: SourceOrigin(identifier: identifier),
            raw: raw,
            addedAt: Date(),
            confidence: confidence
        )
    }

    // MARK: - Enum invariants

    @Test func factConfidenceRawIntRoundTrip() {
        #expect(FactConfidence.tentative.rawInt == 0)
        #expect(FactConfidence.standard.rawInt == 1)
        #expect(FactConfidence.wellEvidenced.rawInt == 2)

        for c in FactConfidence.allCases {
            let round = FactConfidence(rawInt: c.rawInt)
            #expect(round == c)
        }
        #expect(FactConfidence(rawInt: 99) == nil)
    }

    @Test func factConfidenceDisplayNameAndExplanationAreNonEmpty() {
        for c in FactConfidence.allCases {
            #expect(!c.displayName.isEmpty)
            #expect(!c.explanation.isEmpty)
        }
    }

    // MARK: - effectiveConfidence(_:)

    @Test func effectiveConfidenceReturnsNilForEmpty() {
        #expect(effectiveConfidence([]) == nil)
    }

    @Test func effectiveConfidenceFavorsWellEvidenced() {
        // Mixed bag: tentative + standard + wellEvidenced — wellEvidenced wins.
        let sources = [
            makeSource(confidence: .tentative, raw: "a"),
            makeSource(confidence: .standard, raw: "b"),
            makeSource(confidence: .wellEvidenced, raw: "c"),
        ]
        #expect(effectiveConfidence(sources) == .wellEvidenced)

        // Single wellEvidenced source — still wellEvidenced.
        let single = [makeSource(confidence: .wellEvidenced, raw: "d")]
        #expect(effectiveConfidence(single) == .wellEvidenced)
    }

    @Test func effectiveConfidenceReturnsTentativeOnlyWhenAllAreTentative() {
        // All tentative → tentative.
        let allTentative = [
            makeSource(confidence: .tentative, raw: "a"),
            makeSource(confidence: .tentative, raw: "b"),
        ]
        #expect(effectiveConfidence(allTentative) == .tentative)

        // Mixed tentative + standard → nil (standard counterweights).
        let mixed = [
            makeSource(confidence: .tentative, raw: "c"),
            makeSource(confidence: .standard, raw: "d"),
        ]
        #expect(effectiveConfidence(mixed) == nil)

        // Tentative + nil-confidence sources → tentative. Sources without a
        // recorded confidence are filtered out (compactMap), leaving only the
        // explicit tentative entries — they collectively satisfy the
        // "all recorded confidences are tentative" rule.
        let tentativeAndUnset = [
            makeSource(confidence: .tentative, raw: "e"),
            makeSource(confidence: nil, raw: "f"),
        ]
        #expect(effectiveConfidence(tentativeAndUnset) == .tentative)
    }

    @Test func effectiveConfidenceReturnsNilForOnlyStandardOrUnset() {
        // All standard → no indicator.
        let allStandard = [
            makeSource(confidence: .standard, raw: "a"),
            makeSource(confidence: .standard, raw: "b"),
        ]
        #expect(effectiveConfidence(allStandard) == nil)

        // Sources with no recorded confidence at all → no indicator.
        let allUnset = [
            makeSource(confidence: nil, raw: "c"),
            makeSource(confidence: nil, raw: "d"),
        ]
        #expect(effectiveConfidence(allUnset) == nil)
    }
}
