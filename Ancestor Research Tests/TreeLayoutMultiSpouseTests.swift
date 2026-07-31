import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// TreeLayout must place a person's multiple spouses (remarriage / widowhood)
/// in SEPARATE columns, not stacked on one coordinate. Anchored to David Rose,
/// who married Margaret, then Jean after Margaret died — the two spouse cards
/// rendered on top of each other because every spouse got the same x.
@MainActor
struct TreeLayoutMultiSpouseTests {

    private func profile(_ id: String, _ given: String, _ surname: String, _ birthYear: Int) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, lastName: surname,
            gender: .unknown, attributes: nil,
            birthDate: GenealogicalDate(parsing: String(birthYear)),
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseRel(_ a: String, _ b: String, marriage: String? = nil) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: marriage.map { GenealogicalDate(parsing: $0) },
                     marriageLocation: nil, divorceDate: nil)
    }

    /// Under the marriage switcher, a person with two marriages shows only ONE
    /// spouse at a time — the earliest marriage by default — never both stacked.
    @Test func showsOnlyEarliestMarriageByDefault() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret Helen", "Marshall", 1951)
        let jean = profile("jean", "Jean", "", 1935)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret, jean.id: jean],
            // Margaret married 1972 (first), Jean 1990 (after Margaret died).
            relationships: [spouseRel("david", "margaret", marriage: "1972"),
                            spouseRel("david", "jean", marriage: "1990")])

        let result = TreeLayout.pedigreeLayout(rootID: "david", snapshot: snapshot)
        #expect(result.nodes.contains { $0.id == "margaret" }, "earliest marriage shows by default")
        #expect(!result.nodes.contains { $0.id == "jean" }, "the later marriage is hidden until selected")
    }

    /// Selecting the second marriage swaps which spouse is shown.
    @Test func activeSpouseSelectionSwapsShownSpouse() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret Helen", "Marshall", 1951)
        let jean = profile("jean", "Jean", "", 1935)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret, jean.id: jean],
            relationships: [spouseRel("david", "margaret", marriage: "1972"),
                            spouseRel("david", "jean", marriage: "1990")])

        let result = TreeLayout.pedigreeLayout(
            rootID: "david", snapshot: snapshot, activeSpouse: ["david": "jean"])
        #expect(result.nodes.contains { $0.id == "jean" }, "selected marriage shows")
        #expect(!result.nodes.contains { $0.id == "margaret" }, "the other marriage is hidden")
    }

    /// Only the SHOWN marriage's children count toward "▼ N children".
    @Test func displayedChildrenFollowTheActiveMarriage() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret", "Marshall", 1951)
        let jean = profile("jean", "Jean", "Smith", 1948)
        let claire = profile("claire", "Claire", "Rose", 1978)   // David + Margaret
        let sam = profile("sam", "Sam", "Rose", 1992)            // David + Jean
        func parent(_ p: String, _ c: String) -> Relationship {
            Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret, jean.id: jean, claire.id: claire, sam.id: sam],
            relationships: [
                spouseRel("david", "margaret", marriage: "1972"),
                spouseRel("david", "jean", marriage: "1990"),
                parent("david", "claire"), parent("margaret", "claire"),
                parent("david", "sam"), parent("jean", "sam"),
            ])

        // Default (Margaret) → Claire only.
        let m = snapshot.displayedChildren(of: "david", activeSpouse: [:]).map(\.id)
        #expect(m == ["claire"])
        // Switch to Jean → Sam only.
        let j = snapshot.displayedChildren(of: "david", activeSpouse: ["david": "jean"]).map(\.id)
        #expect(j == ["sam"])
    }

    /// Stage 2 chip geometry — the shared source of truth for drawing AND
    /// hit-testing the on-canvas marriage-switch pills.
    @Test func spouseChipGeometry() {
        #expect(TreeLayout.spouseChipCentres(nodeX: 0, nodeY: 0, count: 1).isEmpty,
                "no chips for a single marriage")
        let two = TreeLayout.spouseChipCentres(nodeX: 100, nodeY: 200, count: 2)
        #expect(two.count == 2)
        #expect(two[0].x != two[1].x, "chips must not overlap")
        #expect(two[0].y == two[1].y, "chips share a row")
        // Row centred between the person and the shown spouse.
        let expectedMid = 100 + (TreeLayout.nodeWidth + TreeLayout.spouseSpacing) / 2
        #expect(abs((two[0].x + two[1].x) / 2 - expectedMid) < 0.001)
    }

    /// The George Keyworth specimen (owner dogfood 2026-07-30): rooting the
    /// pedigree on a CHILD of the second marriage places both parents
    /// (George + Alice) side by side — then the spouse pass computed George's
    /// displayed spouse as the EARLIEST marriage (Elizabeth Brewer, not the
    /// co-parent Alice) and dropped her card exactly on Alice's slot. The
    /// spouse pass must place a card only in a free slot (left side, or
    /// pushed clear) — never stacked on an existing card.
    @Test func nonCoParentSpouseNeverStacksOnTheCoParent() {
        let elizabeth = profile("elizabeth", "Elizabeth", "Keyworth", 1886)
        let george = profile("george", "George", "Keyworth", 1838)
        let alice = profile("alice", "Alice", "Keyworth", 1850)
        let brewer = profile("brewer", "Elizabeth", "Brewer", 1840)
        func parent(_ p: String, _ c: String) -> Relationship {
            Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: [elizabeth.id: elizabeth, george.id: george,
                       alice.id: alice, brewer.id: brewer],
            relationships: [
                spouseRel("george", "brewer", marriage: "1860"),   // earliest → displayed by default
                spouseRel("george", "alice", marriage: "1885"),
                parent("george", "elizabeth"), parent("alice", "elizabeth"),
            ])

        let result = TreeLayout.pedigreeLayout(rootID: "elizabeth", snapshot: snapshot)
        // All four people render (both parents + the displayed other wife)…
        for id in ["elizabeth", "george", "alice", "brewer"] {
            #expect(result.nodes.contains { $0.id == id }, "\(id) should render")
        }
        // …and no two cards may overlap (the defect drew Brewer on Alice).
        let nodes = result.nodes
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let a = nodes[i], b = nodes[j]
                let clear = abs(a.x - b.x) >= TreeLayout.nodeWidth
                    || abs(a.y - b.y) >= TreeLayout.nodeHeight
                #expect(clear, "\(a.id) and \(b.id) overlap at (\(a.x),\(a.y)) vs (\(b.x),\(b.y))")
            }
        }
    }

    /// Owner dogfood 2026-07-31, second round: switching George to marriage
    /// ② (Alice — the root's MOTHER, already placed as the co-parent card)
    /// made the wife "vanish": the spouse pass skipped her as visited and
    /// drew no connector. The displayed marriage must always be visible —
    /// as an edge to the existing card, never a duplicate card.
    @Test func switchingToTheCoParentMarriageDrawsTheConnectorNotACard() {
        let elizabeth = profile("elizabeth", "Elizabeth", "Keyworth", 1886)
        let george = profile("george", "George", "Keyworth", 1838)
        let alice = profile("alice", "Alice", "", 1850)
        let brewer = profile("brewer", "Elizabeth", "Brewer", 1843)
        func parent(_ p: String, _ c: String) -> Relationship {
            Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: [elizabeth.id: elizabeth, george.id: george,
                       alice.id: alice, brewer.id: brewer],
            relationships: [
                spouseRel("george", "brewer", marriage: "1873"),
                spouseRel("george", "alice"),           // undated → chip ②
                parent("george", "elizabeth"), parent("alice", "elizabeth"),
            ])

        let result = TreeLayout.pedigreeLayout(
            rootID: "elizabeth", snapshot: snapshot, activeSpouse: ["george": "alice"])
        // Alice renders exactly once (her co-parent card), Brewer not at all.
        #expect(result.nodes.filter { $0.id == "alice" }.count == 1)
        #expect(!result.nodes.contains { $0.id == "brewer" })
        // The selected marriage is VISIBLE: a spouse edge joins the couple.
        let marriage = result.edges.first {
            $0.type == .spouse && Set([$0.fromID, $0.toID]) == ["george", "alice"]
        }
        #expect(marriage != nil, "switching to the co-parent marriage must draw its connector")
        // And exactly one — the reciprocal iteration must not duplicate it.
        #expect(result.edges.filter {
            $0.type == .spouse && Set([$0.fromID, $0.toID]) == ["george", "alice"]
        }.count == 1)
    }

    /// Owner dogfood 2026-07-31 (two rounds): the renderer trims a spouse
    /// edge to the inter-card gap ASSUMING centre coordinates with `from` as
    /// the left card. A left-placed spouse broke the ordering (line across
    /// both faces); layout-side trimming then double-trimmed (backward spans
    /// + floating dashes). Contract: layout emits CENTRES, left partner
    /// first; the renderer's trim must land inside the gap.
    @Test func spouseEdgesEmitOrderedCentresSoTheRendererTrimLandsInTheGap() {
        // Right-placed spouse (the ordinary case)…
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret", "Marshall", 1951)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret],
            relationships: [spouseRel("david", "margaret")])
        let result = TreeLayout.pedigreeLayout(rootID: "david", snapshot: snapshot)
        let nodes = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        let edge = result.edges.first { $0.type == .spouse }!
        #expect(edge.fromX <= edge.toX, "left partner first")
        #expect(edge.fromX == nodes[edge.fromID]!.x, "edges carry card CENTRES — the renderer owns trimming")
        #expect(edge.toX == nodes[edge.toID]!.x)
        // The renderer's trim (±nodeWidth/2) must land inside the gap.
        let rendered = (edge.fromX + TreeLayout.nodeWidth / 2, edge.toX - TreeLayout.nodeWidth / 2)
        #expect(rendered.0 <= rendered.1 + 0.001, "trimmed segment must never run backwards")
    }

    /// A LEFT-placed spouse (the collision-fix slot) must still emit the
    /// left partner first — this exact shape drew the line across both card
    /// faces in live use.
    @Test func leftPlacedSpouseEdgeIsStillOrderedLeftFirst() {
        let elizabeth = profile("elizabeth", "Elizabeth", "Keyworth", 1886)
        let george = profile("george", "George", "Keyworth", 1838)
        let alice = profile("alice", "Alice", "", 1850)
        let brewer = profile("brewer", "Elizabeth", "Brewer", 1843)
        func parent(_ p: String, _ c: String) -> Relationship {
            Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: [elizabeth.id: elizabeth, george.id: george,
                       alice.id: alice, brewer.id: brewer],
            relationships: [
                spouseRel("george", "brewer", marriage: "1873"),
                spouseRel("george", "alice"),
                parent("george", "elizabeth"), parent("alice", "elizabeth"),
            ])
        let result = TreeLayout.pedigreeLayout(rootID: "elizabeth", snapshot: snapshot)
        let brewerNode = result.nodes.first { $0.id == "brewer" }!
        let georgeNode = result.nodes.first { $0.id == "george" }!
        #expect(brewerNode.x < georgeNode.x, "precondition: Brewer took the left slot")
        let edge = result.edges.first {
            $0.type == .spouse && Set([$0.fromID, $0.toID]) == ["george", "brewer"]
        }!
        #expect(edge.fromID == "brewer" && edge.fromX <= edge.toX,
                "the left partner must come first or the renderer draws backwards across both cards")
    }

    /// Single-marriage co-parent couples keep their long-standing
    /// connector-free look — drawing a connector for EVERY couple flooded
    /// the tree with pink lines (owner-reported 2026-07-31). Only
    /// multi-marriage people get the disambiguating connector.
    @Test func singleMarriageCoParentsDrawNoConnector() {
        let child = profile("child", "Reginald", "Holmes", 1916)
        let father = profile("father", "William", "Holmes", 1880)
        let mother = profile("mother", "Mary Ellen", "Thompson", 1885)
        func parent(_ p: String, _ c: String) -> Relationship {
            Relationship(id: UUID(), from: p, to: c, type: .parent, role: nil,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        let snapshot = FamilyGraphSnapshot(
            profiles: [child.id: child, father.id: father, mother.id: mother],
            relationships: [spouseRel("father", "mother"),
                            parent("father", "child"), parent("mother", "child")])
        let result = TreeLayout.pedigreeLayout(rootID: "child", snapshot: snapshot)
        #expect(!result.edges.contains { $0.type == .spouse },
                "a single-marriage co-parent couple draws no marriage connector")
    }

    /// A single spouse always shows (no switcher, no regression).
    @Test func singleSpouseAlwaysShown() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret Helen", "Marshall", 1951)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret],
            relationships: [spouseRel("david", "margaret")])

        let result = TreeLayout.pedigreeLayout(rootID: "david", snapshot: snapshot)
        let david0 = result.nodes.first { $0.id == "david" }!
        let m = result.nodes.first { $0.id == "margaret" }
        #expect(m != nil)
        #expect(m!.x > david0.x, "the one spouse still sits to the right")
    }
}
