import Foundation

/// CENSUS_PARENT_UNLOCK_SPEC Change 1 — the disambiguation that cracks the
/// pre-1911 parent deadlock.
///
/// A frontier ancestor's *childhood* census (them as a child in the parental
/// home) is what names their parents — but it arrives as a low-confidence lead
/// drowned among namesakes, and the scorer can't promote it because it has no
/// parents/siblings to family-match against (chicken-and-egg). This ranks the
/// candidates **without a family match**, era-appropriately: childhood-window
/// only, then county of the census place vs the subject's birthplace, then age
/// fit. Pure — no I/O; the caller feeds it the subject's census leads.
///
/// Proven target: George Keyworth (b.1838 Farnsfield, Notts) → picks his
/// **1851 Halam** census (Notts, age-fitting) over the Caistor/Carrington/
/// Middlesex namesakes and his own adult 1881/1901 households.
nonisolated enum ChildhoodCensusRanker {

    /// A census record found for the subject, reduced to what ranking needs.
    struct Candidate: Equatable, Sendable {
        let id: String              // lead / record id
        let censusYear: Int
        /// Birth year the census implies (from the stated age). nil if unknown.
        let impliedBirthYear: Int?
        /// Census-stated place (residence or birthplace) — used for county match.
        let place: String?
        /// The census's stated BIRTH county specifically (never the enumeration
        /// place), when known. Used to DISQUALIFY a namesake whose birthplace
        /// county contradicts the subject's — a person born in Leicestershire is
        /// not one born in Derbyshire. Defaulted so existing callers/tests keep
        /// compiling. (owner report 2026-08-05, George Herbert Brooks.)
        var birthCounty: String? = nil
    }

    struct Ranked: Equatable, Sendable {
        let candidate: Candidate
        let score: Double
        let ageGap: Int?
    }

    /// A census where the subject would be older than this is their *own*
    /// household (spouse/children), not their parents' — excluded.
    static let childhoodMaxAge = 18

    /// Childhood-window filter + no-family-match ranking, best first. Adult-era
    /// censuses (subject older than `childhoodMaxAge`) are dropped.
    static func rank(subjectBirthYear: Int, subjectCounty: String?,
                     candidates: [Candidate]) -> [Ranked] {
        let subjCounty = normalizeCounty(subjectCounty)
        let ranked = candidates.compactMap { c -> Ranked? in
            let age = c.censusYear - subjectBirthYear
            guard age >= 0, age <= childhoodMaxAge else { return nil }  // childhood only

            // DISQUALIFY a birthplace-contradicting namesake. When the census's
            // stated BIRTH county is known AND the subject's birth county is known
            // (the caller resolves a bare district like "Belper" → "Derbyshire")
            // AND they differ, this is a different person — never their parents'
            // home. A hard exclusion, not a penalty: without it the ranker fell
            // back to age-alone and grafted the wrong parents (owner report
            // 2026-08-05: George b.Belper/Derbyshire got a born-Coleorton/
            // Leicestershire census). Fires ONLY when both counties are known, so
            // an unresolvable subject county still ranks on age as before.
            if let sc = subjCounty, !sc.isEmpty,
               let cbc = normalizeCounty(c.birthCounty), !cbc.isEmpty, sc != cbc {
                return nil
            }

            var score = 0.0
            // County match is the strongest signal available without a family
            // match: the household stayed in the birthplace's county.
            if let sc = subjCounty, !sc.isEmpty, let cc = normalizeCounty(c.place), !cc.isEmpty {
                score += (cc == sc) ? 100 : -50
            }
            // Age fit — a closer implied birth year is more likely the same person.
            let gap = c.impliedBirthYear.map { abs($0 - subjectBirthYear) }
            if let g = gap { score += Double(max(0, 10 - g)) }

            return Ranked(candidate: c, score: score, ageGap: gap)
        }
        return ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let ga = a.ageGap ?? Int.max, gb = b.ageGap ?? Int.max
            if ga != gb { return ga < gb }
            return a.candidate.censusYear < b.candidate.censusYear   // earlier = closer to home
        }
    }

    /// The single best childhood-census candidate, or nil if none qualifies.
    static func best(subjectBirthYear: Int, subjectCounty: String?,
                     candidates: [Candidate]) -> Candidate? {
        rank(subjectBirthYear: subjectBirthYear, subjectCounty: subjectCounty,
             candidates: candidates).first?.candidate
    }

    /// Lower-cased county token from a place string — the last comma-part with a
    /// trailing Chapman code stripped. "Halam, Nottinghamshire" → "nottinghamshire";
    /// "Farnsfield, Nottinghamshire (NTT)" → "nottinghamshire". nil for nil input.
    static func normalizeCounty(_ place: String?) -> String? {
        guard let place else { return nil }
        var county = place.split(separator: ",").last.map(String.init) ?? place
        if let paren = county.firstIndex(of: "(") { county = String(county[..<paren]) }
        return county.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
