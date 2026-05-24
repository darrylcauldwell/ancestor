import Testing
import Foundation
@testable import Ancestor_Research

/// Parity-fix regression tests for `VerdictEmitter.parentLinkVerdict`
/// (parity-report cluster #3, 2026-05-25).
///
/// Background: commit `297a6f3` (2026-05-24) widened the verdict-emitter
/// to walk `result.allScoredRecords` for `.census`-record household
/// tokens — not just the curated `result.householdMembers` — so that
/// Robert's + Ernest's 1891 Belper census records (demoted from `.fact`
/// to `.lead` because of unknown district "Duffield") could still
/// contribute parent-surname tokens. That fix recovered two cells.
///
/// But the widening was sourced too broadly: it scooped in FamilySearch
/// `.census` records too. FamilySearch returns 80–100+ noisy keyword
/// matches per sparse subject (because the FS query is tagged with
/// `father=<surname>`), and even at `.lead` grade those records carry
/// the parent surname as an incidental household token. Catherine
/// Hannah Bown and Stephen Sherwin (corpus axes `sparse_civil_record` /
/// `parish_only_evidence`, both expected `inconclusive`) jumped from
/// `inconclusive` to `supported` purely on FS noise.
///
/// Fix (cluster #3): tier-2 token gathering is restricted to
/// `sourceID == "freecen"` — mirroring Python's
/// `_extract_household_members` which only inspects source keys
/// containing "census" (FreeCen alone in the Python source dict).
/// FamilySearch census records can still contribute via tier-1 if the
/// scorer promotes them to `.fact`, which is implicitly gated by
/// name/geography/family-context — i.e. real matches, not noise.
struct VerdictEmitterParentLinkTests {

    // MARK: - Fixture helpers

    private func makeProfile(
        id: String, firstName: String? = nil, lastName: String?,
        gender: Gender = .male
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: gender,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil,
            isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentEdge(parentID: String, childID: String) -> Relationship {
        Relationship(
            id: UUID(), from: parentID, to: childID, type: .parent,
            role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func makeCommon(
        id: String = UUID().uuidString,
        sourceID: String,
        surname: String? = nil
    ) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: sourceID, name: nil,
            surname: surname, givenName: nil,
            detailURL: nil, rawFields: [:]
        )
    }

    private func makeMember(name: String, relationship: String = "Son") -> HouseholdMember {
        HouseholdMember(
            name: name, relationship: relationship,
            age: nil, birthYear: nil, birthPlace: nil,
            occupation: nil, sex: nil
        )
    }

    private func makeCensus(
        id: String = UUID().uuidString,
        sourceID: String,
        household: [HouseholdMember],
        verdict: RecordVerdict
    ) -> ScoredRecord {
        let census = CensusRecord(
            common: makeCommon(id: id, sourceID: sourceID),
            censusYear: 1891, age: nil, birthYear: nil,
            birthPlace: nil, birthCounty: nil, relationship: nil,
            occupation: nil, address: nil, parish: nil, district: nil,
            household: household
        )
        return ScoredRecord(
            id: id, record: .census(census),
            verdict: verdict, gates: [], summary: ""
        )
    }

    private func makeResult(
        confirmedFacts: [ScoredRecord] = [],
        leads: [ScoredRecord] = [],
        allScoredRecords: [ScoredRecord],
        householdMembers: [HouseholdMember] = []
    ) -> ResearchResult {
        ResearchResult(
            confirmedFacts: confirmedFacts,
            leads: leads,
            allScoredRecords: allScoredRecords,
            clusters: [],
            discrepancies: [],
            householdMembers: householdMembers,
            searchHistory: [],
            hypotheses: []
        )
    }

    private func snapshotWithFather(subjectID: String, fatherSurname: String) -> FamilyGraphSnapshot {
        let subject = makeProfile(id: subjectID, lastName: fatherSurname)
        let father = makeProfile(id: "father-1", lastName: fatherSurname, gender: .male)
        return FamilyGraphSnapshot(
            profiles: [subjectID: subject, "father-1": father],
            relationships: [parentEdge(parentID: "father-1", childID: subjectID)]
        )
    }

    // MARK: - Tier-2 widening (297a6f3) MUST still recover lead-grade FreeCen
    //
    // Robert / Ernest shape: 1891 FreeCen census record demoted to `.lead`
    // (unknown district "Duffield"). Pipeline's `.fact`-only filter excludes
    // it from `result.householdMembers`, but its household payload carries
    // a sibling with the same surname as the father. Tier-2 must scoop
    // that token in to emit `supported`.

    @Test func robertShape_leadGradeFreeCenWithParentSurname_givesSupported() {
        let snapshot = snapshotWithFather(subjectID: "subj-rob", fatherSurname: "Cauldwell")

        let leadCensus = makeCensus(
            sourceID: "freecen",
            household: [
                makeMember(name: "John Cauldwell", relationship: "Brother"),
                makeMember(name: "Sarah Cauldwell", relationship: "Mother"),
            ],
            verdict: .lead   // mirrors Robert's 1891 Belper demotion
        )

        let result = makeResult(
            allScoredRecords: [leadCensus],
            householdMembers: []
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-rob"
            ) == VerdictEmitter.supported
        )
    }

    @Test func ernestShape_leadGradeFreeCenWithParentSurname_givesSupported() {
        let snapshot = snapshotWithFather(subjectID: "subj-ern", fatherSurname: "Cauldwell")

        // Two siblings + a parent — the typical Belper enumeration shape.
        let leadCensus = makeCensus(
            sourceID: "freecen",
            household: [
                makeMember(name: "Mary Cauldwell", relationship: "Sister"),
                makeMember(name: "George Cauldwell", relationship: "Brother"),
                makeMember(name: "James Cauldwell", relationship: "Father"),
            ],
            verdict: .lead
        )

        let result = makeResult(
            allScoredRecords: [leadCensus],
            householdMembers: []
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-ern"
            ) == VerdictEmitter.supported
        )
    }

    // MARK: - Sparsity guard (cluster #3) — FamilySearch noise must NOT promote
    //
    // Catherine / Stephen shape: 0 FreeCen results, but FamilySearch returned
    // 80+ keyword-noise matches per query, many tagged with `father=<surname>`.
    // The FS census records therefore carry the parent surname as an incidental
    // household token — but they're noise, not the subject's real household.
    //
    // Tier-2 must not walk FamilySearch records. Tier-1 (.fact-grade) stays
    // open to FamilySearch as before; nothing reaches tier-1 for these
    // subjects because the scorer never promoted any FS record to `.fact`.

    @Test func catherineShape_onlyFamilySearchLeadCensus_givesInconclusive() {
        let snapshot = snapshotWithFather(subjectID: "subj-cat", fatherSurname: "Bown")

        // The FS records that came back tagged `father=Bown` — easy for a
        // noise hit to carry "Bown" as a member token. Pre-fix this scooped
        // straight through tier-2 and tripped the verdict to supported.
        let fsNoiseLeadCensus = makeCensus(
            sourceID: "familysearch",
            household: [
                makeMember(name: "Philip Bown", relationship: "Father"),
                makeMember(name: "Some Other Bown", relationship: "Brother"),
            ],
            verdict: .lead
        )

        let result = makeResult(
            allScoredRecords: [fsNoiseLeadCensus],
            householdMembers: []
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-cat"
            ) == VerdictEmitter.inconclusive
        )
    }

    @Test func stephenShape_onlyFamilySearchFactCensusInAllScored_butNotInHouseholdMembers_givesInconclusive() {
        // Edge case: even `.fact`-grade FamilySearch census records in
        // `allScoredRecords` must not feed tier-2. The proper path for them
        // is tier-1 via `result.householdMembers`. If the pipeline elected
        // not to surface them there (e.g. user filtered, or the curation
        // step suppressed), tier-2 must not silently rescue them.
        let snapshot = snapshotWithFather(subjectID: "subj-step", fatherSurname: "Sherwin")

        let fsFactCensus = makeCensus(
            sourceID: "familysearch",
            household: [
                makeMember(name: "William Sherwin", relationship: "Father"),
            ],
            verdict: .fact
        )

        let result = makeResult(
            allScoredRecords: [fsFactCensus],
            householdMembers: []   // pipeline curated this OUT — tier-1 sees nothing
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-step"
            ) == VerdictEmitter.inconclusive
        )
    }

    // MARK: - Mabel shape (Python regression; Swift correct)
    //
    // Mabel has 0 FreeCen results but parent_link=`supported` expected
    // (corpus). Her support comes from FamilySearch census records that
    // survived scoring to `.fact` grade and reached `result.householdMembers`
    // via the pipeline's curation step. Tier-1 picks them up regardless of
    // sourceID — that's by design. Restricting tier-2 to FreeCen must NOT
    // break this path.

    @Test func mabelShape_familySearchFactCensusInHouseholdMembers_givesSupported() {
        let snapshot = snapshotWithFather(subjectID: "subj-mab", fatherSurname: "Cauldwell")

        // Tier-1 curated input: a .fact-grade FS census's household member
        // surfaced into result.householdMembers via the pipeline.
        let curatedHousehold = [
            makeMember(name: "James Cauldwell", relationship: "Father"),
            makeMember(name: "Annie Cauldwell", relationship: "Sister"),
        ]

        // The matching .fact record is also in allScoredRecords (because
        // the pipeline appends every scored record there). With the fix
        // it's ignored by tier-2 (FS), but tier-1 already supplied the
        // tokens — so the verdict still resolves supported.
        let factCensus = makeCensus(
            sourceID: "familysearch",
            household: curatedHousehold,
            verdict: .fact
        )

        let result = makeResult(
            confirmedFacts: [factCensus],
            allScoredRecords: [factCensus],
            householdMembers: curatedHousehold
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-mab"
            ) == VerdictEmitter.supported
        )
    }

    // MARK: - Mixed-source: FreeCen lead AND FamilySearch noise both present
    //
    // The discriminating case. Real-world runs see both at once for some
    // subjects. Tier-2 must walk the FreeCen record; the FS record is
    // ignored. If the FreeCen record's household tokens hit a parent
    // surname → supported. If only the FS noise has a hit → inconclusive.

    @Test func mixedSources_freecenHasParentSurname_givesSupported() {
        let snapshot = snapshotWithFather(subjectID: "subj-mix", fatherSurname: "Cauldwell")

        let realFreeCenLead = makeCensus(
            sourceID: "freecen",
            household: [makeMember(name: "Mary Cauldwell", relationship: "Mother")],
            verdict: .lead
        )
        let fsNoise = makeCensus(
            sourceID: "familysearch",
            household: [makeMember(name: "Random Stranger", relationship: "Lodger")],
            verdict: .lead
        )

        let result = makeResult(
            allScoredRecords: [realFreeCenLead, fsNoise]
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-mix"
            ) == VerdictEmitter.supported
        )
    }

    @Test func mixedSources_onlyFamilySearchNoiseHasParentSurname_givesInconclusive() {
        let snapshot = snapshotWithFather(subjectID: "subj-mix2", fatherSurname: "Cauldwell")

        let unrelatedFreeCen = makeCensus(
            sourceID: "freecen",
            household: [makeMember(name: "Random Stranger", relationship: "Visitor")],
            verdict: .lead
        )
        let fsNoiseWithParentSurname = makeCensus(
            sourceID: "familysearch",
            household: [makeMember(name: "James Cauldwell", relationship: "Father")],
            verdict: .lead
        )

        let result = makeResult(
            allScoredRecords: [unrelatedFreeCen, fsNoiseWithParentSurname]
        )

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj-mix2"
            ) == VerdictEmitter.inconclusive
        )
    }

    // MARK: - Boundary checks (preserved from pre-297a6f3 contract)

    @Test func noSubjectID_givesInconclusive() {
        let snapshot = snapshotWithFather(subjectID: "subj", fatherSurname: "Cauldwell")
        let census = makeCensus(
            sourceID: "freecen",
            household: [makeMember(name: "John Cauldwell")],
            verdict: .lead
        )
        let result = makeResult(allScoredRecords: [census])
        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: nil
            ) == VerdictEmitter.inconclusive
        )
    }

    @Test func noParentsInSnapshot_givesInconclusive() {
        let subject = makeProfile(id: "lone", lastName: "Cauldwell")
        let snapshot = FamilyGraphSnapshot(profiles: ["lone": subject], relationships: [])

        let census = makeCensus(
            sourceID: "freecen",
            household: [makeMember(name: "John Cauldwell")],
            verdict: .lead
        )
        let result = makeResult(allScoredRecords: [census])

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "lone"
            ) == VerdictEmitter.inconclusive
        )
    }

    @Test func noHouseholdAnywhere_givesInconclusive() {
        let snapshot = snapshotWithFather(subjectID: "subj", fatherSurname: "Cauldwell")
        let result = makeResult(allScoredRecords: [])

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj"
            ) == VerdictEmitter.inconclusive
        )
    }

    @Test func freeCenHouseholdWithoutParentSurname_givesInconclusive() {
        let snapshot = snapshotWithFather(subjectID: "subj", fatherSurname: "Cauldwell")
        let census = makeCensus(
            sourceID: "freecen",
            household: [
                makeMember(name: "Random Stranger", relationship: "Visitor"),
                makeMember(name: "Some Lodger", relationship: "Lodger"),
            ],
            verdict: .lead
        )
        let result = makeResult(allScoredRecords: [census])

        #expect(
            VerdictEmitter.parentLinkVerdict(
                result: result, snapshot: snapshot, subjectProfileID: "subj"
            ) == VerdictEmitter.inconclusive
        )
    }
}
