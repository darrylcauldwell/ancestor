import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Lead review POLICY — grouping, add actions, and placeholder attachment.
///
/// The store-wide gathering these policies once fed (`campaignLeads`) retired
/// with the Triage tab (SC-9); `ProfileLeadsBlock` now loads per-profile and
/// the Workbench Attention router preserves the store-wide guarantee. The
/// policies below are surface-independent and survive unchanged.
@MainActor
struct CampaignLeadVisibilityTests {

    // MARK: - Grouping: two people are not one finding

    private func relLead(
        _ id: String, given: String, year: Int, relationship: String,
        surname: String = "Land", profileID: String = "@P1@"
    ) -> Lead {
        Lead(id: id, profileID: profileID, name: "\(given) \(surname)",
             surname: surname, givenName: given, birthYear: year, deathYear: nil,
             relationship: relationship, source: .householdMember, status: .new,
             evidence: "1901 census", createdAt: Date())
    }

    /// THE SECOND BUG. Both children of George Land, both surnamed Land, from
    /// the same census. The old key was
    /// `rel|<profile>|<relationship>|<surname>`, which is identical for both —
    /// so Triage showed ONE row badged "2 records" and Lilian was invisible
    /// inside it. Siblings share a surname by definition; only a parent role is
    /// one-per-surname.
    @Test func twoChildrenOfTheSameParentGroupSeparately() {
        let lilian = relLead("l1", given: "Lilian A", year: 1893, relationship: "child")
        let georgeW = relLead("l2", given: "George W", year: 1898, relationship: "child")

        #expect(CampaignReviewService.leadGroupKey(lilian)
                != CampaignReviewService.leadGroupKey(georgeW),
                "two different children must be two different review rows")
    }

    @Test func siblingLeadsAlsoGroupSeparately() {
        let a = relLead("s1", given: "Ada", year: 1880, relationship: "sibling")
        let b = relLead("s2", given: "Bert", year: 1884, relationship: "sibling")
        #expect(CampaignReviewService.leadGroupKey(a)
                != CampaignReviewService.leadGroupKey(b))
    }

    /// The behaviour the role branch exists FOR must survive: a mother is one
    /// per surname, so two mother-inference leads with the same surname are one
    /// finding arriving twice.
    @Test func twoMotherLeadsWithTheSameSurnameStillCollapse() {
        let a = relLead("m1", given: "Hannah", year: 1850, relationship: "mother",
                        surname: "Pidcock")
        let b = relLead("m2", given: "Hanah", year: 1852, relationship: "mother",
                        surname: "Pidcock")
        #expect(CampaignReviewService.leadGroupKey(a)
                == CampaignReviewService.leadGroupKey(b),
                "one mother per surname — differing given/year is transcription variance")
    }

    @Test func aMotherAndAFatherNeverCollapseTogether() {
        let m = relLead("m1", given: "Hannah", year: 1850, relationship: "mother")
        let f = relLead("f1", given: "Joseph", year: 1848, relationship: "father")
        #expect(CampaignReviewService.leadGroupKey(m)
                != CampaignReviewService.leadGroupKey(f))
    }

    /// Same identity from several records still collapses — the case the
    /// "3 records" badge was built for.
    @Test func oneIdentityFromSeveralRecordsStillCollapses() {
        let a = relLead("r1", given: "Ida L", year: 1885, relationship: "child")
        let b = relLead("r2", given: "Ida L", year: 1885, relationship: "child")
        #expect(CampaignReviewService.leadGroupKey(a)
                == CampaignReviewService.leadGroupKey(b))
    }

    /// Children of DIFFERENT parents never share a row, even same name and year.
    @Test func sameNamedChildrenOfDifferentParentsStaySeparate() {
        let a = relLead("c1", given: "Mary", year: 1888, relationship: "child",
                        profileID: "@P1@")
        let b = relLead("c2", given: "Mary", year: 1888, relationship: "child",
                        profileID: "@P2@")
        #expect(CampaignReviewService.leadGroupKey(a)
                != CampaignReviewService.leadGroupKey(b))
    }

    // MARK: - Which leads may be added to the tree

    /// A lead built from a scored record carries NO relationship — it is one
    /// index row out of a namesake-dense set. Adding it blind is what the
    /// removed Promote button did, and it must stay unavailable.
    @Test func aBareRecordCandidateOffersNoAddAction() {
        let candidate = Lead(
            id: "r1", profileID: "@P1@", name: "George H LAND",
            surname: "LAND", givenName: "George H", birthYear: 1866, deathYear: nil,
            relationship: nil, source: .scoredLead, status: .new,
            evidence: "George H LAND, Dec 1866, Rotherham", createdAt: Date())
        #expect(CampaignReviewService.addAction(for: candidate) == nil,
                "no kin claim — Research first, never add blind")
    }

    @Test func anEmptyRelationshipIsNotAKinClaim() {
        let lead = relLead("x", given: "A", year: 1900, relationship: "")
        #expect(CampaignReviewService.addAction(for: lead) == nil)
    }

    /// THE CASE. A census household member named as a child gets an add action.
    @Test func aChildLeadOffersAddAsChild() {
        let lilian = relLead("l1", given: "Lilian A", year: 1893, relationship: "child")
        #expect(CampaignReviewService.addAction(for: lilian) == .child)
        #expect(CampaignReviewService.addAction(for: lilian)?.label == "Add as child")
    }

    @Test func parentAndSpouseLeadsKeepTheirOwnActions() {
        let mother = relLead("m", given: "Hannah", year: 1850, relationship: "mother")
        let spouse = relLead("s", given: "Annie", year: 1862, relationship: "spouse")
        #expect(CampaignReviewService.addAction(for: mother) == .parent(role: "mother"))
        #expect(CampaignReviewService.addAction(for: mother)?.label == "Add as mother")
        #expect(CampaignReviewService.addAction(for: spouse) == .spouse)
    }

    /// #37 — a sibling lead has no edge of its own, so WITHOUT known parents
    /// it still offers no add action (the row explains why instead). WITH the
    /// generator's parents known, the sibling claim resolves through them:
    /// "Add as child of X & Y", carrying the parent ids for the edges.
    @Test func aSiblingLeadOffersNoAddActionUntilParentsAreKnown() {
        let sibling = relLead("s1", given: "Ada", year: 1880, relationship: "sibling")
        #expect(CampaignReviewService.addAction(for: sibling) == nil)
        #expect(CampaignReviewService.isSiblingLead(sibling))

        let action = CampaignReviewService.addAction(
            for: sibling,
            generatorParents: [("F1", "Joseph Wheeldon"), ("M1", "Alice Wheeldon")]
        )
        #expect(action == .childOfParents(
            parentIDs: ["F1", "M1"],
            parentNames: ["Joseph Wheeldon", "Alice Wheeldon"]))
        #expect(action?.label == "Add as child of Joseph Wheeldon & Alice Wheeldon")

        // One known parent is still enough — James/Samuel promoted via
        // Joseph alone before Alice existed.
        let single = CampaignReviewService.addAction(
            for: sibling, generatorParents: [("F1", "Joseph Wheeldon")])
        #expect(single?.label == "Add as child of Joseph Wheeldon")
    }

    /// Every action offered must produce a real edge — otherwise "Add" creates
    /// an orphan. Pins the two rules to each other. (`childOfParents` builds
    /// its edges from the carried parent ids, not via `relationshipEdge` —
    /// excluded here and covered by `aSiblingLeadOffersNoAddActionUntilParentsAreKnown`.)
    @Test func everyOfferedActionHasAMatchingEdge() {
        for role in ["mother", "father", "child", "spouse", "sibling", "cousin", ""] {
            let lead = relLead("x", given: "A", year: 1900, relationship: role)
            let offered = CampaignReviewService.addAction(for: lead) != nil
            let edge = ProjectDatabase.relationshipEdge(
                fromLead: lead, ghostID: "ghost", generatorID: "@P1@") != nil
            #expect(offered == false || edge,
                    "an add action was offered for a role with no edge — would orphan the node")
        }
    }

    // MARK: - A promoted lead must not be absorbed by a nameless placeholder

    private func placeholder(_ id: String, surname: String = "Gould") -> Profile {
        Profile(id: id, firstName: nil, lastName: surname, gender: nil,
                birthDate: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse,
                     role: nil, subtype: .unknown,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent,
                     role: .unspecified, subtype: .biological,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// THE DAMAGE. Promoting the newly-found daughter "Evelyn E Gould" matched
    /// her mother's surname-only SPOUSE placeholder " Gould" — asymmetric, so
    /// `ProposalDedup` classed it a weak surname match and, with no strong
    /// match present, let it win. No profile was created and the husband was
    /// recorded as his own wife's child.
    @Test func aChildLeadNeverAttachesToTheGeneratorsSpousePlaceholder() {
        let husband = placeholder("husband")
        let daughter = relLead("d1", given: "Evelyn E", year: 1923,
                               relationship: "child", surname: "Gould")
        #expect(CampaignReviewService.mayAttach(
            lead: daughter, to: husband,
            relationships: [spouseEdge("husband", "@P1@")]) == false,
            "a spouse is not a child — this must create a new profile")
    }

    /// Nor to an unrelated same-surname placeholder. Sharing a surname is not
    /// identity; "when in doubt, split".
    @Test func aChildLeadNeverAttachesToAnUnrelatedNamelessPlaceholder() {
        #expect(CampaignReviewService.mayAttach(
            lead: relLead("d1", given: "Evelyn E", year: 1923,
                          relationship: "child", surname: "Gould"),
            to: placeholder("stranger"), relationships: []) == false)
    }

    /// The behaviour the weak match exists FOR must survive: enriching a
    /// surname-only placeholder that is already in the claimed role. Promoting
    /// a named mother lead onto the existing surname-only mother attaches.
    @Test func aParentLeadStillEnrichesItsOwnPlaceholder() {
        let mother = placeholder("mother", surname: "Pidcock")
        let lead = relLead("m1", given: "Hannah", year: 1850,
                           relationship: "mother", surname: "Pidcock")
        #expect(CampaignReviewService.mayAttach(
            lead: lead, to: mother,
            relationships: [parentEdge("mother", "@P1@")]) == true,
            "already the generator's parent — this is the placeholder to enrich")
    }

    /// A child lead DOES attach to a nameless child already linked to the
    /// generator — same role, so it is enrichment rather than a new person.
    @Test func aChildLeadEnrichesAnExistingNamelessChild() {
        #expect(CampaignReviewService.mayAttach(
            lead: relLead("d1", given: "Evelyn E", year: 1923,
                          relationship: "child", surname: "Gould"),
            to: placeholder("child"),
            relationships: [parentEdge("@P1@", "child")]) == true)
    }

    /// A candidate that carries a given name matched ON that name — strong, and
    /// genuinely the same person. Unaffected by any of this.
    @Test func aNamedCandidateIsAlwaysAttachable() {
        let named = Profile(id: "n", firstName: "Evelyn", lastName: "Gould",
                            gender: .female, birthDate: GenealogicalDate(parsing: "1923"),
                            isDeleted: false, sources: [:], disputes: [:])
        #expect(CampaignReviewService.mayAttach(
            lead: relLead("d1", given: "Evelyn E", year: 1923,
                          relationship: "child", surname: "Gould"),
            to: named, relationships: []) == true)
    }

    /// A role with no edge at all can never attach to a nameless candidate,
    /// since there is no edge to match against.
    @Test func aRoleWithNoEdgeBuilderNeverAttaches() {
        #expect(CampaignReviewService.mayAttach(
            lead: relLead("s1", given: "Ada", year: 1880,
                          relationship: "sibling", surname: "Gould"),
            to: placeholder("x"), relationships: []) == false)
    }

    @Test func parentRoleRecognisesOnlyMotherAndFather() {
        #expect(CampaignReviewService.parentRole(
            relLead("x", given: "A", year: 1, relationship: "mother")) == "mother")
        #expect(CampaignReviewService.parentRole(
            relLead("x", given: "A", year: 1, relationship: "Father")) == "father")
        for role in ["child", "sibling", "spouse", "unknown", ""] {
            #expect(CampaignReviewService.parentRole(
                relLead("x", given: "A", year: 1, relationship: role)) == nil)
        }
    }
}
