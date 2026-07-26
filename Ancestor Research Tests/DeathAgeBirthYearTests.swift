import Testing
import Foundation
import AncestorKit

/// `DeathAgeBirthYear` — derives a calculated birth year for a person with a
/// FIRM death date but no birth year, by matching that date to their own
/// death-index record and reading the age at death. Modelled on the real
/// Thompson branch (Tree-2): John William d.19 Nov 1922 and his wife Mary Anne
/// d.30 Oct 1923, both registered in the Bakewell district aged 69.
struct DeathAgeBirthYearTests {

    private func candidate(_ id: String, year: Int?, age: Int?, quarter: String?,
                           district: String? = nil) -> DeathAgeBirthYear.Candidate {
        DeathAgeBirthYear.Candidate(
            recordID: id, sourceID: "freebmd", deathYear: year,
            ageAtDeath: age, quarter: quarter, district: district)
    }

    // MARK: - groQuarter (GRO end-month labelling)

    @Test func groQuarterMapsToEndMonthAbbreviations() {
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 1) == "Mar")
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 3) == "Mar")
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 4) == "Jun")
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 7) == "Sep")
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 10) == "Dec")
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 11) == "Dec")   // John William, 19 Nov
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 0) == nil)
        #expect(DeathAgeBirthYear.groQuarter(forMonth: 13) == nil)
    }

    // MARK: - John William: one clean match, other quarters ignored

    @Test func firmQuarterPicksTheOneMatchingDeathIndexEntry() {
        // Firm death 19 Nov 1922 → Dec quarter. Only the Dec/Bakewell/age-69
        // record matches; the Jun and Sep same-year namesakes are dropped on
        // quarter, so the estimate is unambiguous: 1922 − 69 = 1853.
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil,
            firmDeathYear: 1922,
            firmDeathQuarter: "Dec",
            candidates: [
                candidate("bakewell", year: 1922, age: 69, quarter: "Dec", district: "Bakewell"),
                candidate("derby-jun", year: 1922, age: 72, quarter: "Jun", district: "Derby"),
                candidate("derby-sep", year: 1922, age: 81, quarter: "Sep", district: "Derby"),
            ])
        #expect(p?.estimatedBirthYear == 1853)
        #expect(p?.ageAtDeath == 69)
        #expect(p?.sourceRecordID == "bakewell")
    }

    // MARK: - Mary Anne: two same-quarter matches that AGREE

    @Test func twoMatchesAgreeingWithinBandPropose() {
        // Firm 30 Oct 1923 → Dec quarter. Two Dec-1923 candidates survive
        // (Bakewell age 69 → 1854, Rotherham age 70 → 1853). They agree within
        // the ±1 band, so the calculated estimate is safe regardless of which
        // is truly hers — exactly the fuzzy bracket we want.
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil,
            firmDeathYear: 1923,
            firmDeathQuarter: "Dec",
            candidates: [
                candidate("bakewell", year: 1923, age: 69, quarter: "Dec", district: "Bakewell"),
                candidate("rotherham", year: 1923, age: 70, quarter: "Dec", district: "Rotherham"),
            ])
        #expect(p != nil)
        #expect(p?.estimatedBirthYear == 1853)     // earliest implied — deterministic
    }

    @Test func matchesDisagreeingBeyondBandDecline() {
        // Same quarter+year, but one entry is a 5-year-old child → implied years
        // 1853 vs 1918 disagree wildly → decline rather than guess (when in
        // doubt, split).
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil,
            firmDeathYear: 1923,
            firmDeathQuarter: "Dec",
            candidates: [
                candidate("adult", year: 1923, age: 70, quarter: "Dec"),
                candidate("child", year: 1923, age: 5, quarter: "Dec"),
            ])
        #expect(p == nil)
    }

    // MARK: - Florence: an age but nothing that resolves → decline

    @Test func ageWithoutMatchingQuarterDeclines() {
        // Firm 12 May 1913 → Jun quarter. The only age-bearing entry has no
        // quarter (can't confirm against a known firm quarter); the
        // quarter-matching entries carry no age. Nothing resolves → decline.
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil,
            firmDeathYear: 1913,
            firmDeathQuarter: "Jun",
            candidates: [
                candidate("age-no-quarter", year: 1913, age: 32, quarter: nil),
                candidate("sep-no-age", year: 1913, age: nil, quarter: "Sep"),
            ])
        #expect(p == nil)
    }

    // MARK: - Gap-only + junk guards

    @Test func silentWhenBirthYearAlreadyPresent() {
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: 1850,
            firmDeathYear: 1922, firmDeathQuarter: "Dec",
            candidates: [candidate("x", year: 1922, age: 69, quarter: "Dec")])
        #expect(p == nil)
    }

    @Test func silentWithoutAPreciseDeathYear() {
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil, firmDeathYear: nil, firmDeathQuarter: nil,
            candidates: [candidate("x", year: 1922, age: 69, quarter: "Dec")])
        #expect(p == nil)
    }

    @Test func implausibleAgeIsIgnored() {
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil, firmDeathYear: 1922, firmDeathQuarter: "Dec",
            candidates: [candidate("junk", year: 1922, age: 999, quarter: "Dec")])
        #expect(p == nil)
    }

    // MARK: - Quarter discipline + year slop

    @Test func candidateWithoutQuarterDroppedWhenFirmQuarterKnown() {
        // A known firm quarter can't be confirmed against a quarter-less
        // candidate → it's dropped (namesake protection).
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil, firmDeathYear: 1922, firmDeathQuarter: "Dec",
            candidates: [candidate("noq", year: 1922, age: 69, quarter: nil)])
        #expect(p == nil)
    }

    @Test func yearOnlyFirmDateMatchesAtYearGranularity() {
        // No month on the firm date (firmQuarter nil) → year-level match; a
        // single age-bearing candidate still resolves.
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil, firmDeathYear: 1922, firmDeathQuarter: nil,
            candidates: [candidate("q", year: 1922, age: 69, quarter: "Dec")])
        #expect(p?.estimatedBirthYear == 1853)
    }

    @Test func registrationYearSlopWithinOneAccepted() {
        // A death on 31 Dec can register in the following quarter/year — the ±1
        // year slop lets a firm 1922 match a 1923-registered entry.
        let p = DeathAgeBirthYear.proposal(
            existingBirthYear: nil, firmDeathYear: 1922, firmDeathQuarter: "Mar",
            candidates: [candidate("slop", year: 1923, age: 69, quarter: "Mar")])
        #expect(p?.estimatedBirthYear == 1854)     // 1923 − 69
    }
}
