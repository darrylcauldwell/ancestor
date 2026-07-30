import Testing
import Foundation
@testable import Ancestor_Research
@testable import AncestorKit

/// MergeEdit payload builder (WT1 — WIKITREE_MERGEEDIT_SPEC §3/§4): the
/// eligibility gates, the differs-AND-research-provenance sendability rule,
/// twin-valued `expected` guards, the maiden-surname manual note, and the
/// research-notes bio block with citation dedup.
struct WikiTreeMergeEditTests {

    private func wikiTreeSource(_ raw: String) -> FieldSource {
        FieldSource(origin: .wikitree, raw: raw, addedAt: Date(timeIntervalSince1970: 100))
    }

    private func researchSource(_ raw: String, citation: Citation? = nil) -> FieldSource {
        FieldSource(origin: .freebmd, raw: raw, addedAt: Date(timeIntervalSince1970: 200),
                    citation: citation)
    }

    private func deceasedProfile(
        wikiTreeID: String? = "Cauldwell-171",
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: "@I1@",
            externalIDs: wikiTreeID.map { ["wikitree": $0] } ?? [:],
            firstName: "Ernest", lastName: "Cauldwell", gender: .male,
            birthDate: GenealogicalDate(parsing: "1887"),
            deathDate: GenealogicalDate(parsing: "1955"),
            isDeleted: false, sources: sources, disputes: [:])
    }

    @Test func noWikiTreeIDMeansNoPayload() {
        let payload = WikiTreeMergeEdit.build(
            profile: deceasedProfile(wikiTreeID: nil), currentYear: 2026, date: "31 Jul 2026")
        #expect(payload == nil)
    }

    @Test func livingProfileNeverBuildsAPayload() {
        var living = deceasedProfile()
        living.deathDate = nil
        living.birthDate = GenealogicalDate(parsing: "1980")
        let payload = WikiTreeMergeEdit.build(profile: living, currentYear: 2026, date: "31 Jul 2026")
        #expect(payload == nil)
    }

    @Test func researchSourcedChangedFieldSendsWithTwinExpected() throws {
        // WikiTree said "abt 1888"; research established "1887" with a citation.
        let profile = deceasedProfile(sources: [
            .birthDate: [wikiTreeSource("abt 1888"),
                         researchSource("1887", citation: Citation(collection: "FreeBMD Birth Index", page: "vol 7b p213"))],
        ])
        let payload = try #require(WikiTreeMergeEdit.build(
            profile: profile, currentYear: 2026, date: "31 Jul 2026"))
        #expect(payload.userName == "Cauldwell-171")
        #expect(payload.personFields["BirthDate"] == "1887")
        #expect(payload.expectedFields["BirthDate"] == "abt 1888")   // the guard value
        #expect(payload.summary.contains("BirthDate"))
    }

    @Test func importOnlyProvenanceNeverRoundTripsBack() {
        // The birth date came FROM WikiTree (import tier only) — sending it
        // back would launder an import into a "contribution".
        let profile = deceasedProfile(sources: [
            .birthDate: [wikiTreeSource("abt 1888")],
        ])
        let payload = WikiTreeMergeEdit.build(profile: profile, currentYear: 2026, date: "31 Jul 2026")
        // birthDate differs from twin raw ("1887" vs "abt 1888") but has no
        // research provenance → not sendable; nothing else sendable → nil.
        #expect(payload == nil)
    }

    @Test func unchangedFieldIsNotSent() {
        let profile = deceasedProfile(sources: [
            .birthDate: [wikiTreeSource("1887"), researchSource("1887")],
        ])
        let payload = WikiTreeMergeEdit.build(profile: profile, currentYear: 2026, date: "31 Jul 2026")
        #expect(payload == nil)   // app == twin → nothing to contribute
    }

    @Test func maidenSurnameDivergenceBecomesAManualNoteNotAField() throws {
        var profile = deceasedProfile(sources: [
            .lastName: [wikiTreeSource("Caldwell"), researchSource("Cauldwell")],
            .deathLocation: [researchSource("Derby")],
        ])
        profile.deathLocation = "Derby"
        let payload = try #require(WikiTreeMergeEdit.build(
            profile: profile, currentYear: 2026, date: "31 Jul 2026"))
        #expect(payload.personFields["LastNameAtBirth"] == nil)
        #expect(payload.personFields["LastNameCurrent"] == nil)   // maiden ≠ married field
        #expect(payload.manualNotes.count == 1)
        #expect(payload.manualNotes[0].contains("Cauldwell") && payload.manualNotes[0].contains("Caldwell"))
    }

    @Test func bioBlockCarriesFieldRefsAndDedupedCitations() throws {
        let birthCitation = Citation(collection: "FreeBMD Birth Index", page: "vol 7b p213",
                                     url: "https://www.freebmd.org.uk/x")
        let parishCitation = Citation(collection: "FreeREG Baptisms", title: "St Mary, Crich",
                                      url: "https://www.freereg.org.uk/y")
        var profile = deceasedProfile(sources: [
            .birthDate: [wikiTreeSource("abt 1888"), researchSource("1887", citation: birthCitation)],
            .birthLocation: [researchSource("Crich, Derbyshire", citation: parishCitation)],
        ])
        profile.birthLocation = "Crich, Derbyshire"
        let payload = try #require(WikiTreeMergeEdit.build(
            profile: profile, currentYear: 2026, date: "31 Jul 2026"))
        let bio = try #require(payload.bioAppend)
        #expect(bio.hasPrefix("=== Research notes (31 Jul 2026, Ancestor Research) ==="))
        #expect(bio.contains("* Birth: 1887<ref>"))
        #expect(bio.contains("FreeBMD Birth Index"))
        #expect(bio.contains("FreeREG Baptisms"))
        // Each citation appears exactly once (field-ref usage consumes it).
        #expect(bio.components(separatedBy: "FreeBMD Birth Index").count == 2)
    }

    @Test func citationsAlreadyInTheBioAreSkipped() throws {
        let cited = Citation(collection: "FreeBMD Birth Index", url: "https://www.freebmd.org.uk/x")
        var profile = deceasedProfile(sources: [
            .deathLocation: [researchSource("Derby", citation: cited)],
        ])
        profile.deathLocation = "Derby"
        profile.bio = "Existing biography citing https://www.freebmd.org.uk/x already."
        let payload = try #require(WikiTreeMergeEdit.build(
            profile: profile, currentYear: 2026, date: "31 Jul 2026"))
        #expect(payload.personFields["DeathLocation"] == "Derby")
        #expect(payload.bioAppend == nil)   // nothing NEW to cite
    }

    @Test func genderMapsToWikiTreeVocabularyOnlyWhenResearchBacked() throws {
        let profile = deceasedProfile(sources: [
            .gender: [researchSource("male")],
        ])
        let payload = try #require(WikiTreeMergeEdit.build(
            profile: profile, currentYear: 2026, date: "31 Jul 2026"))
        #expect(payload.personFields["Gender"] == "Male")
        #expect(payload.expectedFields["Gender"] == "")   // twin never asserted one
    }

    @Test func citationKeyIsRunStable() {
        let citation = Citation(collection: "FreeBMD", page: "7b/213")
        #expect(WikiTreeMergeEdit.citationKey(citation) == WikiTreeMergeEdit.citationKey(citation))
        #expect(WikiTreeMergeEdit.citationKey(citation) != WikiTreeMergeEdit.citationKey(Citation(collection: "FreeCEN")))
    }
}
