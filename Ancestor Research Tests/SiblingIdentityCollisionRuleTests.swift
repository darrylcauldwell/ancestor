import Testing
import Foundation
@testable import AncestorKit

/// The 1871 Whittington household — John H Gladwin's only record.
/// File-scope so it can be a default argument (a default value cannot reach a
/// type's static members).
private let ark1871 = "https://www.familysearch.org/ark:/61903/1:1:VBFC-NBV"
/// The 1881 Handsworth household — Thomas H Gladwin's only record.
private let ark1881 = "https://www.familysearch.org/ark:/61903/1:1:Q27Y-2JHF"

/// EV17 (owner dogfood 2026-08-26) — `DuplicateDetectionRule`'s forename gate is
/// correct for what it guards (Dorothy vs Florence are different people) and
/// structurally blind to a SIBLING IDENTITY COLLISION: two children of one couple
/// recorded under different forenames who may be one child. The gate fires before
/// surname (0.4) and birth-year overlap (0.3) are added, and `evaluate` consults
/// only name and birthDate — never parent edges, sibship or evidence.
///
/// The fixtures below are the owner's real Gladwin cluster: real profile ids, real
/// birth dates, real FamilySearch arks and the real 1871 Whittington / 1881
/// Handsworth household rosters. A regression here is a regression against the
/// live tree, not against a toy.
struct SiblingIdentityCollisionRuleTests {

    // MARK: - Live ids

    private static let fatherID = "@I332233296774@"          // William Gladwin b.1833
    private static let motherID = "@I332233296853@"          // Hannah Hewkin b.1836
    private static let johnID = "D7ED4D6A-940D-410F-BB58-3491EFF1CE07"     // John H b. CAL 1861
    private static let thomasID = "66F4E482-F2BD-4350-A19A-AE7A461EF021"   // Thomas H b.1861
    private static let jamesID = "36640953-2A33-4B02-981F-CC217260C312"    // James b.1865
    private static let williamJrID = "F548FB6F-1318-4619-9FA1-340900C6F428" // William b.1866
    private static let grandfatherID = "DD09950B-2B73-4D21-9A4D-C781B90E7E6B" // Thomas b. CAL 1801

    // MARK: - Builders

    private func person(
        id: String, first: String?, middle: String? = nil, last: String? = "Gladwin",
        gender: Gender? = .male, birth: String? = nil, citing url: String? = nil,
        deleted: Bool = false
    ) -> Profile {
        var sources: [ProfileField: [FieldSource]] = [:]
        if let url {
            sources[.birthDate] = [FieldSource(
                origin: SourceOrigin(identifier: "field-researcher"),
                raw: "field-researcher", addedAt: Date(),
                citation: Citation(title: "Census", url: url))]
        }
        return Profile(
            id: id, externalIDs: [:], firstName: first, middleName: middle,
            lastName: last, gender: gender, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) },
            birthLocation: "Unstone, Derbyshire",
            deathDate: nil, deathLocation: nil, bio: nil,
            isDeleted: deleted, sources: sources, disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String,
                            role: ParentRole = .father) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: role,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil,
                     divorceDate: nil)
    }

    private func member(_ name: String, _ relation: String,
                        age: Int, birthYear: Int, sex: String) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relation, age: age, birthYear: birthYear,
                        birthPlace: "Unstone", sex: sex)
    }

    private func censusEvent(on profileID: String, date: String,
                             household: [HouseholdMember], url: String) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: profileID, type: .census,
            date: GenealogicalDate(parsing: date), location: "Whittington",
            details: .census(CensusDetails(household: household)),
            sources: [FieldSource(origin: SourceOrigin(identifier: "field-researcher"),
                                  raw: "field-researcher", addedAt: Date(),
                                  citation: Citation(url: url))])
    }

    /// The 1871 Whittington roster, verbatim from the live tree. John H is on it;
    /// Thomas H is not. Note row 3: the GRANDFATHER "Thomas Gladwin", age 70 — the
    /// row that makes a name-only co-residence matcher unsafe.
    private var roster1871: [HouseholdMember] {
        [member("William Gladwin", "Head", age: 36, birthYear: 1835, sex: "M"),
         member("Hannah Gladwin", "Wife", age: 35, birthYear: 1836, sex: "F"),
         member("Thomas Gladwin", "Father", age: 70, birthYear: 1801, sex: "M"),
         member("Sarah Gladwin", "Daughter", age: 11, birthYear: 1860, sex: "F"),
         member("John H Gladwin", "Son", age: 10, birthYear: 1861, sex: "M"),
         member("Caroline Gladwin", "Daughter", age: 8, birthYear: 1863, sex: "F"),
         member("James Gladwin", "Son", age: 7, birthYear: 1864, sex: "M"),
         member("William Gladwin", "Son", age: 6, birthYear: 1865, sex: "M"),
         member("Charles Gladwin", "Son", age: 2, birthYear: 1869, sex: "M")]
    }

    /// The 1881 Handsworth roster, verbatim from the live tree. Thomas H is on it;
    /// John H is not.
    private var roster1881: [HouseholdMember] {
        [member("William Gladwin", "Head", age: 47, birthYear: 1834, sex: "M"),
         member("Hannah Gladwin", "Wife", age: 45, birthYear: 1836, sex: "F"),
         member("Thomas H Gladwin", "Son", age: 20, birthYear: 1861, sex: "M"),
         member("James Gladwin", "Son", age: 16, birthYear: 1865, sex: "M"),
         member("William Gladwin", "Son", age: 15, birthYear: 1866, sex: "M"),
         member("Charles Gladwin", "Son", age: 12, birthYear: 1869, sex: "M")]
    }

    /// The cluster as the live tree holds it. `johnCites` / `thomasCites` etc. let
    /// individual tests vary ONE condition at a time.
    private func gladwins(
        johnCites: String? = ark1871,
        thomasCites: String? = ark1881,
        jamesCites: String? = ark1871,
        williamJrCites: String? = ark1881,
        johnHasMother: Bool = true,
        dismissed: Set<DuplicatePairKey> = []
    ) -> FamilyGraphSnapshot {
        let father = person(id: Self.fatherID, first: "William", birth: "1833")
        let mother = person(id: Self.motherID, first: "Hannah", last: "Hewkin",
                            gender: .female, birth: "1836")
        let grandfather = person(id: Self.grandfatherID, first: "Thomas", birth: "CAL 1801")
        let john = person(id: Self.johnID, first: "John", middle: "H",
                          birth: "CAL 1861", citing: johnCites)
        let thomas = person(id: Self.thomasID, first: "Thomas", middle: "H",
                            birth: "1861", citing: thomasCites)
        let james = person(id: Self.jamesID, first: "James", birth: "1865", citing: jamesCites)
        let williamJr = person(id: Self.williamJrID, first: "William", birth: "1866",
                               citing: williamJrCites)

        var edges = [parentEdge(Self.grandfatherID, Self.fatherID)]
        for child in [Self.johnID, Self.thomasID, Self.jamesID, Self.williamJrID] {
            edges.append(parentEdge(Self.fatherID, child))
            if child != Self.johnID || johnHasMother {
                edges.append(parentEdge(Self.motherID, child, role: .mother))
            }
        }

        // Both rosters hang off the FATHER's profile in the live tree — which is
        // why co-residence has to be looked for tree-wide, not just on the pair.
        let events: [String: [LifeEvent]] = [
            Self.fatherID: [
                censusEvent(on: Self.fatherID, date: "2 Apr 1871",
                            household: roster1871, url: ark1871),
                censusEvent(on: Self.fatherID, date: "1881",
                            household: roster1881, url: ark1881),
            ],
            Self.thomasID: [
                censusEvent(on: Self.thomasID, date: "1881",
                            household: roster1881, url: ark1881),
            ],
        ]

        let people = [father, mother, grandfather, john, thomas, james, williamJr]
        return FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }),
            relationships: edges, lifeEvents: events,
            dismissedDuplicatePairs: dismissed)
    }

    private func fire(_ snapshot: FamilyGraphSnapshot, from id: String) -> [AuditResult] {
        guard let p = snapshot.profiles[id] else { return [] }
        return SiblingIdentityCollisionRule().evaluate(profile: p, snapshot: snapshot)
    }

    // MARK: - The live case

    @Test func johnAndThomasGladwinRaiseTheQuestion() {
        let snapshot = gladwins()
        // Reported once, from the alphabetically-first id (Thomas's "66F4…" sorts
        // before John's "D7ED…"), exactly as DuplicateDetectionRule reports pairs.
        let fromThomas = fire(snapshot, from: Self.thomasID)
        let fromJohn = fire(snapshot, from: Self.johnID)
        #expect(fromThomas.count == 1)
        #expect(fromJohn.isEmpty)
        #expect(fromThomas.first?.relatedProfileIDs == [Self.johnID])
        #expect(fromThomas.first?.ruleID == "siblingIdentityCollision")
    }

    @Test func duplicateDetectionIsBlindToTheSamePair() {
        // The premise of EV17: nameSimilarity("Thomas","John") is 0, so the pair
        // scores 0 BEFORE surname or birth-year overlap is added.
        let snapshot = gladwins()
        #expect(nameSimilarity("John", "Thomas") == 0.0)
        let dupes = DuplicateDetectionRule().evaluate(
            profile: snapshot.profiles[Self.thomasID]!, snapshot: snapshot)
        #expect(!dupes.contains { $0.relatedProfileIDs?.contains(Self.johnID) == true })
    }

    @Test func theFindingIsAnOpenQuestionNotAMergeProposal() {
        let result = fire(gladwins(), from: Self.thomasID).first
        #expect(result?.category == .issue)
        #expect(result?.severity == .warning)
        // The merge affordances in the UI key on ruleID == "duplicateDetection".
        // This must never borrow that id — "two brothers" is a legitimate answer
        // and a merge here cannot be undone.
        #expect(result?.ruleID != "duplicateDetection")
        #expect(result?.message.contains("One child or two?") == true)
        #expect(result?.message.contains("cannot be undone") == true)
    }

    @Test func theMessageNamesTheDisjointRosters() {
        let message = fire(gladwins(), from: Self.thomasID).first?.message ?? ""
        #expect(message.contains("Thomas only on 1881"))
        #expect(message.contains("John only on 1871"))
        #expect(message.contains("William Gladwin"))   // the shared parents
        #expect(message.contains("Hannah Hewkin"))
    }

    // MARK: - Condition 5: never co-resident

    @Test func jamesAndWilliamJrDoNotFireBecauseTheyShareBothRosters() {
        // Everything else about this pair passes: identical parents, both male,
        // b.1865 and b.1866 (one year apart), forenames completely dissimilar,
        // and the fixture deliberately gives them citations to DIFFERENT records
        // so condition 4 cannot be what stops it. Only condition 5 can.
        let snapshot = gladwins()
        let james = snapshot.profiles[Self.jamesID]!
        let williamJr = snapshot.profiles[Self.williamJrID]!
        #expect(SiblingIdentityCollisionRule.forenamesDiffer(james, williamJr))
        #expect(SiblingIdentityCollisionRule.birthWindowsCollide(james, williamJr))
        #expect(SiblingIdentityCollisionRule
            .citedRecords(of: james, in: snapshot)
            .isDisjoint(with: SiblingIdentityCollisionRule.citedRecords(of: williamJr, in: snapshot)))

        let rosters = SiblingIdentityCollisionRule.rosterOverlap(james, williamJr, in: snapshot)
        #expect(rosters.coResident, "they sit two rows apart on the 1871 AND 1881 rosters")
        #expect(fire(snapshot, from: Self.jamesID).isEmpty)
        #expect(fire(snapshot, from: Self.williamJrID).isEmpty)
    }

    @Test func theGrandfathersRosterRowDoesNotCountAsThomasBeingPresent() {
        // The 1871 roster seats "Thomas Gladwin, Father, 70" — the grandfather. A
        // name-only co-residence matcher would read that as Thomas H b.1861,
        // conclude the brothers were co-resident, and swallow the finding.
        let snapshot = gladwins()
        let thomas = snapshot.profiles[Self.thomasID]!
        let john = snapshot.profiles[Self.johnID]!
        let rosters = SiblingIdentityCollisionRule.rosterOverlap(thomas, john, in: snapshot)
        #expect(!rosters.coResident)
        #expect(rosters.aYears == [1881])
        #expect(rosters.bYears == [1871])
    }

    // MARK: - The grandfather pair must stay silent

    @Test func grandfatherAndGrandsonDoNotFire() {
        let snapshot = gladwins()
        let grandfather = snapshot.profiles[Self.grandfatherID]!
        let thomas = snapshot.profiles[Self.thomasID]!
        // Condition 1: not siblings at all — different parent sets.
        #expect(Set(snapshot.parentsOf(grandfather.id).map(\.id))
            != Set(snapshot.parentsOf(thomas.id).map(\.id)))
        // Condition 3: b.1801 vs b.1861 — sixty years apart.
        #expect(!SiblingIdentityCollisionRule.birthWindowsCollide(grandfather, thomas))
        // Condition 7: same forename, so this rule's trigger never arms.
        #expect(!SiblingIdentityCollisionRule.forenamesDiffer(grandfather, thomas))
        #expect(fire(snapshot, from: Self.grandfatherID).isEmpty)
        #expect(!fire(snapshot, from: Self.thomasID)
            .contains { $0.relatedProfileIDs?.contains(Self.grandfatherID) == true })
    }

    // MARK: - Must not worsen the known namesake over-fire

    @Test func sameForenameNamesakesWithDifferentParentsAreUntouched() {
        // The known duplicateDetection over-fire: two same-forename namesakes with
        // DIFFERENT parents. This rule requires identical parent sets AND forename
        // dissimilarity — the namesake pair has neither, so it is orthogonal and
        // cannot make that over-fire worse.
        let dadA = person(id: "dad-a", first: "Abel", birth: "1830")
        let dadB = person(id: "dad-b", first: "Bertram", birth: "1832")
        let georgeA = person(id: "a-george", first: "George", birth: "1861",
                             citing: ark1871)
        let georgeB = person(id: "b-george", first: "George", birth: "1861",
                             citing: ark1881)
        let snapshot = FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues:
                [dadA, dadB, georgeA, georgeB].map { ($0.id, $0) }),
            relationships: [parentEdge("dad-a", "a-george"), parentEdge("dad-b", "b-george")])

        // duplicateDetection still behaves exactly as before…
        let dupes = DuplicateDetectionRule().evaluate(profile: georgeA, snapshot: snapshot)
        #expect(dupes.contains { $0.relatedProfileIDs?.contains("b-george") == true })
        // …and this rule adds nothing to it.
        #expect(SiblingIdentityCollisionRule().evaluate(profile: georgeA, snapshot: snapshot).isEmpty)
        #expect(SiblingIdentityCollisionRule().evaluate(profile: georgeB, snapshot: snapshot).isEmpty)
    }

    @Test func sameForenameSiblingsAreDuplicateDetectionsBusinessNotThisRules() {
        // Two same-parent, same-forename children: forename similarity is 1.0, so
        // condition 7 never arms and duplicateDetection owns the pair. The two
        // rules must partition the space, never both describe one row.
        let dad = person(id: "dad", first: "Abel", birth: "1830")
        let a = person(id: "a-john", first: "John", birth: "1861", citing: ark1871)
        let b = person(id: "b-john", first: "John", birth: "1861", citing: ark1881)
        let snapshot = FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: [dad, a, b].map { ($0.id, $0) }),
            relationships: [parentEdge("dad", "a-john"), parentEdge("dad", "b-john")])
        #expect(DuplicateDetectionRule.flags(a, b))
        #expect(SiblingIdentityCollisionRule().evaluate(profile: a, snapshot: snapshot).isEmpty)
    }

    // MARK: - Narrowing guards

    @Test func aDismissedPairStaysDismissed() {
        let snapshot = gladwins(
            dismissed: [DuplicatePairKey(Self.thomasID, Self.johnID)])
        #expect(fire(snapshot, from: Self.thomasID).isEmpty)
    }

    @Test func sharedEvidenceIsNotDisjointEvidence() {
        // John cited from the SAME 1881 record as Thomas — one record naming both
        // is the opposite of the EV17 signal.
        let snapshot = gladwins(johnCites: ark1881)
        #expect(fire(snapshot, from: Self.thomasID).isEmpty)
    }

    @Test func anUncitedProfileCannotBeOnADisjointRecord() {
        // John carries no citation at all, so "appearing on disjoint records"
        // would be a false claim — the rule must not make it. (Thomas keeps his
        // 1881 census event, so this isolates the empty side.)
        let snapshot = gladwins(johnCites: nil)
        #expect(SiblingIdentityCollisionRule
            .citedRecords(of: snapshot.profiles[Self.johnID]!, in: snapshot).isEmpty)
        #expect(fire(snapshot, from: Self.thomasID).isEmpty)
    }

    @Test func aHalfSiblingIsNotAnIdenticalParentSet() {
        // John keeps only the father; Thomas has both. "Shares a parent" is not
        // "identical parents", and half-siblings must never be proposed as one.
        let snapshot = gladwins(johnHasMother: false)
        #expect(fire(snapshot, from: Self.thomasID).isEmpty)
    }

    @Test func undatedChildrenAreSilent() {
        // An unbounded birth window would "intersect" everything.
        let snapshot = gladwins()
        let undatedJohn = person(id: Self.johnID, first: "John", middle: "H",
                                 birth: nil, citing: ark1871)
        var profiles = snapshot.profiles
        profiles[Self.johnID] = undatedJohn
        let mutated = FamilyGraphSnapshot(
            profiles: profiles, relationships: snapshot.relationships,
            lifeEvents: snapshot.lifeEvents)
        #expect(fire(mutated, from: Self.thomasID).isEmpty)
    }

    @Test func aSoftDeletedSiblingIsNotALiveIdentity() {
        let snapshot = gladwins()
        var profiles = snapshot.profiles
        profiles[Self.johnID] = person(id: Self.johnID, first: "John", middle: "H",
                                       birth: "CAL 1861", citing: ark1871,
                                       deleted: true)
        let mutated = FamilyGraphSnapshot(
            profiles: profiles, relationships: snapshot.relationships,
            lifeEvents: snapshot.lifeEvents)
        #expect(fire(mutated, from: Self.thomasID).isEmpty)
    }

    @Test func sexMustBeKnownOnBothSides() {
        let snapshot = gladwins()
        var profiles = snapshot.profiles
        profiles[Self.johnID] = person(id: Self.johnID, first: "John", middle: "H",
                                       gender: nil, birth: "CAL 1861", citing: ark1871)
        let mutated = FamilyGraphSnapshot(
            profiles: profiles, relationships: snapshot.relationships,
            lifeEvents: snapshot.lifeEvents)
        #expect(fire(mutated, from: Self.thomasID).isEmpty)
    }

    // MARK: - Registry

    @Test func theRuleIsRegisteredAsAnIssue() {
        let rule = AuditRules.builtIn.first { $0.id == "siblingIdentityCollision" }
        #expect(rule != nil)
        #expect(rule?.category == .issue)
        #expect(rule?.defaultSeverity == .warning)
    }
}
