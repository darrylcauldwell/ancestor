import Testing
import Foundation
@testable import FieldResearcherMCP

/// Unit tests for the dedup decision helper used by `promote_lead`
/// (ENGINE_FOUNDATION_SPEC #Change3). These cover the pure matching
/// logic only; the SQL fetch + side-effect path is exercised by the
/// existing integration setup (out of scope for this test file).
struct PromoteLeadDedupTests {

    // Convenience constructor — keeps the test cases readable.
    private func candidate(
        _ id: String,
        first: String? = nil,
        last: String? = "Holmes",
        bYearEarly: Int? = nil,
        bYearLate: Int? = nil
    ) -> MCPHandler.DedupCandidate {
        MCPHandler.DedupCandidate(
            profileID: id,
            firstName: first,
            lastName: last,
            birthYearEarliest: bYearEarly,
            birthYearLatest: bYearLate
        )
    }

    // MARK: - Strict-match path (both sides have given name)

    @Test func strictMatchSinglePointDedups() {
        // Jennifer in tree, Jennifer in lead, same year — single match.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1942, bYearLate: 1942)
            ]
        )
        #expect(decision == .matched(profileID: "@I001@"))
    }

    @Test func strictMatchCaseInsensitive() {
        let decision = MCPHandler.decideDedup(
            leadGivenName: "JENNIFER",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "jennifer", bYearEarly: 1942, bYearLate: 1942)
            ]
        )
        #expect(decision == .matched(profileID: "@I001@"))
    }

    @Test func strictMatchYearTolerancePlusMinus2() {
        // Lead 1942, candidate 1944 — within ±2.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1944, bYearLate: 1944)
            ]
        )
        #expect(decision == .matched(profileID: "@I001@"))
    }

    @Test func strictMatchYearOutsideToleranceNoMatch() {
        // Lead 1942, candidate 1950 — outside ±2.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1950, bYearLate: 1950)
            ]
        )
        #expect(decision == .noMatch)
    }

    @Test func strictMatchDifferentGivenNamesNoMatch() {
        // Same surname + year, different given name — not the same person.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "Janet", bYearEarly: 1942, bYearLate: 1942)
            ]
        )
        #expect(decision == .noMatch)
    }

    @Test func strictMatchTwinsSplitsRatherThanMerges() {
        // Two Jennifer Holmes born 1942 (real twins, or one is a duplicate
        // worth investigating). Split-don't-merge per CLAUDE.md — INSERT
        // new rather than guess which to dedup against.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1942, bYearLate: 1942),
                candidate("@I002@", first: "Jennifer", bYearEarly: 1942, bYearLate: 1942)
            ]
        )
        #expect(decision == .multipleMatches)
    }

    // MARK: - Asymmetric path (Jennifer Holmes empirical case)

    @Test func asymmetricMatchLeadSurnameOnlyDedups() {
        // The empirical bug: lead arrives as surname-only HOLMES;
        // existing tree profile is rich (Jennifer Holmes, b. 1942).
        // Year overlap + single candidate → dedup.
        let decision = MCPHandler.decideDedup(
            leadGivenName: nil,
            leadBirthYearEarliest: 1940,
            leadBirthYearLatest: 1945,
            candidates: [
                candidate("@I50100815@", first: "Jennifer", bYearEarly: 1942, bYearLate: 1942)
            ]
        )
        #expect(decision == .matched(profileID: "@I50100815@"))
    }

    @Test func asymmetricMatchLeadSurnameOnlyMultipleCandidatesSplits() {
        // Surname-only lead matches two existing Holmeses born around the
        // same time — engine can't tell which is the right one, so it
        // splits (INSERT new) and lets the user merge later if needed.
        let decision = MCPHandler.decideDedup(
            leadGivenName: nil,
            leadBirthYearEarliest: 1940,
            leadBirthYearLatest: 1945,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1942, bYearLate: 1942),
                candidate("@I002@", first: "Janet", bYearEarly: 1944, bYearLate: 1944)
            ]
        )
        #expect(decision == .multipleMatches)
    }

    @Test func asymmetricMatchCandidateSurnameOnlyDedups() {
        // Inverse asymmetric case: rich lead, surname-only candidate.
        // Same dedup path.
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@FR_A@", first: nil, bYearEarly: 1940, bYearLate: 1945)
            ]
        )
        #expect(decision == .matched(profileID: "@FR_A@"))
    }

    @Test func bothSurnameOnlyWithYearOverlapDedups() {
        // Both lead and candidate are surname-only with overlapping year
        // windows. Single match → dedup.
        let decision = MCPHandler.decideDedup(
            leadGivenName: nil,
            leadBirthYearEarliest: 1940,
            leadBirthYearLatest: 1945,
            candidates: [
                candidate("@FR_A@", first: nil, bYearEarly: 1942, bYearLate: 1948)
            ]
        )
        #expect(decision == .matched(profileID: "@FR_A@"))
    }

    @Test func asymmetricMatchYearOutsideOverlapNoMatch() {
        // Surname-only lead but year windows don't overlap (even with
        // ±2 fudge) — distinct people.
        let decision = MCPHandler.decideDedup(
            leadGivenName: nil,
            leadBirthYearEarliest: 1940,
            leadBirthYearLatest: 1945,
            candidates: [
                candidate("@I001@", first: "Jennifer", bYearEarly: 1900, bYearLate: 1905)
            ]
        )
        #expect(decision == .noMatch)
    }

    // MARK: - No-match cases

    @Test func emptyCandidateListIsNoMatch() {
        let decision = MCPHandler.decideDedup(
            leadGivenName: "Jennifer",
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: []
        )
        #expect(decision == .noMatch)
    }

    @Test func candidateWithNoYearAcceptsThroughSurnameAlone() {
        // Candidate has no year info — overlap is treated as compatible
        // (the SQL surname filter is the only binding signal). Single
        // candidate → dedup.
        let decision = MCPHandler.decideDedup(
            leadGivenName: nil,
            leadBirthYearEarliest: 1942,
            leadBirthYearLatest: 1942,
            candidates: [
                candidate("@FR_A@", first: nil, bYearEarly: nil, bYearLate: nil)
            ]
        )
        #expect(decision == .matched(profileID: "@FR_A@"))
    }

    // MARK: - yearWindowsOverlap edge cases

    @Test func yearWindowsOverlapExactBoundary() {
        // Lead [1940..1942], candidate [1944..1945] → ±2 fudge brings
        // lead's window to [1938..1944], which touches candidate's 1944.
        #expect(MCPHandler.yearWindowsOverlap(
            aEarliest: 1940, aLatest: 1942,
            bEarliest: 1944, bLatest: 1945
        ))
    }

    @Test func yearWindowsOverlapClearGap() {
        // [1940..1942] (+ ±2 = [1938..1944]) vs [1950..1952] — no overlap.
        #expect(!MCPHandler.yearWindowsOverlap(
            aEarliest: 1940, aLatest: 1942,
            bEarliest: 1950, bLatest: 1952
        ))
    }

    @Test func yearWindowsOverlapBothMissingReturnsTrue() {
        // Both sides have no year info — accept (rare; the surname filter
        // is the only signal in this case).
        #expect(MCPHandler.yearWindowsOverlap(
            aEarliest: nil, aLatest: nil,
            bEarliest: nil, bLatest: nil
        ))
    }

    @Test func yearWindowsOverlapOnlyOneSideMissingReturnsTrue() {
        // Candidate has no year — be permissive (single-match gate in
        // decideDedup still keeps us honest).
        #expect(MCPHandler.yearWindowsOverlap(
            aEarliest: 1942, aLatest: 1942,
            bEarliest: nil, bLatest: nil
        ))
    }

    @Test func yearWindowsOverlapSinglePointWindows() {
        // Both sides are single-year (earliest == latest), ±2 means
        // windows up to 4 years apart still match.
        #expect(MCPHandler.yearWindowsOverlap(
            aEarliest: 1942, aLatest: 1942,
            bEarliest: 1944, bLatest: 1944
        ))
        #expect(!MCPHandler.yearWindowsOverlap(
            aEarliest: 1942, aLatest: 1942,
            bEarliest: 1945, bLatest: 1945
        ))
    }
}
