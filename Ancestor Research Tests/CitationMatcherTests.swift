import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the CitationMatcher contract used by the §5.8 eval harness
/// (RESEARCH_PIPELINE_SPEC.md §5.8.5). Mirrors the Python reference
/// implementation at `eval/extract_gedcom_citations.py`.
struct CitationMatcherTests {

    // MARK: - parse() — prose → CitedIdentifier

    @Test func parseFreeBMDBirthWithVolumeAndPage() {
        let prose = "* FreeBMD birth Dec 1887 Belper vol7b p559 (mother Barker)"
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 1)
        let c = cites[0]
        #expect(c.source == .freebmd)
        #expect(c.kind == .birthRegistration)
        #expect(c.identifiers["quarter"] == "Dec")
        #expect(c.identifiers["year"] == "1887")
        #expect(c.identifiers["district"] == "Belper")
        #expect(c.identifiers["volume"] == "7b")
        #expect(c.identifiers["page"] == "559")
    }

    @Test func parseFreeBMDBirthWithoutVolumeOrPage() {
        // Robert's bio-note style — district only, no vol/page
        let prose = "* FreeBMD birth Sep 1885 Belper"
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 1)
        let c = cites[0]
        #expect(c.source == .freebmd)
        #expect(c.kind == .birthRegistration)
        #expect(c.identifiers["district"] == "Belper")
        #expect(c.identifiers["volume"] == nil)
        #expect(c.identifiers["page"] == nil)
    }

    @Test func parseFreeBMDDeathWithAge() {
        let prose = "* FreeBMD death Mar 1959 Ashbourne vol3a p14, age 71"
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 1)
        #expect(cites[0].kind == .deathRegistration)
        #expect(cites[0].identifiers["volume"] == "3a")
    }

    @Test func parseGROMarriageInferKindFromContext() {
        let prose = "He married '''Mary Ward''' of Kirk Ireton in March 1915 (Ashbourne, GRO vol7b p977)."
        let cites = CitationMatcher.parse(prose: prose)
        let gro = cites.first { $0.source == .gro }
        #expect(gro != nil)
        #expect(gro?.kind == .marriageRegistration)
        #expect(gro?.identifiers["volume"] == "7b")
        #expect(gro?.identifiers["page"] == "977")
    }

    @Test func parseFamilySearchCensusARK() {
        let prose = "* FamilySearch 1911 census: Ernest Cauldwell, waggoner, Hulland Ward Intakes (ARK 1G2B-WFR)"
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 1)
        let c = cites[0]
        #expect(c.source == .familysearch)
        #expect(c.kind == .census)
        #expect(c.identifiers["year"] == "1911")
        #expect(c.identifiers["ark"] == "1G2B-WFR")
    }

    @Test func parseCWGCWithPlot() {
        let prose = "* CWGC: Corporal Robert Cauldwell, 1st Bn West Yorkshire Regt, died 14 Jul 1918, Lijssenthoek Military Cemetery XXVIII.G.3A"
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 1)
        let c = cites[0]
        #expect(c.source == .cwgc)
        #expect(c.kind == .warGrave)
        #expect(c.identifiers["plot"] == "XXVIII.G.3A")
        #expect(c.identifiers["date_of_death"] == "14 Jul 1918")
    }

    @Test func parseMultiplePatternsInSameBio() {
        // Approximates Ernest's full bio — 5 expected citations
        let prose = """
        He married '''Mary Ward''' of Kirk Ireton in March 1915 (Ashbourne, GRO vol7b p977).
        * FreeBMD birth Dec 1887 Belper vol7b p559 (mother Barker)
        * FreeBMD death Mar 1959 Ashbourne vol3a p14, age 71
        * FamilySearch 1901 census: Ernest Cauldwell, son, b.1888 Turnditch (ARK p_10268848273)
        * FamilySearch 1911 census: Ernest Cauldwell, waggoner, Hulland Ward Intakes (ARK 1G2B-WFR)
        """
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.count == 5)
        // Sanity check the source mix matches expectations
        let freebmdCount = cites.filter { $0.source == .freebmd }.count
        let groCount = cites.filter { $0.source == .gro }.count
        let fsCount = cites.filter { $0.source == .familysearch }.count
        #expect(freebmdCount == 2)
        #expect(groCount == 1)
        #expect(fsCount == 2)
    }

    @Test func parseReturnsEmptyForUnstructuredProse() {
        let prose = "John was a farmer in Alderwasley. He had several children."
        let cites = CitationMatcher.parse(prose: prose)
        #expect(cites.isEmpty)
    }

    // MARK: - equivalent() — match rules

    @Test func freeBMDExactMatchOnAllIdentifiers() {
        let a = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper", "volume": "7b", "page": "559"],
            raw: nil
        )
        let b = a
        #expect(CitationMatcher.equivalent(a, b) == .exact)
    }

    @Test func freeBMDPartialMatchWhenOneSideLacksVolumeAndPage() {
        // The Robert-birth case — bio note has no vol/page but the
        // engine's discovered citation does.
        let bioNote = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Sep", "year": "1885", "district": "Belper"],
            raw: nil
        )
        let engineFound = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Sep", "year": "1885", "district": "Belper", "volume": "7b", "page": "571"],
            raw: nil
        )
        #expect(CitationMatcher.equivalent(bioNote, engineFound) == .partial)
        // Symmetric
        #expect(CitationMatcher.equivalent(engineFound, bioNote) == .partial)
    }

    @Test func freeBMDNoMatchOnDifferentVolumeAndPage() {
        let a = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper", "volume": "7b", "page": "559"],
            raw: nil
        )
        let b = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper", "volume": "7b", "page": "631"],
            raw: nil
        )
        #expect(CitationMatcher.equivalent(a, b) == .noMatch)
    }

    @Test func freeBMDAndGROTreatedAsSameFamily() {
        // The Ernest-marriage case — bio uses "GRO vol7b p977" but the
        // engine emits "FreeBMD marriage Mar 1915 Ashbourne vol7b p977"
        let gro = CitedIdentifier(
            source: .gro, kind: .marriageRegistration,
            identifiers: ["volume": "7b", "page": "977"],
            raw: nil
        )
        let freebmd = CitedIdentifier(
            source: .freebmd, kind: .marriageRegistration,
            identifiers: ["quarter": "Mar", "year": "1915", "district": "Ashbourne", "volume": "7b", "page": "977"],
            raw: nil
        )
        // GRO has only vol+page (no district/quarter/year) — primary-key
        // alignment fails, so this is noMatch by the current rule.
        // This is the right call: vol+page alone isn't enough because
        // the same vol+page exists in different districts across years.
        #expect(CitationMatcher.equivalent(gro, freebmd) == .noMatch)
    }

    @Test func familySearchExactMatchOnArk() {
        let a = CitedIdentifier(
            source: .familysearch, kind: .census,
            identifiers: ["year": "1911", "ark": "1G2B-WFR"], raw: nil
        )
        let b = a
        #expect(CitationMatcher.equivalent(a, b) == .exact)
    }

    @Test func familySearchNoMatchOnDifferentArk() {
        let a = CitedIdentifier(
            source: .familysearch, kind: .census,
            identifiers: ["year": "1911", "ark": "1G2B-WFR"], raw: nil
        )
        let b = CitedIdentifier(
            source: .familysearch, kind: .census,
            identifiers: ["year": "1911", "ark": "1G2B-35Q"], raw: nil
        )
        #expect(CitationMatcher.equivalent(a, b) == .noMatch)
    }

    @Test func cwgcExactMatchOnPlot() {
        let a = CitedIdentifier(
            source: .cwgc, kind: .warGrave,
            identifiers: ["plot": "XXVIII.G.3A", "date_of_death": "14 Jul 1918"],
            raw: nil
        )
        let b = a
        #expect(CitationMatcher.equivalent(a, b) == .exact)
    }

    @Test func crossSourceNoMatch() {
        let a = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper"],
            raw: nil
        )
        let b = CitedIdentifier(
            source: .familysearch, kind: .census,
            identifiers: ["year": "1901"], raw: nil
        )
        #expect(CitationMatcher.equivalent(a, b) == .noMatch)
    }

    @Test func differentKindsAreNoMatch() {
        let birth = CitedIdentifier(
            source: .freebmd, kind: .birthRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper", "volume": "7b", "page": "559"],
            raw: nil
        )
        let death = CitedIdentifier(
            source: .freebmd, kind: .deathRegistration,
            identifiers: ["quarter": "Dec", "year": "1887", "district": "Belper", "volume": "7b", "page": "559"],
            raw: nil
        )
        // Same identifiers but different kind — must NOT match
        #expect(CitationMatcher.equivalent(birth, death) == .noMatch)
    }
}
