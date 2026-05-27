import Testing
import Foundation
@testable import Ancestor_Research

/// Pins start-of-run birth-window narrowing from persisted `field_sources`.
///
/// `Profile.birthDate` carries one value (the wide range when sources
/// disagree), but `profile.sources[.birthDate]` is the audit log of every
/// value ever asserted by any source. Without seeding, every research run
/// restarts from the wide window regardless of precise quarters earlier
/// runs uncovered — `refineSubject` reads only the *in-run*
/// `state.confirmedFacts`, so prior precision is lost.
///
/// Anchored to the George H Brooks case: `Profile.birthDate` =
/// "BET 1869 AND 1896" but `field_sources` carries "Jun 1870" and the
/// correct "Dec 1883". The narrowest-then-latest rule must pick Dec 1883.
struct ResearchSubjectBirthPrecisionSeedingTests {

    // MARK: - Helpers

    private func source(_ raw: String, addedAt: Date) -> FieldSource {
        FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: raw, addedAt: addedAt)
    }

    private func date(year: Int, month: Int = 1, day: Int = 1) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Narrowing

    @Test func narrowsToPreciseSourceWhenProfileBirthDateIsWide() {
        // Current window from profile.birthDate is wide; a precise source
        // exists in field_sources — narrow to it.
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [
                source("BET 1869 AND 1896", addedAt: date(year: 2024)),
                source("Dec 1883", addedAt: date(year: 2024, month: 6)),
            ],
            dispute: nil
        )
        #expect(result.0 == 1883)
        #expect(result.1 == 1883)
    }

    @Test func refusesToNarrowWhenMultiplePreciseCandidatesTieOnSpan() {
        // Jun 1870 and Dec 1883 both have span 0 — silently picking either
        // (e.g. by addedAt recency) risks seeding the wrong year and having
        // the engine build on a wrong premise. Refuse; let multi-hypothesis
        // investigation resolve it via corroborating evidence.
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [
                source("BET 1869 AND 1896", addedAt: date(year: 2024, month: 1)),
                source("Jun 1870", addedAt: date(year: 2024, month: 2)),
                source("Dec 1883", addedAt: date(year: 2024, month: 4)),
            ],
            dispute: nil
        )
        #expect(result.0 == 1869)
        #expect(result.1 == 1896)
    }

    @Test func narrowsWhenDuplicateRowsForSameYearAreNotTrueDisagreement() {
        // A FreeBMD record written twice across two scoring passes isn't a
        // disagreement — same (earliest, latest). Should narrow normally,
        // because the only narrow candidate after dedup is unique.
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [
                source("BET 1869 AND 1896", addedAt: date(year: 2024, month: 1)),
                source("Jun 1870", addedAt: date(year: 2024, month: 2)),
                source("Jun 1870", addedAt: date(year: 2024, month: 3)),
            ],
            dispute: nil
        )
        #expect(result.0 == 1870)
        #expect(result.1 == 1870)
    }

    @Test func doesNotWidenWhenSourcesAreCoarserThanCurrent() {
        // Profile already has a precise quarter — wider sources must not
        // override. (Mirrors `feedback_check_before_overwrite.md`.)
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1883, 1883),
            sources: [
                source("BET 1869 AND 1896", addedAt: date(year: 2026)),
                source("ABT 1880", addedAt: date(year: 2026, month: 2)),
            ],
            dispute: nil
        )
        #expect(result.0 == 1883)
        #expect(result.1 == 1883)
    }

    @Test func leavesWindowUnchangedWhenNoSources() {
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [],
            dispute: nil
        )
        #expect(result.0 == 1869)
        #expect(result.1 == 1896)
    }

    @Test func leavesWindowUnchangedWhenSourcesAreUnparseable() {
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [source("nonsense", addedAt: date(year: 2024))],
            dispute: nil
        )
        #expect(result.0 == 1869)
        #expect(result.1 == 1896)
    }

    @Test func narrowsFromNilCurrentWhenPreciseSourcePresent() {
        // Current window is fully unknown — any finite source wins.
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (nil, nil),
            sources: [source("Dec 1883", addedAt: date(year: 2024))],
            dispute: nil
        )
        #expect(result.0 == 1883)
        #expect(result.1 == 1883)
    }

    // MARK: - Dispute handling

    @Test func refusesToNarrowWhenDisputeIsDeferred() {
        // User explicitly deferred picking a winner — don't auto-pick.
        let dispute = FieldDispute(
            field: .birthDate,
            reason: .valueMismatch,
            competingSources: [],
            detectedAt: Date(),
            resolution: .deferred
        )
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [source("Dec 1883", addedAt: date(year: 2024))],
            dispute: dispute
        )
        #expect(result.0 == 1869)
        #expect(result.1 == 1896)
    }

    @Test func refusesToNarrowWhenDisputeIsUnresolved() {
        // Dispute on file, no resolution chosen — same caution.
        let dispute = FieldDispute(
            field: .birthDate,
            reason: .valueMismatch,
            competingSources: [],
            detectedAt: Date(),
            resolution: nil
        )
        let result = ResearchSubject.narrowBirthWindowFromSources(
            current: (1869, 1896),
            sources: [source("Dec 1883", addedAt: date(year: 2024))],
            dispute: dispute
        )
        #expect(result.0 == 1869)
        #expect(result.1 == 1896)
    }
}
