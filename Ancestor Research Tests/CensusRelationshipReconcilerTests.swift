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

    /// Census abbreviations: "Dau" must read as a daughter (child), not dropped
    /// as "not family" — while "Gdau" (granddaughter) stays out of nuclear scope.
    @Test func daughterAbbreviationIsRecognisedButGranddaughterIsNot() {
        let john = person("john", "John", "Wheeldon", birthYear: 1824)
        let household = [
            member("John Wheeldon", "Head", age: 37, isTarget: true),
            member("Hannah Wheeldon", "Dau", age: 8),
            member("Baby Wheeldon", "Gdau", age: 1)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["john": john],
            relationships: [],
            lifeEvents: ["john": [censusEvent("john", year: 1861, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: john, in: snapshot).first)
        let hannah = try! #require(recon.entries.first { $0.member.name == "Hannah Wheeldon" })
        #expect(hannah.censusRelation == .child)         // Dau → the head's child
        #expect(hannah.status == .missing)               // not yet in the tree → offered
        #expect(recon.entries.first { $0.member.name == "Baby Wheeldon" }?.status == .outOfScope)
    }

    /// Two household members sharing a name — a father "John" (Head) and his son
    /// "John" (Son) — must not be conflated. From the wife's viewpoint the Head is
    /// her spouse (in tree); the son is a missing child. Keying relations by name
    /// stamped both with the son's `.child`, so the husband read as a missing
    /// child ("Add son" on the Head, a phantom "child b.1824"). Live repro 2026-07-27.
    @Test func sameNamedHeadAndSonAreNotConflated() {
        let ruth = person("ruth", "Ruth", "Wheeldon", birthYear: 1824)
        let johnSr = person("johnSr", "John", "Wheeldon", birthYear: 1824)   // the husband
        let household = [
            member("John Wheeldon", "Head", age: 37),
            member("Ruth Wheeldon", "Wife", age: 37, isTarget: true),
            member("John Wheeldon", "Son", age: 12),                         // same name, the son
            member("Samuel Wheeldon", "Son", age: 9)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "johnSr": johnSr],
            relationships: [spouseEdge("ruth", "johnSr")],
            lifeEvents: ["ruth": [censusEvent("ruth", year: 1861, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: ruth, in: snapshot).first)
        // The Head John (age 37 → 1824) is Ruth's spouse, already in the tree.
        let head = try! #require(recon.entries.first { $0.member.relationship == "Head" })
        #expect(head.censusRelation == .spouse)
        #expect(head.status == .inTree(profileID: "johnSr"))
        // The Son John (age 12) is a distinct, missing child — not the Head.
        let sonJohn = try! #require(recon.entries.first {
            $0.member.relationship == "Son" && $0.member.name == "John Wheeldon"
        })
        #expect(sonJohn.censusRelation == .child)
        #expect(sonJohn.status == .missing)
        // No finding describes the 37-year-old Head as a missing child.
        let missing = CensusRelationshipReconciler.findings(for: ruth, in: snapshot).filter { $0.kind == .missing }
        #expect(!missing.contains { $0.censusRelation == .child && $0.member.age == 37 })
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

    /// A Wife added from a census lands under her MARRIED surname, not her
    /// maiden name: a census gives only the household (husband's) surname, which
    /// is her married name — her maiden `lastName` stays empty until a marriage
    /// record or a child's BMD yields it. The father keeps the census surname as
    /// his own birth surname. Gender is inferred from the "Wife" relationship
    /// term (this roster has no Sex column). (Owner report 2026-08-04: "Lydia
    /// Twyford" was created with Twyford as her maiden name.)
    @MainActor
    @Test func wifeAddedFromCensusGetsMarriedSurnameNotMaiden() throws {
        let db = try makeTempDB()
        // Subject is a child with NO parents in the tree — both Head and Wife
        // are missing and get created.
        _ = try db.addProfile(person("abraham", "Abraham", "Twyford", birthYear: 1888), source: .gedcom)

        let base = try db.buildSnapshot()
        let household = [
            member("George Twyford", "Head", age: 30),
            member("Lydia Twyford", "Wife", age: 29),
            member("Abraham Twyford", "Son", age: 3, isTarget: true)]
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = FamilyGraphSnapshot(
            profiles: base.profiles, relationships: base.relationships,
            lifeEvents: ["abraham": [censusEvent("abraham", year: 1891, household: household)]])

        appState.addMissingCensusRelatives(for: "abraham")

        let snap = appState.snapshot
        let lydia = try #require(snap.profiles.values.first { $0.firstName == "Lydia" }, "Lydia (Wife) created")
        #expect(lydia.marriedSurname == "Twyford", "census surname is her married name")
        #expect(lydia.lastName == nil, "maiden name is unknown from census — left empty")
        #expect(lydia.gender == .female, "inferred female from the Wife relationship term")
        // The father keeps the census surname as his birth surname.
        let george = try #require(snap.profiles.values.first { $0.firstName == "George" }, "George (Head) created")
        #expect(george.lastName == "Twyford")
        #expect(george.marriedSurname == nil)
    }

    /// Applying a SECOND child's census must not re-create siblings the tree
    /// already holds: the roster lists the whole nuclear family, but the create
    /// path dedups each member by name + birth year against the existing children
    /// of the shared parents. (Owner report 2026-08-05: applying Sarah Ann's
    /// census duplicated Mary A / Lydia, already added from Abraham's census.)
    @MainActor
    @Test func siblingAlreadyInTreeIsNotDuplicatedFromCensus() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("george", "George", "Twyford", birthYear: 1857), source: .gedcom)
        _ = try db.addProfile(person("sarah", "Sarah Ann", "Twyford", birthYear: 1882), source: .gedcom)
        _ = try db.addProfile(person("mary", "Mary A", "Twyford", birthYear: 1884), source: .gedcom)
        _ = try db.addRelationship(parentEdge("george", "sarah"))
        _ = try db.addRelationship(parentEdge("george", "mary"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        // Sarah's census lists her existing sibling Mary A (b.~1884, age 7 in 1891).
        let links = [CensusFamilyLinker.Link(
            member: member("Mary A Twyford", "Dau", age: 7), relation: .sibling)]
        let result = appState.addCensusFamily(
            links: links, subject: try #require(appState.snapshot.profiles["sarah"]),
            censusYear: 1891, sourceID: "freecen")

        #expect(result.added == 0, "the existing sibling is not re-created")
        #expect(result.skipped == 1)
        #expect(appState.snapshot.profiles.values.filter { $0.firstName == "Mary A" }.count == 1,
                "still exactly one Mary A in the tree")
    }

    // MARK: - Profile-card household proposal (net-new link preview)

    @Test func censusMemberGenderReadsSexThenRelationship() {
        #expect(AppState.censusMemberGender(HouseholdMember(name: "Elizabeth", relationship: "Wife", age: 38)) == .female)
        #expect(AppState.censusMemberGender(HouseholdMember(name: "George", relationship: "Son", age: 12)) == .male)
        // Sex column wins when present.
        #expect(AppState.censusMemberGender(HouseholdMember(name: "Pat", relationship: "Head", age: 40, sex: "F")) == .female)
        // No sex column and no gendered relationship term → unknown.
        #expect(AppState.censusMemberGender(HouseholdMember(name: "Chris", relationship: "Head", age: 40)) == nil)
    }

    /// John W Thompson's 1861 household (his live case): Head + Wife + siblings.
    /// The proposal previews only family NOT already on the tree.
    @MainActor
    @Test func netNewLinksExcludeKinAlreadyOnTheTree() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("johnw", "John W", "Thompson", birthYear: 1853), source: .gedcom)
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        let links: [CensusFamilyLinker.Link] = [
            .init(member: HouseholdMember(name: "John Thompson", relationship: "Head", age: 55, sex: "M"), relation: .parent),
            .init(member: HouseholdMember(name: "Elizabeth Thompson", relationship: "Wife", age: 38, sex: "F"), relation: .parent),
            .init(member: member("George Thompson", "Son", age: 12), relation: .sibling),
            .init(member: member("Mary E Thompson", "Dau", age: 5), relation: .sibling),
        ]

        // Nothing on the tree yet → every roster link is net-new.
        let subject = try #require(appState.snapshot.profiles["johnw"])
        #expect(appState.censusFamilyNetNewLinks(links, subject: subject, censusYear: 1861).count == 4)

        // Add the father → his roster row is matched (name + census-age year) and
        // drops out; the mother and both siblings remain net-new.
        _ = try db.addProfile(person("john", "John", "Thompson", birthYear: 1806), source: .gedcom)
        _ = try db.addRelationship(parentEdge("john", "johnw"))
        appState.snapshot = try db.buildSnapshot()
        let subject2 = try #require(appState.snapshot.profiles["johnw"])
        let net = appState.censusFamilyNetNewLinks(links, subject: subject2, censusYear: 1861)
        #expect(net.count == 3)
        #expect(!net.contains { $0.member.name == "John Thompson" })
    }

    // MARK: - In-law capture (father/mother-in-law of the Head)

    /// John W's real 1861 roster: the "Fa-Law" is the Head's father-in-law, so
    /// relative to John W (a child) he's a maternal grandfather.
    @Test func inLawLinkerEmitsParentInLawForAChildSubject() {
        let household = [
            member("John Thompson", "Head", age: 55),
            member("Elizabeth Thompson", "Wife", age: 38),
            member("John W Thompson", "Son", age: 8, isTarget: true),
            member("William Burnett", "Fa-Law", age: 74),
            member("Mary Kirkham", "Servnt", age: 18),          // excluded
        ]
        let inLaws = CensusFamilyLinker.inLawLinks(household: household)
        #expect(inLaws.count == 1)
        #expect(inLaws.first?.member.name == "William Burnett")
        // For a child subject the in-law is the parent of the subject's mother.
        #expect(inLaws.first?.parentOfRelation == .parent)
        // Brother/sister/son/daughter-in-law are not emitted.
        #expect(CensusFamilyLinker.inLawLinks(household: [
            member("A B", "Head", age: 40),
            member("C D", "Son", age: 10, isTarget: true),
            member("E F", "Bro-Law", age: 30)]).isEmpty)
    }

    /// The full capture: adding John W's family from his 1861 census creates the
    /// grandfather Burnett linked to Elizabeth AND stamps Elizabeth's maiden
    /// surname (Burnett) — two generations from one roster.
    @MainActor
    @Test func addCensusFamilyWiresInLawGrandparentAndMaidenSurname() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("johnw", "John W", "Thompson", birthYear: 1853), source: .gedcom)
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        let household = [
            HouseholdMember(name: "John Thompson", relationship: "Head", age: 55, sex: "M",
                            birthCounty: "Staffordshire"),
            HouseholdMember(name: "Elizabeth Thompson", relationship: "Wife", age: 38,
                            birthPlace: "Kingsley", sex: "F", birthCounty: "Staffordshire"),
            HouseholdMember(name: "John W Thompson", relationship: "Son", age: 8, sex: "M", isTarget: true),
            HouseholdMember(name: "William Burnett", relationship: "Fa-Law", age: 74,
                            birthPlace: "Grindon", sex: "M", birthCounty: "Staffordshire"),
        ]
        let links = CensusFamilyLinker.familyLinks(household: household)
        let subject = try #require(appState.snapshot.profiles["johnw"])
        let result = appState.addCensusFamily(
            links: links, subject: subject,
            censusYear: 1861, sourceID: "freecen", household: household)

        // Father + mother + grandfather = 3 new people.
        #expect(result.added == 3)
        let profiles = appState.snapshot.profiles.values
        // Elizabeth carries her maiden surname from the in-law, not "Thompson",
        // and her census birthplace (owner report: it was blank).
        let elizabeth = try #require(profiles.first { $0.firstName == "Elizabeth" })
        #expect(elizabeth.lastName == "Burnett", "the Fa-Law's surname is her maiden name")
        #expect(elizabeth.marriedSurname == "Thompson")
        #expect(elizabeth.birthLocation == "Kingsley, Staffordshire")
        // William Burnett exists and is Elizabeth's father (John W's grandfather).
        let william = try #require(profiles.first { $0.firstName == "William" && $0.lastName == "Burnett" })
        #expect(william.birthLocation == "Grindon, Staffordshire")
        let elizabethParents = appState.snapshot.parentsOf(elizabeth.id)
        #expect(elizabethParents.contains { $0.id == william.id },
                "Burnett is wired as the mother's father — a maternal grandfather")

        // Dedup: with the grandfather now on the tree, the in-law offer clears
        // (the raw roster still lists him, but he's no longer net-new).
        let subject2 = try #require(appState.snapshot.profiles["johnw"])
        let stillNew = appState.censusInLawNetNew(
            CensusFamilyLinker.inLawLinks(household: household), subject: subject2, censusYear: 1861)
        #expect(stillNew.isEmpty, "the grandfather is already on the tree — no repeat offer")
    }

    /// A census address is a household fact: applying it broadcasts to the whole
    /// household — the subject and each 1-hop relative that matches a roster row
    /// gets a census life-event for that year carrying the shared address plus
    /// their own occupation. (Owner request 2026-08-05.)
    @MainActor
    @Test func applyCensusToHouseholdWritesEventForEachMatchedMember() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("abraham", "Abraham", "Twyford", birthYear: 1888), source: .gedcom)
        _ = try db.addProfile(person("george", "George", "Twyford", birthYear: 1857), source: .gedcom)
        _ = try db.addProfile(person("mary", "Mary", "Twyford", birthYear: 1884), source: .gedcom)
        _ = try db.addRelationship(parentEdge("george", "abraham"))
        _ = try db.addRelationship(parentEdge("george", "mary"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        let household = [
            HouseholdMember(name: "George Twyford", relationship: "Head", age: 34, occupation: "Lead Miner", sex: "M"),
            HouseholdMember(name: "Abraham Twyford", relationship: "Son", age: 3, sex: "M", isTarget: true),
            HouseholdMember(name: "Mary Twyford", relationship: "Dau", age: 7, occupation: "Scholar", sex: "F")]
        let census = DiscoveryCensusHousehold(
            year: 1891, address: "Bakewell Rd", district: "Bakewell",
            parish: "Youlgreave", household: household)

        let n = appState.applyCensusToHousehold(subjectID: "abraham", census: census)
        #expect(n == 3, "subject + father + sibling each matched a roster row")

        let snap = appState.snapshot
        func censusDetails(_ id: String) throws -> CensusDetails {
            let ev = try #require(snap.lifeEvents[id]?.first {
                $0.type == .census && $0.date?.bestYear == 1891 }, "\(id) has an 1891 census event")
            guard case .census(let c)? = ev.details else {
                Issue.record("\(id) census event has no census details"); return CensusDetails()
            }
            return c
        }
        // The shared address reached the whole household.
        #expect(try censusDetails("abraham").address == "Bakewell Rd")
        #expect(try censusDetails("george").address == "Bakewell Rd")
        #expect(try censusDetails("mary").address == "Bakewell Rd")
        // Each member kept their OWN roster occupation.
        #expect(try censusDetails("george").occupation == "Lead Miner")
        #expect(try censusDetails("mary").occupation == "Scholar")
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

    /// Adding a census CHILD to a subject who has a spouse links the child to
    /// BOTH parents — a census child of the Wife is equally the Head's child, so
    /// it must not keep only the one parent. (The Wheeldon daughters added from
    /// Ruth's census had lost John as father.)
    @MainActor
    @Test func addingCensusChildLinksBothCoParents() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("ruth", "Ruth", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addProfile(person("john", "John", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("ruth", "john"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.addCensusRelative(subjectID: "ruth",
                                   member: member("Hannah Wheeldon", "Dau", age: 8),
                                   relation: .child, censusYear: 1861)

        let snap = appState.snapshot
        let hannah = try #require(snap.profiles.values.first { $0.firstName == "Hannah" })
        let parentIDs = Set(snap.parentsOf(hannah.id).map(\.id))
        #expect(parentIDs.contains("ruth"))
        #expect(parentIDs.contains("john"), "the co-parent (subject's spouse) is linked too")
    }

    // MARK: - Link existing instead of add duplicate

    /// A census relative who already EXISTS elsewhere in the tree (matched by
    /// name + year) but is not linked to the subject is offered as a LINK, not an
    /// add — so a second profile is never spawned. (Kezia's census names Mary, who
    /// exists as the orphaned Mary b.1856.)
    @Test func unlinkedExistingRelativeIsOfferedAsLinkNotAdd() {
        let ruth = person("ruth", "Ruth", "Wheeldon", birthYear: 1824)
        let kezia = person("kezia", "Kezia", "Wheeldon", birthYear: 1862)
        let maryLizzy = person("maryLizzy", "Mary", "Wheeldon", birthYear: 1856)   // exists, unlinked
        let household = [
            member("Ruth Wheeldon", "Head", age: 67),
            member("Kezia Wheeldon", "Dau", age: 29, isTarget: true),
            member("Mary Wheeldon", "Dau", age: 35)]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["ruth": ruth, "kezia": kezia, "maryLizzy": maryLizzy],
            relationships: [parentEdge("ruth", "kezia")],                         // Mary NOT linked
            lifeEvents: ["kezia": [censusEvent("kezia", year: 1891, household: household)]])

        let recon = try! #require(CensusRelationshipReconciler.reconciliations(for: kezia, in: snapshot).first)
        let mary = try! #require(recon.entries.first { $0.member.name == "Mary Wheeldon" })
        #expect(mary.censusRelation == .sibling)
        #expect(mary.status == .unlinkedInTree(profileID: "maryLizzy"))
        let unlinked = CensusRelationshipReconciler.unlinkedRelatives(for: kezia, in: snapshot)
        #expect(unlinked.count == 1)
        #expect(unlinked.first?.existingID == "maryLizzy")
        #expect(unlinked.first?.relation == .sibling)
        // She is NOT reported as a missing (create-new) relative.
        #expect(!CensusRelationshipReconciler.findings(for: kezia, in: snapshot)
            .contains { $0.kind == .missing && $0.member.name == "Mary Wheeldon" })
    }

    /// Linking wires the EXISTING profile through the subject's parents — no
    /// duplicate created, and the orphan gains her family.
    @MainActor
    @Test func linkCensusRelativeWiresExistingWithoutDuplicate() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("ruth", "Ruth", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addProfile(person("kezia", "Kezia", "Wheeldon", birthYear: 1862), source: .gedcom)
        _ = try db.addProfile(person("maryLizzy", "Mary", "Wheeldon", birthYear: 1856), source: .gedcom)
        _ = try db.addRelationship(parentEdge("ruth", "kezia"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        appState.linkCensusRelative(subjectID: "kezia", existingID: "maryLizzy",
                                    relation: .sibling, censusYear: 1891)

        let snap = appState.snapshot
        #expect(snap.profiles.values.filter { $0.firstName == "Mary" }.count == 1)   // no duplicate
        #expect(snap.childrenOf("ruth").contains { $0.id == "maryLizzy" })           // wired through the parent
        #expect(snap.siblingsOf("kezia").contains { $0.id == "maryLizzy" })
    }

    /// Sibling linking is symmetric: from the ORPHAN's own panel — the subject
    /// having no parents but the existing sibling having them — the orphan is
    /// attached to the sibling's parents, not a silent no-op.
    @MainActor
    @Test func linkSiblingFromParentlessSubjectAttachesToSiblingsParents() throws {
        let db = try makeTempDB()
        _ = try db.addProfile(person("ruth", "Ruth", "Wheeldon", birthYear: 1824), source: .gedcom)
        _ = try db.addProfile(person("kezia", "Kezia", "Wheeldon", birthYear: 1862), source: .gedcom)
        _ = try db.addProfile(person("maryLizzy", "Mary", "Wheeldon", birthYear: 1856), source: .gedcom)
        _ = try db.addRelationship(parentEdge("ruth", "kezia"))          // Kezia has a parent; Mary is an orphan

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()

        // Subject is the parentless orphan; the existing sibling Kezia has parents.
        appState.linkCensusRelative(subjectID: "maryLizzy", existingID: "kezia",
                                    relation: .sibling, censusYear: 1891)

        let snap = appState.snapshot
        #expect(snap.childrenOf("ruth").contains { $0.id == "maryLizzy" }, "orphan attached to sibling's parent")
        #expect(snap.siblingsOf("kezia").contains { $0.id == "maryLizzy" })
    }

    // MARK: - matchesRoleScoped (age-less/infant rows, owner report 2026-08-06)

    /// An age-less infant row ("7m" → no age, no birth year) must dedup by name
    /// against the already-linked child — else it's offered as net-new,
    /// duplicated on apply, and flagged "census unabsorbed" though present.
    @Test func matchesRoleScopedDedupesUndateableInfantByName() {
        let george = person("g", "George", "Cauldwell", birthYear: 1890)
        let infantRow = member("George Cauldwell", "Son", age: nil)   // the "7m" case
        // Plain matches() can't: the row is undateable.
        #expect(CensusRelationshipReconciler.matches(member: infantRow, profile: george, censusYear: 1891) == false)
        // Role-scoped falls back to the name match.
        #expect(CensusRelationshipReconciler.matchesRoleScoped(member: infantRow, profile: george, censusYear: 1891))
    }

    /// Namesake safety is unchanged for DATABLE rows: a same-name row with a
    /// wrong year must NOT match, even role-scoped (no name-only fallback fires
    /// when the census can date the row).
    @Test func matchesRoleScopedStillYearGatesDatableRows() {
        let george = person("g", "George", "Cauldwell", birthYear: 1890)
        let datableNamesake = member("George Cauldwell", "Son", age: 30)  // census 1891 → b.1861
        #expect(CensusRelationshipReconciler.matchesRoleScoped(member: datableNamesake, profile: george, censusYear: 1891) == false)
    }

    /// The name still has to match — an age-less row with a different given name
    /// is not silently absorbed.
    @Test func matchesRoleScopedRequiresNameMatch() {
        let george = person("g", "George", "Cauldwell", birthYear: 1890)
        let otherInfant = member("Henry Cauldwell", "Son", age: nil)
        #expect(CensusRelationshipReconciler.matchesRoleScoped(member: otherInfant, profile: george, censusYear: 1891) == false)
    }

    /// The mirror arm (owner report 2026-08-06, Abraham Twyford): a DATABLE
    /// census row must still dedup by name against a DATELESS tree profile —
    /// a linked ghost father with no birth date otherwise reads as "not on
    /// the tree" and grows a duplicate-creating Add offer.
    @Test func matchesRoleScopedDedupesDatableRowAgainstDatelessProfile() {
        let ghostFather = person("g", "George", "Twyford", birthYear: nil)
        let headRow = member("George TWYFORD", "Head", age: 30)
        #expect(CensusRelationshipReconciler.matches(member: headRow, profile: ghostFather, censusYear: 1891) == false)
        #expect(CensusRelationshipReconciler.matchesRoleScoped(member: headRow, profile: ghostFather, censusYear: 1891))
    }

    /// End-to-end through `reconciliations`: the subject's linked-but-dateless
    /// father, appearing as the datable Head of the subject's own census, is
    /// classified in-tree — not `.missing` (which rendered as "a census lists
    /// 1 of Abraham's relatives not in the tree" plus an Add-father offer).
    @Test func reconciliationsClassifyDatelessLinkedParentAsInTree() {
        let abraham = person("abraham", "Abraham", "Twyford", birthYear: 1888)
        let ghostFather = person("george", "George", "Twyford", birthYear: nil)
        let household = [
            member("George TWYFORD", "Head", age: 30),
            member("Abraham TWYFORD", "Son", age: 3, isTarget: true),
        ]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["abraham": abraham, "george": ghostFather],
            relationships: [parentEdge("george", "abraham")],
            lifeEvents: ["abraham": [censusEvent("abraham", year: 1891, household: household)]])

        let findings = CensusRelationshipReconciler.findings(for: abraham, in: snapshot)
        #expect(findings.filter { $0.kind == .missing }.isEmpty)
        let recons = CensusRelationshipReconciler.reconciliations(for: abraham, in: snapshot)
        let georgeEntry = recons.first?.entries.first { $0.member.name == "George TWYFORD" }
        #expect(georgeEntry?.status == .inTree(profileID: "george"))
    }
}
