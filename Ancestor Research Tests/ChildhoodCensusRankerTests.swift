import Testing
import Foundation
@testable import Ancestor_Research

/// CENSUS_PARENT_UNLOCK_SPEC Change 1 — the childhood-census disambiguation that
/// promotes a frontier ancestor's parental-home census without a family match.
struct ChildhoodCensusRankerTests {

    private typealias C = ChildhoodCensusRanker.Candidate

    // George Keyworth, b.1838 Farnsfield, Nottinghamshire — the proven target.
    // His census leads as research surfaces them: two same-county namesakes,
    // two out-of-county namesakes, and his own adult households.
    private let george: [C] = [
        C(id: "halam",     censusYear: 1851, impliedBirthYear: 1835, place: "Halam, Nottinghamshire"),
        C(id: "carrington", censusYear: 1851, impliedBirthYear: 1842, place: "Carrington, Nottinghamshire"),
        C(id: "hamptonwick", censusYear: 1851, impliedBirthYear: 1839, place: "Hampton Wick, Middlesex"),
        C(id: "caistor",   censusYear: 1861, impliedBirthYear: 1835, place: "Caistor, Lincolnshire"),
        C(id: "own1881",   censusYear: 1881, impliedBirthYear: 1838, place: "Farnsfield, Nottinghamshire (NTT)"),
        C(id: "own1901",   censusYear: 1901, impliedBirthYear: 1838, place: "Farnsfield, Nottinghamshire"),
    ]

    @Test func picksTheCountyMatchingChildhoodCensus() {
        let best = ChildhoodCensusRanker.best(
            subjectBirthYear: 1838, subjectCounty: "Farnsfield, Nottinghamshire (NTT)",
            candidates: george)
        #expect(best?.id == "halam")   // 1851 Halam, Notts, b.1835 — the parental home
    }

    @Test func sameCountyBeatsCloserAgeOutOfCounty() {
        // Hampton Wick (Middlesex) implies b.1839 — a *closer* age fit than Halam's
        // b.1835 — but county match must dominate age fit.
        let ranked = ChildhoodCensusRanker.rank(
            subjectBirthYear: 1838, subjectCounty: "Nottinghamshire", candidates: george)
        let halam = ranked.firstIndex { $0.candidate.id == "halam" }!
        let hampton = ranked.firstIndex { $0.candidate.id == "hamptonwick" }!
        #expect(halam < hampton)
    }

    @Test func withinCountyCloserAgeWins() {
        // Halam (b.1835, 3y off) vs Carrington (b.1842, 4y off) — both Notts, so
        // the closer age fit breaks the tie.
        let ranked = ChildhoodCensusRanker.rank(
            subjectBirthYear: 1838, subjectCounty: "Nottinghamshire", candidates: george)
        let halam = ranked.firstIndex { $0.candidate.id == "halam" }!
        let carrington = ranked.firstIndex { $0.candidate.id == "carrington" }!
        #expect(halam < carrington)
    }

    @Test func excludesAdultOwnHouseholdCensuses() {
        // 1861 (age 23), 1881 (43), 1901 (63) are all past the childhood window —
        // they're his own household, never his parents'.
        let ranked = ChildhoodCensusRanker.rank(
            subjectBirthYear: 1838, subjectCounty: "Nottinghamshire", candidates: george)
        #expect(ranked.allSatisfy { $0.candidate.censusYear - 1838 <= 18 })
        #expect(!ranked.contains { $0.candidate.id == "caistor" })
        #expect(!ranked.contains { $0.candidate.id == "own1881" })
        #expect(!ranked.contains { $0.candidate.id == "own1901" })
    }

    @Test func keepsTheBirthYearCensusEdge() {
        // Age exactly 0 (born in a census year) is still childhood.
        let bornOnCensus = [C(id: "x", censusYear: 1851, impliedBirthYear: 1851, place: "Halam, Notts")]
        let ranked = ChildhoodCensusRanker.rank(
            subjectBirthYear: 1851, subjectCounty: "Notts", candidates: bornOnCensus)
        #expect(ranked.count == 1)
    }

    @Test func keepsTheEighteenYearEdge() {
        let atEdge = [C(id: "x", censusYear: 1869, impliedBirthYear: 1851, place: "Halam, Notts")]
        #expect(ChildhoodCensusRanker.rank(
            subjectBirthYear: 1851, subjectCounty: "Notts", candidates: atEdge).count == 1)
    }

    @Test func returnsNilWhenNoChildhoodCandidate() {
        // Only adult censuses → nothing to promote.
        let adultOnly = [C(id: "own1881", censusYear: 1881, impliedBirthYear: 1838,
                           place: "Farnsfield, Nottinghamshire")]
        #expect(ChildhoodCensusRanker.best(
            subjectBirthYear: 1838, subjectCounty: "Nottinghamshire", candidates: adultOnly) == nil)
    }

    @Test func rankableWithUnknownSubjectCounty() {
        // No birthplace county recorded → fall back to age fit alone; still ranks.
        let ranked = ChildhoodCensusRanker.rank(
            subjectBirthYear: 1838, subjectCounty: nil, candidates: george)
        // Best by age among childhood candidates is Hampton Wick (b.1839, 1y off).
        #expect(ranked.first?.candidate.id == "hamptonwick")
    }

    @Test func normalizeCountyStripsChapmanCodeAndVillage() {
        #expect(ChildhoodCensusRanker.normalizeCounty("Halam, Nottinghamshire") == "nottinghamshire")
        #expect(ChildhoodCensusRanker.normalizeCounty("Farnsfield, Nottinghamshire (NTT)") == "nottinghamshire")
        #expect(ChildhoodCensusRanker.normalizeCounty(nil) == nil)
    }
}
