import Foundation

/// Derives a circa birth year for a person who has a FIRM death date but NO
/// birth year, by matching that death date to one of their own death-index
/// records (FreeBMD/GRO) and reading the recorded age at death. `death − age`
/// is a birth year, precise to ±1 (the registration age is a whole number and
/// the birthday may not have passed), so the caller writes it with the
/// `.calculated` GenealogicalDate qualifier ("CAL 1853").
///
/// This is the death-side twin of `CensusAgeEnrichment` (census age → birth
/// year). Where the census engine keys on an *applied* household roster, this
/// one keys on the profile's firm death date matching a death-index entry's
/// registration **quarter + year** — the firm date is the disambiguator that
/// lets an otherwise-unconfirmed death LEAD contribute its age. A person with
/// a full GEDCOM death date ("19 Nov 1922") but three same-name death-index
/// leads across different quarters resolves to the one whose quarter matches.
///
/// Safety, in order (mirrors `CensusAgeEnrichment`):
///  1. Gap-fill only — fires only when the birth year is empty.
///  2. Requires a precise death year.
///  3. Matches on year (±1 registration slop) AND, when the firm quarter is
///     known, the same GRO quarter — a candidate with no quarter can't confirm
///     against a known firm quarter and is dropped.
///  4. The scorer's already-rejected (`.impossible`) namesakes are excluded by
///     the caller before this point.
///  5. If several matches survive, they must AGREE on the implied birth year
///     within `agreementBand` years; genuine namesakes of different ages force
///     a decline ("when in doubt, split").
///
/// Pure and deterministic — the DB layer supplies the candidate death records
/// and the firm-date-derived quarter, so this is fully unit-testable.
public nonisolated struct DeathAgeBirthYear {

    /// Largest plausible human age at death — guards transcription junk
    /// ("age 0", "age 999") from fabricating a wild birth year. Matches
    /// `IdentityConstraints.plausibleAgeAtDeath`'s intent.
    public static let maxAge = 120

    /// One death-index record already scored against this profile (an
    /// `evidence_records` row, verdict lead or fact). Carries the age column
    /// plus the registration quarter/year/district for firm-date matching.
    public struct Candidate: Sendable, Equatable {
        public let recordID: String
        public let sourceID: String
        public let deathYear: Int?
        public let ageAtDeath: Int?
        /// GRO end-month quarter abbreviation as stored: "Mar"/"Jun"/"Sep"/"Dec".
        public let quarter: String?
        public let district: String?

        public init(recordID: String, sourceID: String, deathYear: Int?,
                    ageAtDeath: Int?, quarter: String?, district: String?) {
            self.recordID = recordID
            self.sourceID = sourceID
            self.deathYear = deathYear
            self.ageAtDeath = ageAtDeath
            self.quarter = quarter
            self.district = district
        }
    }

    /// A calculated birth year plus the death-index entry it came from.
    public struct Proposal: Sendable, Equatable {
        public let estimatedBirthYear: Int
        public let deathYear: Int
        public let ageAtDeath: Int
        public let quarter: String?
        public let district: String?
        public let sourceRecordID: String
        public let sourceID: String

        public init(estimatedBirthYear: Int, deathYear: Int, ageAtDeath: Int,
                    quarter: String?, district: String?, sourceRecordID: String, sourceID: String) {
            self.estimatedBirthYear = estimatedBirthYear
            self.deathYear = deathYear
            self.ageAtDeath = ageAtDeath
            self.quarter = quarter
            self.district = district
            self.sourceRecordID = sourceRecordID
            self.sourceID = sourceID
        }
    }

    /// GRO quarters are labelled by their END month — the reverse of the
    /// pipeline's `expandBMDQuarter`. A death registered Jan–Mar is "Mar",
    /// Oct–Dec is "Dec". nil for an out-of-range month.
    public static func groQuarter(forMonth month: Int) -> String? {
        switch month {
        case 1...3:   return "Mar"
        case 4...6:   return "Jun"
        case 7...9:   return "Sep"
        case 10...12: return "Dec"
        default:      return nil
        }
    }

    /// Propose a calculated birth year, or nil (decline) when the signal is
    /// missing or ambiguous. See the type doc for the full rule ladder.
    ///
    /// - Parameters:
    ///   - existingBirthYear: the profile's current best birth year; must be nil.
    ///   - firmDeathYear: the year of the profile's precise death date.
    ///   - firmDeathQuarter: the GRO quarter derived from the firm death date's
    ///     month, or nil when the firm date is year-only (weaker, year-level match).
    ///   - candidates: the profile's death-index records, `.impossible` already removed.
    ///   - agreementBand: max spread (years) allowed among surviving matches.
    public static func proposal(
        existingBirthYear: Int?,
        firmDeathYear: Int?,
        firmDeathQuarter: String?,
        candidates: [Candidate],
        agreementBand: Int = 2
    ) -> Proposal? {
        guard existingBirthYear == nil, let firmDeathYear else { return nil }

        // (3) Year (±1) match; when the firm quarter is known the candidate must
        // carry a matching quarter — a quarter-less candidate can't be confirmed
        // against a known firm quarter, so it's dropped (namesake protection).
        let matched = candidates.filter { c in
            guard let dy = c.deathYear, abs(dy - firmDeathYear) <= 1 else { return false }
            guard let fq = firmDeathQuarter else { return true } // year-only firm date
            guard let cq = c.quarter?.trimmingCharacters(in: .whitespaces), !cq.isEmpty
            else { return false }
            return cq.caseInsensitiveCompare(fq) == .orderedSame
        }

        // (5) Each match's implied birth year (guarded age). Decline if none, or
        // if the surviving matches disagree beyond the agreement band.
        let implied: [(candidate: Candidate, year: Int)] = matched.compactMap { c in
            guard let dy = c.deathYear, let age = c.ageAtDeath, age > 0, age <= maxAge
            else { return nil }
            return (c, dy - age)
        }
        guard let minYear = implied.map(\.year).min(),
              let maxYear = implied.map(\.year).max(),
              maxYear - minYear <= agreementBand else { return nil }

        // Deterministic pick: the earliest implied year, from the
        // lowest-recordID candidate implying it (the ±1 `.calculated` span the
        // caller writes covers the ≤`agreementBand` spread anyway).
        let best = implied
            .filter { $0.year == minYear }
            .min { $0.candidate.recordID < $1.candidate.recordID }!
        let c = best.candidate
        return Proposal(
            estimatedBirthYear: best.year,
            deathYear: c.deathYear!,
            ageAtDeath: c.ageAtDeath!,
            quarter: c.quarter,
            district: c.district,
            sourceRecordID: c.recordID,
            sourceID: c.sourceID)
    }
}
