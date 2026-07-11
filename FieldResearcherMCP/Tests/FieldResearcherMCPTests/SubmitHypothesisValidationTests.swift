import Testing
import Foundation
@testable import FieldResearcherMCP

/// Unit tests for the `submit_hypothesis` synchronous validation core
/// (RESEARCH_PIPELINE_SPEC §5.15.2 / §5.15.7, Decision E2). These cover
/// the pure logic only — profile facts are pre-fetched by the caller,
/// same pattern as `PromoteLeadDedupTests`. The rejection-memory check
/// and the seeds-table INSERT ride the SQL path exercised end-to-end by
/// the app-side `HypothesisSeedServiceTests`.
struct SubmitHypothesisValidationTests {

    // Convenience wrapper — a valid baseline call every case perturbs.
    private func validate(
        profileID: String = "p1",
        profileExists: Bool = true,
        birthYearEarliest: Int? = 1887,
        birthYearLatest: Int? = 1887,
        fatherGiven: String? = "Bob",
        fatherSurname: String? = nil,
        motherGiven: String? = "Sue",
        motherMaidenSurname: String? = nil,
        windowStart: Int? = nil,
        windowEnd: Int? = nil
    ) -> MCPHandler.HypothesisSeedValidation {
        MCPHandler.validateHypothesisSeed(
            profileID: profileID,
            profileExists: profileExists,
            birthYearEarliest: birthYearEarliest,
            birthYearLatest: birthYearLatest,
            fatherGiven: fatherGiven,
            fatherSurname: fatherSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: motherMaidenSurname,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }

    // MARK: - Refusal codes (§5.15.2)

    @Test func allNilHintsRefusedWithNoNameHints() {
        let v = validate(fatherGiven: nil, motherGiven: nil)
        #expect(v == .refused(reason: "no_name_hints"))
    }

    @Test func noNameHintsTakesPrecedenceOverProfileNotFound() {
        // §5.15.2 lists the rules in order; an assertion-free seed is
        // refused as such even when the profile is also unknown.
        let v = validate(profileExists: false, fatherGiven: nil, motherGiven: nil)
        #expect(v == .refused(reason: "no_name_hints"))
    }

    @Test func unknownProfileRefused() {
        let v = validate(profileExists: false)
        #expect(v == .refused(reason: "profile_not_found"))
    }

    @Test func noBirthEstimateAndNoWindowRefused() {
        let v = validate(birthYearEarliest: nil, birthYearLatest: nil)
        #expect(v == .refused(reason: "no_subject_birth_estimate"))
    }

    @Test func backwardsWindowRefused() {
        let v = validate(windowStart: 1900, windowEnd: 1850)
        #expect(v == .refused(reason: "invalid_window"))
    }

    // MARK: - Window derivation (§5.15.1: birthYear − 30 … birthYear + 1)

    @Test func windowDefaultsFromBirthEstimate() {
        let v = validate()
        #expect(v == .valid(
            identityKey: "parentCandidates:p1:BOBxxSUEx:1857-1888",
            windowStart: 1857, windowEnd: 1888
        ))
    }

    @Test func birthLatestUsedWhenEarliestAbsent() {
        let v = validate(birthYearEarliest: nil, birthYearLatest: 1890)
        guard case .valid(_, let start, let end) = v else {
            Issue.record("expected valid, got \(v)")
            return
        }
        #expect(start == 1860)
        #expect(end == 1891)
    }

    @Test func explicitBoundsOverrideDerivedDefaults() {
        let v = validate(windowStart: 1860, windowEnd: 1870)
        guard case .valid(_, let start, let end) = v else {
            Issue.record("expected valid, got \(v)")
            return
        }
        #expect(start == 1860)
        #expect(end == 1870)
    }

    @Test func partialBoundsMergeWithDerivedDefaults() {
        // The user may narrow one side only; the other derives.
        let v = validate(windowStart: 1870)
        guard case .valid(_, let start, let end) = v else {
            Issue.record("expected valid, got \(v)")
            return
        }
        #expect(start == 1870)
        #expect(end == 1888)
    }

    @Test func explicitWindowValidWithoutBirthEstimate() {
        let v = validate(
            birthYearEarliest: nil, birthYearLatest: nil,
            windowStart: 1850, windowEnd: 1880
        )
        guard case .valid = v else {
            Issue.record("expected valid, got \(v)")
            return
        }
    }

    @Test func singleHintIsSufficient() {
        let v = validate(fatherGiven: nil, motherGiven: nil,
                         motherMaidenSurname: "Smith")
        guard case .valid(let key, _, _) = v else {
            Issue.record("expected valid, got \(v)")
            return
        }
        #expect(key == "parentCandidates:p1:xxxSMITH:1857-1888")
    }

    // MARK: - identityKey mirror (must match AncestorKit's composition)

    @Test func identityKeyComposesUppercasedHintsWithNilNormalisation() {
        let key = MCPHandler.parentCandidatesIdentityKey(
            profileID: "subj-1",
            fatherGiven: "Bob", fatherSurname: "Wheeldon",
            motherGiven: "Sue", motherMaidenSurname: "Smith",
            windowStart: 1850, windowEnd: 1881
        )
        // Expected literal mirrors ParentCandidatesHypothesisTests in the
        // app suite — the two implementations must never drift.
        #expect(key == "parentCandidates:subj-1:BOBxWHEELDONxSUExSMITH:1850-1881")
    }

    @Test func identityKeyNilHintsNormaliseToEmpty() {
        let key = MCPHandler.parentCandidatesIdentityKey(
            profileID: "subj-1",
            fatherGiven: nil, fatherSurname: nil,
            motherGiven: "Sue", motherMaidenSurname: nil,
            windowStart: 1850, windowEnd: 1881
        )
        #expect(key == "parentCandidates:subj-1:xxSUEx:1850-1881")
    }

    // MARK: - Hint trimming

    @Test func trimmedHintNormalisesWhitespaceToNil() {
        #expect(MCPHandler.trimmedHint("   ") == nil)
        #expect(MCPHandler.trimmedHint("") == nil)
        #expect(MCPHandler.trimmedHint(nil) == nil)
        #expect(MCPHandler.trimmedHint(42) == nil)
        #expect(MCPHandler.trimmedHint("  Bob ") == "Bob")
    }
}
