import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part III, Slice A deferred item — administrative
/// co-occurrence.
///
/// The spec listed this as a scoring signal. Building it showed it must not be
/// one. A family that stayed in one district corroborates *every* ambiguous
/// place in that district, so a boost would discriminate almost nothing while
/// manufacturing high scores — and it compounds: one wrong binding raises the
/// next ambiguous place toward the same wrong district, and the round after
/// that higher still. So it ranks, and only ranks.
@MainActor
struct PlaceInventoryCorroborationTests {

    private func person(
        _ id: String, birthLocation: String? = nil, birthCode: String? = nil,
        birthRD: String? = nil, deathCode: String? = nil, year: String = "1861"
    ) -> Profile {
        Profile(id: id, firstName: id, lastName: "Person", gender: .male,
                birthDate: GenealogicalDate(parsing: year),
                birthLocation: birthLocation, birthLocationCode: birthCode,
                birthRegistrationDistrict: birthRD,
                deathDate: nil, deathLocation: nil, deathLocationCode: deathCode,
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent,
                     role: .father, subtype: .biological,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    // MARK: - Ranking

    /// "Wirksworth, Derbyshire" sits in both Bakewell and Belper. A father
    /// already established in Belper puts Belper first — without claiming the
    /// word became less ambiguous.
    @Test func aCorroboratedDistrictIsRankedFirst() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("father", birthRD: "DBY:Belper-RD"),
        ]
        let rows = PlaceInventory.build(profiles: profiles,
                                        relationships: [parentEdge("father", "child")])
        guard let row = rows.first(where: { $0.text == "Wirksworth, Derbyshire" }) else {
            Issue.record("row missing"); return
        }
        #expect(row.candidates.count > 1, "precondition: this place must be ambiguous")
        #expect(row.candidates.first?.id == "DBY:Belper-RD",
                "corroborated district must sort first — got \(row.candidates.map(\.id))")
        #expect(row.corroboration["DBY:Belper-RD"] == 1)
    }

    @Test func corroborationIsStatedInWords() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("father", birthRD: "DBY:Belper-RD"),
        ]
        let rows = PlaceInventory.build(profiles: profiles,
                                        relationships: [parentEdge("father", "child")])
        let reasons = rows.first { $0.text == "Wirksworth, Derbyshire" }?.reasons ?? []
        #expect(reasons.contains { $0.contains("already has records in") && $0.contains("Belper") },
                "\(reasons)")
        #expect(reasons.contains { $0.contains("does not decide") },
                "the reason must say what corroboration is NOT: \(reasons)")
    }

    // MARK: - The property that matters

    /// The anti-cascade guard. Corroboration must never move the score, or a
    /// wrong binding compounds into confident wrong answers.
    @Test func corroborationNeverChangesConfidence() {
        let alone = PlaceInventory.build(profiles: [
            person("child", birthLocation: "Wirksworth, Derbyshire")
        ])
        let corroborated = PlaceInventory.build(
            profiles: [
                person("child", birthLocation: "Wirksworth, Derbyshire"),
                person("father", birthRD: "DBY:Belper-RD"),
                person("gran", birthRD: "DBY:Belper-RD"),
            ],
            relationships: [parentEdge("father", "child"), parentEdge("gran", "father")])

        let before = alone.first { $0.text == "Wirksworth, Derbyshire" }?.confidence
        let after = corroborated.first { $0.text == "Wirksworth, Derbyshire" }?.confidence
        #expect(before == after,
                "family history must not make an ambiguous word less ambiguous — \(before?.label ?? "nil") → \(after?.label ?? "nil")")
    }

    /// Corroboration only ever names districts that are actually on offer. A
    /// count for an eliminated or unrelated district would be noise the user
    /// cannot act on.
    @Test func corroborationOnlyCoversCandidatesOnOffer() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("father", birthRD: "STS:Leek-RD"),
        ]
        let rows = PlaceInventory.build(profiles: profiles,
                                        relationships: [parentEdge("father", "child")])
        let row = rows.first { $0.text == "Wirksworth, Derbyshire" }
        #expect(row?.corroboration.isEmpty == true,
                "a Staffordshire district is not a candidate here: \(row?.corroboration ?? [:])")
    }

    /// Only STRUCTURED fields corroborate. Vouching for an unresolved string
    /// with another unresolved string is circular.
    @Test func freeTextDoesNotCorroborate() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("father", birthLocation: "Belper, Derbyshire"),   // text only, no code
        ]
        let rows = PlaceInventory.build(profiles: profiles,
                                        relationships: [parentEdge("father", "child")])
        #expect(rows.first { $0.text == "Wirksworth, Derbyshire" }?.corroboration.isEmpty == true)
    }

    /// One hop plus siblings. A transitive walk would make a county-bound tree
    /// one blob in which every district corroborates everything.
    @Test func corroborationDoesNotTraverseTheWholeTree() {
        // stranger — great-grandparent, three hops from the child
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("father"), person("gran"),
            person("stranger", birthRD: "DBY:Belper-RD"),
        ]
        let rows = PlaceInventory.build(
            profiles: profiles,
            relationships: [parentEdge("father", "child"), parentEdge("gran", "father"),
                            parentEdge("stranger", "gran")])
        #expect(rows.first { $0.text == "Wirksworth, Derbyshire" }?.corroboration.isEmpty == true,
                "three hops away is not this person's family")
    }

    @Test func siblingsCorroborate() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("sibling", birthRD: "DBY:Belper-RD"),
            person("father"),
        ]
        let rows = PlaceInventory.build(
            profiles: profiles,
            relationships: [parentEdge("father", "child"), parentEdge("father", "sibling")])
        #expect(rows.first { $0.text == "Wirksworth, Derbyshire" }?.corroboration["DBY:Belper-RD"] == 1)
    }

    /// A decision must not become evidence for itself. Binding "Wirksworth,
    /// Derbyshire" for one sibling writes a code that would otherwise return as
    /// independent corroboration when the other sibling's identical string is
    /// scored — the same choice echoed, wearing the clothes of a second opinion.
    @Test func aDecisionIsNotEvidenceForItself() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            // Already bound by an earlier pass through the Places tab.
            person("sibling", birthLocation: "Wirksworth, Derbyshire", birthCode: "DBY:Belper-RD"),
            person("father"),
        ]
        let rows = PlaceInventory.build(
            profiles: profiles,
            relationships: [parentEdge("father", "child"), parentEdge("father", "sibling")])
        let row = rows.first { $0.text == "Wirksworth, Derbyshire" }
        #expect(row?.corroboration.isEmpty == true,
                "the same string settled elsewhere is the same decision, not corroboration: \(row?.corroboration ?? [:])")
    }

    /// But a DIFFERENT string in the family still corroborates — that is a real
    /// second data point, and excluding it would gut the signal.
    @Test func aDifferentStringInTheFamilyStillCorroborates() {
        let profiles = [
            person("child", birthLocation: "Wirksworth, Derbyshire"),
            person("sibling", birthLocation: "Belper, Derbyshire", birthCode: "DBY:Belper-RD"),
            person("father"),
        ]
        let rows = PlaceInventory.build(
            profiles: profiles,
            relationships: [parentEdge("father", "child"), parentEdge("father", "sibling")])
        #expect(rows.first { $0.text == "Wirksworth, Derbyshire" }?.corroboration["DBY:Belper-RD"] == 1)
    }

    /// Omitting relationships costs ranking, never correctness — every caller
    /// that has not been updated must still get the same candidates.
    @Test func omittingRelationshipsChangesOnlyOrderNotContent() {
        let profiles = [person("child", birthLocation: "Wirksworth, Derbyshire")]
        let withEdges = PlaceInventory.build(profiles: profiles, relationships: [])
        let without = PlaceInventory.build(profiles: profiles)
        #expect(Set(withEdges.first?.candidates.map(\.id) ?? []) ==
                Set(without.first?.candidates.map(\.id) ?? []))
        #expect(withEdges.first?.confidence == without.first?.confidence)
    }
}
