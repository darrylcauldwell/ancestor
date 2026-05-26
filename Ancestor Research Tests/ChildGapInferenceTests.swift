import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the child-gap inference helpers backing the
/// post-iteration Victorian-era infant-death pivot. Mirrors
/// `agent/rules.py:child_gap_suggests_death` and the use site in
/// `agent/analyser.py:_check_child_gaps`.
@MainActor
struct ChildGapInferenceTests {

    /// Tuple-of-Int comparison helper — `(Int, Int)` arrays don't
    /// auto-conform to Equatable, so flatten to pairs of ints for the
    /// assertions.
    private func flat(_ gaps: [(Int, Int)]) -> [Int] {
        gaps.flatMap { [$0.0, $0.1] }
    }

    @Test func zeroChildrenYieldsNoGaps() {
        #expect(ResearchPipeline.childBirthYearGaps([]).isEmpty)
    }

    @Test func singleChildYieldsNoGaps() {
        #expect(ResearchPipeline.childBirthYearGaps([1880]).isEmpty)
    }

    @Test func consecutiveChildrenWithinThresholdYieldNoGaps() {
        // 2-year spacing is normal — under the threshold of 3.
        let gaps = ResearchPipeline.childBirthYearGaps([1880, 1882, 1884, 1886])
        #expect(gaps.isEmpty)
    }

    @Test func gapAtThresholdBoundaryIsNotFlagged() {
        // Python uses `gap > threshold` (strictly greater), so a
        // 3-year gap at threshold=3 should NOT fire. Pin the boundary.
        let gaps = ResearchPipeline.childBirthYearGaps([1880, 1883])
        #expect(gaps.isEmpty)
    }

    @Test func gapOneOverThresholdFires() {
        // 4-year gap → fires.
        let gaps = ResearchPipeline.childBirthYearGaps([1880, 1884])
        #expect(flat(gaps) == [1880, 1884])
    }

    @Test func multipleGapsSurfaceSeparately() {
        // Children at 1880, 1885 (5-yr gap), 1888 (3-yr — fine),
        // 1894 (6-yr gap). Two gaps fire.
        let gaps = ResearchPipeline.childBirthYearGaps([1880, 1885, 1888, 1894])
        #expect(flat(gaps) == [1880, 1885, 1888, 1894])
    }

    @Test func unsortedInputIsSortedBeforeAnalysis() {
        // Children passed in arbitrary order should still give the
        // same gaps. Defensive — caller shouldn't have to pre-sort.
        let gaps = ResearchPipeline.childBirthYearGaps([1894, 1880, 1885, 1888])
        #expect(flat(gaps) == [1880, 1885, 1888, 1894])
    }

    @Test func mostCommonReturnsModeOfElements() {
        // Child surnames: ["Brooks", "Brooks", "Smith"] → "Brooks"
        // wins. Handles the step-sibling defensively-most-common case.
        #expect(ResearchPipeline.mostCommon(["Brooks", "Brooks", "Smith"]) == "Brooks")
    }

    @Test func mostCommonOfEmptyIsNil() {
        let result: String? = ResearchPipeline.mostCommon([] as [String])
        #expect(result == nil)
    }

    @Test func mostCommonOfSingleElementYieldsThatElement() {
        #expect(ResearchPipeline.mostCommon(["Brooks"]) == "Brooks")
    }
}
