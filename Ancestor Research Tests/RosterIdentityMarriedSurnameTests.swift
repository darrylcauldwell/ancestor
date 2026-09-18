import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// EV23 (owner dogfood 2026-08-26) — a married woman was invisible to census
/// enrichment.
///
/// The tree stores a woman under her MAIDEN surname (WikiTree convention) and
/// every census indexes her under her MARRIED one. `CensusAgeEnrichment`
/// compared a roster row's surname against `profile.lastName` ALONE, while
/// `CensusRelationshipReconciler`, reading the SAME household, compared it
/// against `lastName` AND `marriedSurname` — and `ConflictSweep.knownSurnames`
/// (app target) against `lastName`, `marriedSurname` and the `nameForms`
/// sidecar. Three answers to one question, and the strictest one silently
/// dropped every married woman: Hannah HEWKIN (`marriedSurname` "Gladwin") is
/// "Hannah Gladwin" on every roster she appears on, so no birth-year proposal,
/// no corroboration and no "Cite census" offer could ever form for her,
/// anywhere in the app.
///
/// These fixtures are modelled on the live 1861 Low Green household (William
/// GLADWIN head, Hannah his wife, their daughter) but carry synthetic ages and
/// ids.
///
/// The bottom half of this file pins the SHARED-BEHAVIOUR property: the
/// enrichment matcher and the reconciler matcher must return the same verdict
/// for the same (roster row, profile) pair, so they cannot drift apart again.
nonisolated struct RosterIdentityMarriedSurnameTests {

    // MARK: - Fixtures

    private func person(
        _ id: String, first: String, last: String?,
        married: String? = nil, birthYear: Int? = nil,
        forms: [NameForm] = []
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, marriedSurname: married,
            nameForms: forms, gender: nil, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func member(_ name: String, _ role: String, age: Int? = nil,
                        isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: role, age: age, isTarget: isTarget)
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// Hannah as the tree holds her: maiden `lastName`, married surname beside it.
    private func hannah(birthYear: Int? = nil) -> Profile {
        person("hannah", first: "Hannah", last: "Hewkin", married: "Gladwin", birthYear: birthYear)
    }

    // MARK: - EV23: the three required cases

    /// lastName "Hewkin" + marriedSurname "Gladwin", roster row "Hannah
    /// Gladwin" → MATCH. The defect case: before the fix the surname was
    /// compared against "HEWKIN" only and the row was dropped.
    @Test func marriedSurnameRowMatchesMaidenStoredProfile() {
        #expect(CensusAgeEnrichment.nameMatches("Hannah GLADWIN", hannah()))
    }

    /// The maiden form still works — this is a UNION, not a swap. A roster that
    /// happens to index her under her birth surname must not start failing.
    @Test func maidenSurnameRowStillMatches() {
        #expect(CensusAgeEnrichment.nameMatches("Hannah HEWKIN", hannah()))
    }

    /// lastName "Hewkin", NO married surname recorded → "Hannah Gladwin" is a
    /// different woman. The fix must not degrade into "any surname matches":
    /// over-merging is what this guard exists to prevent, and it is the one
    /// mistake the user cannot undo.
    @Test func marriedSurnameRowRefusedWhenProfileHasNoMarriedSurname() {
        let maidenOnly = person("hannah-maiden", first: "Hannah", last: "Hewkin")
        #expect(!CensusAgeEnrichment.nameMatches("Hannah GLADWIN", maidenOnly))
        #expect(CensusAgeEnrichment.nameMatches("Hannah HEWKIN", maidenOnly))
    }

    // MARK: - EV23: the affordance can now form end-to-end

    /// The whole point of the fix: a birth-year proposal for Hannah off her own
    /// household. Subject is her daughter Emma (the roster's target row); Hannah
    /// is a LINKED parent with an empty birth year, listed as "Hannah Gladwin"
    /// on the Wife row. 1861 − 38 → circa 1823.
    @Test func enrichmentProposesBirthYearForMarriedWomanOnRoster() {
        let household = [
            member("William GLADWIN", "Head", age: 40),
            member("Hannah GLADWIN", "Wife", age: 38),
            member("Emma GLADWIN", "Daur", age: 4, isTarget: true),
        ]
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "emma", household: household, censusYear: 1861,
            linkedRelatives: [hannah()], sourceID: "src-1861",
            relations: ["hannah": .parent])

        #expect(proposals.count == 1)
        #expect(proposals.first?.targetProfileID == "hannah")
        #expect(proposals.first?.estimatedBirthYear == 1823)
        #expect(proposals.first?.relationshipLabel == "Wife")
    }

    /// The same household against a maiden-only profile proposes NOTHING —
    /// the end-to-end mirror of the refusal above.
    @Test func enrichmentProposesNothingForAMaidenOnlyNamesake() {
        let household = [
            member("Hannah GLADWIN", "Wife", age: 38),
            member("Emma GLADWIN", "Daur", age: 4, isTarget: true),
        ]
        let maidenOnly = person("hannah-maiden", first: "Hannah", last: "Hewkin")
        let proposals = CensusAgeEnrichment.proposals(
            subjectID: "emma", household: household, censusYear: 1861,
            linkedRelatives: [maidenOnly], sourceID: "src-1861",
            relations: ["hannah-maiden": .parent])
        #expect(proposals.isEmpty)
    }

    // MARK: - The canonical surname union

    /// `RosterIdentity.knownSurnames` is the one definition, and it is the same
    /// union `ConflictSweep.knownSurnames` uses: both flat search keys plus the
    /// `nameForms` sidecar (where a WikiTree `LastNameOther` lands).
    @Test func knownSurnamesUnionsFlatKeysAndTheNameFormSidecar() {
        let profile = person(
            "p", first: "Hannah", last: "Hewkin", married: "Gladwin",
            forms: [NameForm(type: .alsoKnownAs, fullText: "Hannah Hewkins", surname: "Hewkins")])
        #expect(RosterIdentity.knownSurnames(of: profile) == ["HEWKIN", "GLADWIN", "HEWKINS"])
    }

    /// A profile with no surname at all is an ABSENCE, not a mismatch — the
    /// distinction the enrichment matcher's stub tolerance depends on.
    @Test func surnameAgreementDistinguishesAbsenceFromConflict() {
        let stub = person("stub", first: "Hannah", last: nil)
        #expect(RosterIdentity.surnameAgreement(memberName: "Hannah GLADWIN", profile: stub)
                == .profileSurnamesAbsent)
        #expect(RosterIdentity.surnameAgreement(memberName: "Hannah", profile: hannah())
                == .rosterSurnameAbsent)
        #expect(RosterIdentity.surnameAgreement(memberName: "Hannah GLADWIN", profile: hannah())
                == .agrees)
        #expect(RosterIdentity.surnameAgreement(memberName: "Hannah WHEELDON", profile: hannah())
                == .conflicts)
    }

    // MARK: - Shared behaviour: the two matchers must not diverge again

    /// One table, both matchers. Every row uses a given name that BOTH accept
    /// by exact equality, so the only variable is the surname — which is the
    /// axis that drifted. (The given-name halves are deliberately different and
    /// stay different: the reconciler runs forenames through the 0.85
    /// name-similarity ladder so a census "Sam" recognises the tree's "Samuel",
    /// while enrichment matches given names exactly. That difference is
    /// documented on each function; the SURNAME answer must be identical.)
    @Test func enrichmentAndReconcilerAgreeOnEverySurnameCase() {
        struct Row {
            let label: String
            let profile: Profile
            let memberName: String
            let shouldMatch: Bool
        }
        let sidecarOnly = person(
            "sidecar", first: "Hannah", last: "Hewkin",
            forms: [NameForm(type: .married, fullText: "Hannah Gladwin", surname: "Gladwin")])

        let rows = [
            Row(label: "married surname on the roster, maiden on the tree",
                profile: hannah(), memberName: "Hannah GLADWIN", shouldMatch: true),
            Row(label: "maiden surname on the roster",
                profile: hannah(), memberName: "Hannah HEWKIN", shouldMatch: true),
            Row(label: "a third surname is a different family",
                profile: hannah(), memberName: "Hannah WHEELDON", shouldMatch: false),
            Row(label: "no married surname recorded → married-surname row refused",
                profile: person("maiden", first: "Hannah", last: "Hewkin"),
                memberName: "Hannah GLADWIN", shouldMatch: false),
            Row(label: "no married surname recorded → maiden row still matches",
                profile: person("maiden", first: "Hannah", last: "Hewkin"),
                memberName: "Hannah HEWKIN", shouldMatch: true),
            Row(label: "maiden and married identical",
                profile: person("same", first: "Hannah", last: "Gladwin", married: "Gladwin"),
                memberName: "Hannah GLADWIN", shouldMatch: true),
            Row(label: "middle name on the roster row",
                profile: hannah(), memberName: "Hannah Maria GLADWIN", shouldMatch: true),
            Row(label: "different forename, same surname",
                profile: hannah(), memberName: "Sarah GLADWIN", shouldMatch: false),
            Row(label: "married surname carried only by the nameForms sidecar",
                profile: sidecarOnly, memberName: "Hannah GLADWIN", shouldMatch: true),
        ]

        for row in rows {
            let rosterRow = HouseholdMember(name: row.memberName, relationship: "Wife", age: 38)
            let enrichment = CensusAgeEnrichment.nameMatches(row.memberName, row.profile)
            let reconciler = CensusRelationshipReconciler.namesMatch(
                member: rosterRow, profile: row.profile)
            #expect(enrichment == row.shouldMatch, "enrichment: \(row.label)")
            #expect(reconciler == row.shouldMatch, "reconciler: \(row.label)")
            #expect(enrichment == reconciler, "matchers disagree: \(row.label)")
        }
    }

    // MARK: - EV25 characterisation (the gate itself is NOT in these files)

    /// EV25 (2026-08-26) — the scorer's `familyContext` gate reported "no known
    /// family members in household" for a household containing the subject's
    /// own LINKED SPOUSE on the Head row.
    ///
    /// The gate lives in `RecordScorer.checkFamilyContext` (app target), so the
    /// repair is not made here. What IS pinned here is the premise the repair
    /// rests on: AncestorKit already classifies that roster correctly. When the
    /// subject is the WIFE, the Head row IS her spouse — a fact
    /// `CensusFamilyLinker` has always known and the gate re-derived by hand,
    /// wrongly, with `relationship.contains("wife") || contains("husband")`.
    /// A husband on his own schedule is never labelled "Husband"; he is "Head".
    ///
    /// REPAIRED 2026-08-26: `checkFamilyContext` now routes through
    /// `CensusFamilyLinker.category` (made public for exactly this) and scores
    /// the spouse under every surname she is known by. The gate-side tests live
    /// in `FamilyContextGateSpouseTests`; this stays as the premise.
    @Test func linkedSpouseOnTheHeadRowIsACensusFamilyRelation() {
        let household = [
            member("William GLADWIN", "Head", age: 40),
            member("Hannah GLADWIN", "Wife", age: 38, isTarget: true),
            member("Emma GLADWIN", "Daur", age: 4),
        ]
        let links = CensusFamilyLinker.familyLinks(household: household)
        let spouseLinks = links.filter { $0.relation == .spouse }
        #expect(spouseLinks.count == 1)
        #expect(spouseLinks.first?.member.name == "William GLADWIN")
        // And the abbreviated daughter row — "Daur", which the gate's
        // `contains("daughter")` test also misses — is classified too.
        #expect(links.contains { $0.relation == .child && $0.member.name == "Emma GLADWIN" })
    }

    /// The in-scope regression test for EV25's household: reconciled against
    /// the tree, Hannah's 1861 roster reports her linked husband and linked
    /// daughter as ALREADY IN THE TREE, and raises no `.missing` finding. If
    /// this passes while the scorer still downgrades the same household for
    /// "no known family members", the disagreement is entirely inside
    /// `RecordScorer.checkFamilyContext`.
    @Test func reconcilerSeesTheLinkedSpouseAndChildInHannahsHousehold() {
        let hannahProfile = hannah(birthYear: 1823)
        let william = person("william", first: "William", last: "Gladwin", birthYear: 1821)
        let emma = person("emma", first: "Emma", last: "Gladwin", birthYear: 1857)
        let household = [
            member("William GLADWIN", "Head", age: 40),
            member("Hannah GLADWIN", "Wife", age: 38, isTarget: true),
            member("Emma GLADWIN", "Daur", age: 4),
        ]
        let event = LifeEvent(
            id: UUID(), profileID: "hannah", type: .census,
            date: GenealogicalDate(parsing: "1861"),
            details: .census(CensusDetails(household: household)))
        let snapshot = FamilyGraphSnapshot(
            profiles: ["hannah": hannahProfile, "william": william, "emma": emma],
            relationships: [spouseEdge("hannah", "william"),
                            parentEdge("hannah", "emma"),
                            parentEdge("william", "emma")],
            lifeEvents: ["hannah": [event]])

        let recon = CensusRelationshipReconciler.reconciliations(for: hannahProfile, in: snapshot)
        #expect(recon.count == 1)
        let entries = recon.first?.entries ?? []
        #expect(entries.count == 3)
        // Her own row anchors the census — without that the whole household is
        // discarded and every relative below is invisible.
        #expect(entries.contains { $0.member.name == "Hannah GLADWIN" && $0.status == .subject })
        #expect(entries.contains { $0.member.name == "William GLADWIN"
            && $0.status == .inTree(profileID: "william") })
        #expect(entries.contains { $0.member.name == "Emma GLADWIN"
            && $0.status == .inTree(profileID: "emma") })
        #expect(CensusRelationshipReconciler.findings(for: hannahProfile, in: snapshot).isEmpty)
    }
}
