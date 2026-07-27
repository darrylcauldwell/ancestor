import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The census-relationship reconciliation engine (`CensusRelationshipReconciler`)
/// and its audit rule (`CensusRelationshipRule`). A census records
/// relationship-to-Head; the engine turns a household into the members'
/// relations to the subject (via `CensusFamilyLinker`) and diffs them against
/// the subject's tree relatives → `.missing` / `.contradiction`. The
/// contradiction case is the real one that bit us: the 1861 census showed
/// Samuel and Mary Wheeldon as siblings while the tree recorded Samuel as
/// Mary's father (2026-07-27).
struct CensusRelationshipReconcilerTests {

    // MARK: - Fixtures

    private func person(_ id: String, _ first: String, _ last: String, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, gender: nil,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func member(_ name: String, _ relationship: String, age: Int?, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age, isTarget: isTarget)
    }

    /// A census life-event on `subjectID` carrying `household`.
    private func censusEvent(_ subjectID: String, year: Int, household: [HouseholdMember]) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: subjectID, type: .census,
            date: GenealogicalDate(parsing: String(year)),
            details: .census(CensusDetails(household: household)))
    }

    /// The Wheeldon 1861 household as it sits on Samuel's census: John (Head) +
    /// Ruth (Wife) as his parents, Samuel (Son, the subject) and Mary (Dau) as
    /// children → census makes John/Ruth Samuel's parents and Mary his sibling.
    private func wheeldonHousehold() -> [HouseholdMember] {
        [member("John Wheeldon", "Head", age: 37),
         member("Ruth Wheeldon", "Wife", age: 37),
         member("Samuel Wheeldon", "Son", age: 8, isTarget: true),
         member("Mary Wheeldon", "Daughter", age: 5)]
    }

    // MARK: - Tests

    /// The tree records Samuel as Mary's FATHER while the census makes them
    /// siblings → one `.contradiction` (census sibling vs tree child).
    @Test func detectsParentChildVsCensusSiblingContradiction() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],       // tree: Samuel is Mary's father
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let findings = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
        let contradictions = findings.filter { $0.kind == .contradiction }
        #expect(contradictions.count == 1)
        let c = try! #require(contradictions.first)
        #expect(c.member.name == "Mary Wheeldon")
        #expect(c.censusRelation == .sibling)     // census: Mary is Samuel's sibling
        #expect(c.treeRelation == .child)         // tree: Mary is Samuel's child
        #expect(c.treeRelativeID == "mary")
    }

    /// When the tree already has Samuel and Mary as siblings (shared parent),
    /// the census agrees → NO contradiction.
    @Test func consistentSiblingProducesNoContradiction() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let dad = person("dad", "John", "Wheeldon", birthYear: 1824)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary, "dad": dad],
            relationships: [parentEdge("dad", "samuel"), parentEdge("dad", "mary")],  // siblings
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let contradictions = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
            .filter { $0.kind == .contradiction }
        #expect(contradictions.isEmpty)
    }

    /// A census relative absent from the tree is reported as `.missing`
    /// (John/Ruth here are not in the tree).
    @Test func reportsCensusRelativesMissingFromTree() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let missing = CensusRelationshipReconciler.findings(for: samuel, in: snapshot)
            .filter { $0.kind == .missing }
        // John (Head) and Ruth (Wife) → the subject's parents, neither in the tree.
        #expect(missing.contains { $0.member.name == "John Wheeldon" && $0.censusRelation == .parent })
        #expect(missing.contains { $0.member.name == "Ruth Wheeldon" && $0.censusRelation == .parent })
    }

    /// Non-family co-residents (servant, lodger) and out-of-scope kin
    /// (grandchild) are excluded by `CensusFamilyLinker` → never a finding.
    @Test func excludesNonFamilyAndOutOfScopeRoles() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        var household = wheeldonHousehold()
        household.append(member("Jane Smith", "Servant", age: 20))
        household.append(member("Tom Brown", "Lodger", age: 40))
        household.append(member("Baby Wheeldon", "Grandson", age: 1))
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel],
            relationships: [],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: household)]])

        let names = Set(CensusRelationshipReconciler.findings(for: samuel, in: snapshot).map { $0.member.name })
        #expect(!names.contains("Jane Smith"))
        #expect(!names.contains("Tom Brown"))
        #expect(!names.contains("Baby Wheeldon"))
    }

    /// The audit rule surfaces the contradiction as a single `.warning`.
    @Test func ruleSurfacesContradictionAsWarning() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "mary": mary],
            relationships: [parentEdge("samuel", "mary")],
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: wheeldonHousehold())]])

        let results = CensusRelationshipRule().evaluate(profile: samuel, snapshot: snapshot)
        // A contradiction warning (Mary) plus a missing-summary info (John + Ruth).
        let warning = try! #require(results.first { $0.severity == .warning })
        #expect(warning.ruleID == "censusRelationship")
        #expect(warning.relatedProfileIDs == ["mary"])
        #expect(warning.message.contains("sibling") && warning.message.contains("child"))
        #expect(results.contains { $0.severity == .info && $0.category == .gap && $0.message.contains("not in the tree") })
    }

    /// A household attached to a subject but whose `isTarget` row is SOMEONE
    /// ELSE (a shared household / stale target) must produce NO findings — else
    /// the relations are computed in the wrong reference frame. Here the census
    /// sits on John (the Head, b.1861) but flags his son Ernest as the target;
    /// without the anchor guard this yielded phantom contradictions (Elizabeth
    /// read as John's parent, the sons as his siblings). Live repro 2026-07-27.
    @Test func misAnchoredHouseholdProducesNoFindings() {
        let john = person("john", "John", "Cauldwell", birthYear: 1861)       // the Head
        let eliza = person("eliza", "Elizabeth", "Cauldwell", birthYear: 1861)
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1887)
        let household = [
            member("John Cauldwell", "Head", age: 30),                        // John's own row — NOT flagged
            member("Elizabeth Cauldwell", "Wife", age: 30),
            member("Ernest Cauldwell", "Son", age: 4, isTarget: true)]        // wrong anchor: a son
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john, "eliza": eliza, "ernest": ernest],
            relationships: [spouseEdge("john", "eliza"), parentEdge("john", "ernest")], // correct Head family
            lifeEvents: ["john": [censusEvent("john", year: 1891, household: household)]])

        // isTarget row ("Ernest", age 4 → 1887) does not match John (1861) → skip.
        #expect(CensusRelationshipReconciler.findings(for: john, in: snapshot).isEmpty)
    }

    /// A census sibling and a tree child that merely SHARE A NAME (different
    /// people, decades apart) must NOT be matched — so no phantom contradiction.
    /// Ernest's census sibling George (b.1889) vs Ernest's son George (b.1915).
    /// Live repro 2026-07-27 (name-only matching paired the two Georges).
    @Test func namesakeWithDivergentYearIsNotAContradiction() {
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1886)
        let georgeSon = person("georgeSon", "George", "Cauldwell", birthYear: 1915)  // Ernest's real son
        let household = [
            member("John Cauldwell", "Head", age: 30),
            member("Ernest Cauldwell", "Son", age: 5, isTarget: true),        // b.1886
            member("George Cauldwell", "Son", age: 2)]                        // census sibling, b.1889
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ernest": ernest, "georgeSon": georgeSon],
            relationships: [parentEdge("ernest", "georgeSon")],               // Ernest is George(1915)'s father
            lifeEvents: ["ernest": [censusEvent("ernest", year: 1891, household: household)]])

        let findings = CensusRelationshipReconciler.findings(for: ernest, in: snapshot)
        // The b.1889 census-sibling George must NOT match the b.1915 son George.
        #expect(findings.allSatisfy { $0.kind != .contradiction })
        // It should instead be reported as a missing sibling.
        #expect(findings.contains { $0.kind == .missing && $0.member.name == "George Cauldwell" && $0.censusRelation == .sibling })
    }

    /// The review-facing roster report classifies every row: the subject, a
    /// relative already in the tree, a role conflict, a missing relative, and a
    /// non-family co-resident — the data the audit panel renders.
    @Test func reconciliationClassifiesEveryRosterRow() {
        let samuel = person("samuel", "Samuel", "Wheeldon", birthYear: 1853)
        let john = person("john", "John", "Wheeldon", birthYear: 1824)
        let mary = person("mary", "Mary", "Wheeldon", birthYear: 1856)
        var household = wheeldonHousehold()                       // John, Ruth, Samuel(target), Mary
        household.append(member("Jane Smith", "Servant", age: 20))
        let snapshot = FamilyGraphSnapshot(
            profiles: ["samuel": samuel, "john": john, "mary": mary],
            relationships: [parentEdge("john", "samuel"),         // John is a real parent → in tree
                            parentEdge("samuel", "mary")],        // tree says Samuel fathers Mary → conflict
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: household)]])

        let recons = CensusRelationshipReconciler.reconciliations(for: samuel, in: snapshot)
        let recon = try! #require(recons.first)
        #expect(recon.censusYear == 1861)
        func status(_ name: String) -> CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status? {
            recon.entries.first { $0.member.name == name }?.status
        }
        #expect(status("Samuel Wheeldon") == .subject)
        #expect(status("John Wheeldon") == .inTree(profileID: "john"))
        #expect(status("Ruth Wheeldon") == .missing)
        #expect(status("Mary Wheeldon") == .contradiction(treeRelativeID: "mary", treeRelation: .child))
        #expect(status("Jane Smith") == .outOfScope)
    }

    /// The SAME missing person seen from two household viewpoints must not
    /// double-add. George is a Son the roster cannot date (no age); once he
    /// exists as the head's child, the head's own finding recognises him — same
    /// census, same role, same name — so no duplicate is offered, even though
    /// year corroboration is impossible.
    @Test func undateableMemberAlreadyInRoleIsNotReofferedAsMissing() {
        let john = person("john", "John", "Cauldwell", birthYear: 1861)
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1887)
        let george = person("george", "George", "Cauldwell", birthYear: nil)  // added earlier, undateable
        let household = [
            member("John Cauldwell", "Head", age: 30, isTarget: true),
            member("Ernest Cauldwell", "Son", age: 4),
            member("George Cauldwell", "Son", age: nil)]                        // no age on the roster
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john, "ernest": ernest, "george": george],
            relationships: [parentEdge("john", "ernest"), parentEdge("john", "george")],
            lifeEvents: ["john": [censusEvent("john", year: 1891, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: john, in: snapshot).first)
        let georgeStatus = recon.entries.first { $0.member.name == "George Cauldwell" }?.status
        #expect(georgeStatus == .inTree(profileID: "george"))
        #expect(!CensusRelationshipReconciler.findings(for: john, in: snapshot)
            .contains { $0.member.name == "George Cauldwell" })
    }

    // MARK: - Parent-in-law leads (Martha Barker)

    /// A "Ma-Law" (mother-in-law) row on the HEAD's census pins the head's
    /// spouse's mother — surfaced as an in-law lead against the spouse, not a
    /// dead "not family" row. (John Cauldwell head, Elizabeth wife ⇒ Martha
    /// Barker is Elizabeth's mother; Elizabeth née Barker.)
    @Test func motherInLawOfHeadSurfacesAsSpouseParentLead() {
        let john = person("john", "John", "Cauldwell", birthYear: 1861)
        let eliza = person("eliza", "Elizabeth", "Cauldwell", birthYear: 1862)
        let household = [
            member("John Cauldwell", "Head", age: 30, isTarget: true),
            member("Elizabeth Cauldwell", "Wife", age: 29),
            member("Martha Barker", "Ma-Law", age: 66)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john, "eliza": eliza],
            relationships: [spouseEdge("john", "eliza")],
            lifeEvents: ["john": [censusEvent("john", year: 1891, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: john, in: snapshot).first)
        let martha = try! #require(recon.entries.first { $0.member.name == "Martha Barker" })
        #expect(martha.status == .inLawOfSpouse(spouseID: "eliza", kind: .mother))

        let leads = CensusRelationshipReconciler.inLawLeads(for: john, in: snapshot)
        #expect(leads.count == 1)
        #expect(leads.first?.spouseID == "eliza")
        #expect(leads.first?.kind == .mother)
        #expect(leads.first?.member.name == "Martha Barker")
    }

    /// The same Ma-Law row is meaningless from a SON's viewpoint (the roster's
    /// "-in-law" is relative to the head, not the son) → it stays out of scope,
    /// never mis-attached to the son's own spouse.
    @Test func motherInLawIsNotSurfacedFromNonHeadViewpoint() {
        let ernest = person("ernest", "Ernest", "Cauldwell", birthYear: 1887)
        let wife = person("wife", "Ada", "Cauldwell", birthYear: 1889)
        let household = [
            member("John Cauldwell", "Head", age: 30),
            member("Ernest Cauldwell", "Son", age: 4, isTarget: true),
            member("Ada Cauldwell", "Daughter-in-Law", age: 2),
            member("Martha Barker", "Ma-Law", age: 66)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ernest": ernest, "wife": wife],
            relationships: [spouseEdge("ernest", "wife")],
            lifeEvents: ["ernest": [censusEvent("ernest", year: 1891, household: household)]])

        #expect(CensusRelationshipReconciler.inLawLeads(for: ernest, in: snapshot).isEmpty)
        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: ernest, in: snapshot).first)
        #expect(recon.entries.first { $0.member.name == "Martha Barker" }?.status == .outOfScope)
    }

    /// Once the in-law is actually in the tree (the spouse now has a
    /// name-matching parent), the row must read "in tree" and drop off the
    /// leads — not keep offering an add that would duplicate her. (Martha Barker
    /// added as Elizabeth's mother ⇒ no longer a gap.)
    @Test func inLawAlreadyInTreeIsNotReoffered() {
        let john = person("john", "John", "Cauldwell", birthYear: 1861)
        let eliza = person("eliza", "Elizabeth", "Barker", birthYear: 1862)   // now née Barker
        let martha = person("martha", "Martha", "Barker", birthYear: 1825)    // added as her mother
        let household = [
            member("John Cauldwell", "Head", age: 30, isTarget: true),
            member("Elizabeth Cauldwell", "Wife", age: 29),
            member("Martha Barker", "Ma-Law", age: 66)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john, "eliza": eliza, "martha": martha],
            relationships: [spouseEdge("john", "eliza"), parentEdge("martha", "eliza")],
            lifeEvents: ["john": [censusEvent("john", year: 1891, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: john, in: snapshot).first)
        #expect(recon.entries.first { $0.member.name == "Martha Barker" }?.status == .inTree(profileID: "martha"))
        #expect(CensusRelationshipReconciler.inLawLeads(for: john, in: snapshot).isEmpty)
    }

    /// `parentInLawKind` reads spelled-out and abbreviated forms, and excludes
    /// child/sibling in-laws.
    @Test func parentInLawKindParsesFormsAndExcludesOthers() {
        #expect(CensusRelationshipReconciler.parentInLawKind("Ma-Law") == .mother)
        #expect(CensusRelationshipReconciler.parentInLawKind("Mother-in-Law") == .mother)
        #expect(CensusRelationshipReconciler.parentInLawKind("Mother in law") == .mother)
        #expect(CensusRelationshipReconciler.parentInLawKind("Fa-Law") == .father)
        #expect(CensusRelationshipReconciler.parentInLawKind("Father-in-Law") == .father)
        #expect(CensusRelationshipReconciler.parentInLawKind("Son-in-Law") == nil)
        #expect(CensusRelationshipReconciler.parentInLawKind("Daughter-in-Law") == nil)
        #expect(CensusRelationshipReconciler.parentInLawKind("Brother-in-Law") == nil)
        #expect(CensusRelationshipReconciler.parentInLawKind("Head") == nil)
        #expect(CensusRelationshipReconciler.parentInLawKind("Wife") == nil)
    }

    // MARK: - One-click "Add from census" (the mutating write, Stage 2b)

    /// End-to-end for `AppState.addMissingCensusRelatives`: a subject whose census
    /// lists a sibling absent from the tree → the sibling is created fresh and
    /// wired through the subject's existing parent (never a direct sibling edge),
    /// and the already-present father is NOT duplicated (only the missing links
    /// are fed to `addCensusFamily`).
    @MainActor
    @Test func addMissingCensusRelativesCreatesAndWiresSibling() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("samuel", "Samuel", "Wheeldon", birthYear: 1853), source: .gedcom)
        _ = try db.addProfile(person("john", "John", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addRelationship(parentEdge("john", "samuel"))

        let base = try db.buildSnapshot()
        let household = [
            member("John Wheeldon", "Head", age: 37),
            member("Samuel Wheeldon", "Son", age: 8, isTarget: true),
            member("Mary Wheeldon", "Daughter", age: 5)]        // census sibling, missing from tree
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["samuel": [censusEvent("samuel", year: 1861, household: household)]])

        appState.addMissingCensusRelatives(for: "samuel")

        let snap = appState.snapshot
        let mary = try #require(snap.profiles.values.first { $0.firstName == "Mary" }, "Mary was created")
        #expect(snap.childrenOf("john").contains { $0.id == mary.id }, "wired through the subject's parent John")
        #expect(snap.siblingsOf("samuel").contains { $0.id == mary.id }, "now surfaces as Samuel's sibling")
        // Fed only the missing link → the existing father John is not re-created.
        #expect(snap.profiles.values.filter { $0.firstName == "John" }.count == 1)
    }

    /// The Martha payoff end-to-end: a mother-in-law census row creates the
    /// in-law, links her as the spouse's mother, dates her from her census age,
    /// and fills the spouse's maiden name (moving the married surname across).
    @MainActor
    @Test func addSpouseParentFromInLawCreatesMotherAndSetsMaidenName() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("john", "John", "Cauldwell", birthYear: 1861), source: .gedcom)
        // Elizabeth stored under her MARRIED surname — the common GEDCOM state.
        _ = try db.addProfile(person("eliza", "Elizabeth", "Cauldwell", birthYear: 1862), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("john", "eliza"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.addSpouseParentFromInLaw(
            subjectID: "john", spouseID: "eliza",
            member: member("Martha Barker", "Ma-Law", age: 66), kind: .mother, censusYear: 1891)

        let snap = appState.snapshot
        let martha = try #require(snap.profiles.values.first { $0.firstName == "Martha" }, "Martha created")
        #expect(martha.lastName == "Barker")
        #expect(martha.gender == .female)
        #expect(martha.birthDate?.bestYear == 1825)                       // 1891 − 66
        #expect(snap.parentsOf("eliza").contains { $0.id == martha.id }, "linked as Elizabeth's mother")
        // Elizabeth née Barker; the married surname is preserved, not lost.
        let eliza = try #require(snap.profiles["eliza"])
        #expect(eliza.lastName == "Barker")
        #expect(eliza.marriedSurname == "Cauldwell")
    }
}
