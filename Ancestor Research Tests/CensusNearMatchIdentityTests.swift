import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV18, 2026-08-26 — the near-match rung of census absorption, and what the
/// surfaces are allowed to CLAIM about it.
///
/// `CensusRelationshipReconciler.nearMatchCandidate` pairs a roster row with a
/// tree relative on structure alone: same household role, that role a singleton
/// on the tree, matching surname, sex not contradicted, birth years within
/// tolerance — and a forename that does NOT agree. It is the engine's weakest
/// rung and the only one that asserts an identity the names contradict.
///
/// The case that exposed it is William Gladwin's 1871 Whittington schedule
/// (FamilySearch 1:1:VBFC-NBV, Chesterfield RD ED 40 household 95). It lists a
/// son "John H Gladwin", b. 1861, born Unstone. The tree — built 28 minutes
/// earlier from the family's 1881 Handsworth schedule — already held "Thomas H
/// Gladwin", b. 1861, born Unstone. Same surname, same role, same year, same
/// birthplace; different forename. An adversarial review put "same boy" at about
/// 70%, explicitly NOT proven, with a do-not-merge ruling.
///
/// Two separate defects live in that one row, and only the second is dangerous:
///  1. the rival set counts roster peers that are already resolved to a
///     DIFFERENT tree profile, so the rung refuses (his brother James blocks it);
///  2. had it fired, John H would have been absorbed into Thomas H with nothing
///     asked — the count would silently drop him and the roster would draw a
///     green "✓ Thomas Gladwin".
///
/// (2) is the one this file defends against, because the standing invariant is
/// WHEN IN DOUBT, SPLIT: over-splitting is recoverable by the user, over-merging
/// is not. These tests therefore assert the SAFETY property (the row is never
/// presented as settled, and the split always remains available) rather than
/// pinning today's `.missing`, so that repairing (1) cannot make them lie.
struct CensusNearMatchIdentityTests {

    // MARK: - Fixtures (the real 1871 Whittington roster and the tree it met)

    private func person(_ id: String, _ first: String, _ last: String,
                        birthYear: Int?, gender: Gender) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last, gender: gender,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: .normal),
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .unspecified,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// The 1871 schedule verbatim: every row carries its transcribed birth year,
    /// so `memberBirthYear` never has to fall back on census-year − age.
    private func whittington1871(includeJames: Bool = true) -> [HouseholdMember] {
        var rows: [HouseholdMember] = [
            HouseholdMember(name: "William Gladwin", relationship: "Head", age: 36, birthYear: 1835,
                            birthPlace: "Bolsover", occupation: "Coal Miner", sex: "M", isTarget: true),
            HouseholdMember(name: "Hannah Gladwin", relationship: "Wife", age: 35, birthYear: 1836,
                            birthPlace: "Holymoorside", sex: "F"),
            HouseholdMember(name: "Thomas Gladwin", relationship: "Father", age: 70, birthYear: 1801,
                            birthPlace: "Ashover", sex: "M"),
            HouseholdMember(name: "Sarah Gladwin", relationship: "Daughter", age: 11, birthYear: 1860,
                            birthPlace: "Unstone", sex: "F"),
            HouseholdMember(name: "John H Gladwin", relationship: "Son", age: 10, birthYear: 1861,
                            birthPlace: "Unstone", sex: "M"),
            HouseholdMember(name: "Caroline Gladwin", relationship: "Daughter", age: 8, birthYear: 1863,
                            birthPlace: "Unstone", sex: "F")
        ]
        if includeJames {
            rows.append(HouseholdMember(name: "James Gladwin", relationship: "Son", age: 7, birthYear: 1864,
                                        birthPlace: "Whittington", sex: "M"))
        }
        rows.append(HouseholdMember(name: "William Gladwin", relationship: "Son", age: 6, birthYear: 1865,
                                    birthPlace: "Whittington", sex: "M"))
        rows.append(HouseholdMember(name: "Charles Gladwin", relationship: "Son", age: 2, birthYear: 1869,
                                    birthPlace: "Whittington", sex: "M"))
        return rows
    }

    /// The tree as the 1871 absorption found it: the children the 1881 Handsworth
    /// schedule had just created, carrying THAT census's birth years — James is
    /// recorded 1865 there (age 16), which is why he is not himself a candidate
    /// for the 1861-born roster row.
    private func gladwinTree(household: [HouseholdMember]) -> FamilyGraphSnapshot {
        let william = person("william", "William", "Gladwin", birthYear: 1833, gender: .male)
        let hannah  = person("hannah", "Hannah", "Gladwin", birthYear: 1836, gender: .female)
        let thomas  = person("thomas", "Thomas", "Gladwin", birthYear: 1861, gender: .male)
        let james   = person("james", "James", "Gladwin", birthYear: 1865, gender: .male)
        let willjr  = person("willjr", "William", "Gladwin", birthYear: 1866, gender: .male)
        let emma    = person("emma", "Emma", "Gladwin", birthYear: 1868, gender: .female)
        let charles = person("charles", "Charles", "Gladwin", birthYear: 1869, gender: .male)
        let event = LifeEvent(
            id: UUID(), profileID: "william", type: .census,
            date: GenealogicalDate(parsing: "1871"),
            details: .census(CensusDetails(district: "Chesterfield", parish: "Whittington",
                                           household: household)))
        return FamilyGraphSnapshot(
            profiles: ["william": william, "hannah": hannah, "thomas": thomas, "james": james,
                       "willjr": willjr, "emma": emma, "charles": charles],
            relationships: [
                spouseEdge("william", "hannah"),
                parentEdge("william", "thomas"), parentEdge("hannah", "thomas"),
                parentEdge("william", "james"),  parentEdge("hannah", "james"),
                parentEdge("william", "willjr"), parentEdge("hannah", "willjr"),
                parentEdge("william", "emma"),   parentEdge("hannah", "emma"),
                parentEdge("william", "charles"), parentEdge("hannah", "charles")],
            lifeEvents: ["william": [event]])
    }

    private func entry(_ name: String, in snapshot: FamilyGraphSnapshot)
        -> CensusRelationshipReconciler.CensusReconciliation.RosterEntry? {
        guard let william = snapshot.profiles["william"] else { return nil }
        return CensusRelationshipReconciler.reconciliations(for: william, in: snapshot)
            .flatMap(\.entries)
            .first { $0.member.name == name }
    }

    // MARK: - Problem 1: the rival set counts an already-resolved peer

    /// The premise of the whole diagnosis. James's 1871 row (b. 1864) resolves to
    /// the tree's James (b. 1865) by name + year — he is NOT an unresolved person
    /// competing for Thomas's identity, he is already spoken for.
    @Test func theRivalRosterRowIsItselfAlreadyMatchedToItsOwnTreeProfile() throws {
        let household = whittington1871()
        let snapshot = gladwinTree(household: household)
        let james = try #require(entry("James Gladwin", in: snapshot))
        #expect(james.censusRelation == .child)
        #expect(james.status == .inTree(profileID: "james"),
                "James's own row is resolved to James — so he cannot also be an open rival for Thomas")
    }

    /// And the rival set is what refuses the pairing, not the tree side. Take
    /// James's row off the schedule and every other guard still passes: Thomas is
    /// the only tree child the years and sex allow, the surname agrees, and the
    /// forenames do not. His presence is the whole difference.
    ///
    /// `yearTolerance` is 3 and |1864 − 1861| is exactly 3, so James sits on the
    /// boundary — he qualifies as a rival by one year of census-age slack while
    /// being, on the tree, a 1865-born boy four years off the candidate.
    @Test func removingTheAlreadyMatchedPeerIsWhatUnblocksTheNearMatch() throws {
        let snapshot = gladwinTree(household: whittington1871(includeJames: false))
        let john = try #require(entry("John H Gladwin", in: snapshot))
        guard case .nearMatch(let candidateID, _) = john.status else {
            Issue.record("with the rival row gone every other near-match guard passes, got \(john.status)")
            return
        }
        #expect(candidateID == "thomas")
    }

    // MARK: - Problem 2: a proposal must never read as a decision

    /// The safety property, and the one that matters. Whatever the rival rule
    /// decides, John H must never be classified as an ESTABLISHED identity: either
    /// he is offered as a new person (`.missing`), or he is raised as an explicit
    /// question against Thomas (`.nearMatch`). `.inTree` — the status the roster
    /// draws as a green tick and the absorption count treats as already handled —
    /// would be the app fusing two boys on a 70% guess.
    @Test func theNearMatchedRowIsNeverClassifiedAsSettled() throws {
        let snapshot = gladwinTree(household: whittington1871())
        let john = try #require(entry("John H Gladwin", in: snapshot))
        switch john.status {
        case .missing:
            break                                       // offered as his own person
        case .nearMatch(let candidateID, _):
            #expect(candidateID == "thomas")            // raised as a question
        default:
            Issue.record("""
                John H Gladwin must stay either an offer to add or an open identity question — \
                got \(john.status), which reads as decided
                """)
        }
    }

    /// `findings` must not turn a proposal into a chore either: a `.nearMatch` is
    /// deliberately not a `.missing` finding. Whichever way the rung goes, the
    /// audit must not both propose him as Thomas AND nag to add him.
    @Test func aNearMatchIsNeverAlsoReportedAsAMissingRelative() throws {
        let snapshot = gladwinTree(household: whittington1871(includeJames: false))
        let william = try #require(snapshot.profiles["william"])
        let findings = CensusRelationshipReconciler.findings(for: william, in: snapshot)
        #expect(!findings.contains { $0.kind == .missing && $0.member.name == "John H Gladwin" })
    }

    // MARK: - What the roster row is allowed to claim

    private func rosterEntry(
        _ status: CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status,
        relation: CensusRelation? = .child
    ) -> CensusRelationshipReconciler.CensusReconciliation.RosterEntry {
        CensusRelationshipReconciler.CensusReconciliation.RosterEntry(
            member: HouseholdMember(name: "John H Gladwin", relationship: "Son",
                                    age: 10, birthYear: 1861, sex: "M"),
            censusRelation: relation, status: status)
    }

    /// Only `.inTree` earns the settled green tick. `.nearMatch` used to draw the
    /// identical "✓ Thomas Gladwin" in the identical green, which is how a 70%
    /// proposal came to look like a fact.
    @Test func onlyAnInTreeStatusAssertsASettledIdentity() {
        #expect(CensusHouseholdFixRow.assertsSettledIdentity(.inTree(profileID: "thomas")))
        #expect(!CensusHouseholdFixRow.assertsSettledIdentity(
            .nearMatch(profileID: "thomas", reason: "same surname and household role")))
        #expect(!CensusHouseholdFixRow.assertsSettledIdentity(.unlinkedInTree(profileID: "thomas")))
        #expect(!CensusHouseholdFixRow.assertsSettledIdentity(.missing))
        #expect(!CensusHouseholdFixRow.assertsSettledIdentity(.subject))
        #expect(!CensusHouseholdFixRow.assertsSettledIdentity(nil))
    }

    /// A near-match row raises a question the user can answer, and carries the
    /// relation the "different person" answer needs in order to create them.
    @Test func aNearMatchRowRaisesAnAnswerableIdentityQuestion() throws {
        let question = try #require(CensusHouseholdFixRow.identityQuestion(
            rosterEntry(.nearMatch(profileID: "thomas", reason: "birth years agree"))))
        #expect(question.candidateID == "thomas")
        #expect(question.relation == .child)
        #expect(question.reason == "birth years agree")
    }

    /// No other status is a question — an offer to add and an offer to link are
    /// already unambiguous, and turning them into questions would bury them.
    @Test func settledAndActionableStatusesRaiseNoQuestion() {
        #expect(CensusHouseholdFixRow.identityQuestion(rosterEntry(.missing)) == nil)
        #expect(CensusHouseholdFixRow.identityQuestion(rosterEntry(.inTree(profileID: "thomas"))) == nil)
        #expect(CensusHouseholdFixRow.identityQuestion(
            rosterEntry(.unlinkedInTree(profileID: "thomas"))) == nil)
        #expect(CensusHouseholdFixRow.identityQuestion(nil) == nil)
    }

    /// Without a census-implied relation there is no way to act on either answer,
    /// so the row falls back to a plain marker rather than offering a dead button
    /// (the defect class of the 2026-08-25 inert "add" markers).
    @Test func anUnrelatedNearMatchRowRaisesNoActionableQuestion() {
        #expect(CensusHouseholdFixRow.identityQuestion(
            rosterEntry(.nearMatch(profileID: "thomas", reason: "r"), relation: nil)) == nil)
    }

    // MARK: - The split must always remain available

    /// The answer the invariant prefers has to actually work. Adding John H as his
    /// own person from the 1871 schedule creates a SECOND boy alongside Thomas —
    /// the near-match rung must not be able to swallow the row on the write path
    /// either.
    @MainActor
    @Test func addingTheNearMatchedRowSeparatelyCreatesADistinctChild() throws {
        let db = try makeTempDB()
        let household = whittington1871()
        _ = try db.addProfile(person("william", "William", "Gladwin", birthYear: 1833, gender: .male),
                              source: .gedcom)
        _ = try db.addProfile(person("hannah", "Hannah", "Gladwin", birthYear: 1836, gender: .female),
                              source: .gedcom)
        _ = try db.addProfile(person("thomas", "Thomas", "Gladwin", birthYear: 1861, gender: .male),
                              source: .gedcom)
        _ = try db.addProfile(person("james", "James", "Gladwin", birthYear: 1865, gender: .male),
                              source: .gedcom)
        _ = try db.addRelationship(spouseEdge("william", "hannah"))
        _ = try db.addRelationship(parentEdge("william", "thomas"))
        _ = try db.addRelationship(parentEdge("william", "james"))

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()
        let william = try #require(appState.snapshot.profiles["william"])
        let johnRow = try #require(household.first { $0.name == "John H Gladwin" })

        let result = appState.addCensusFamily(
            links: [CensusFamilyLinker.Link(member: johnRow, relation: .child)],
            subject: william, censusYear: 1871, sourceID: "census.1871",
            household: household, citationURL: nil)
        #expect(result.added == 1)

        let snap = appState.snapshot
        let john = try #require(snap.profiles.values.first { $0.firstName == "John" && !$0.isDeleted },
                                "John H is created as his own profile, not folded into Thomas")
        #expect(john.id != "thomas")
        #expect(john.birthDate?.bestYear == 1861)
        #expect(snap.parentsOf(john.id).contains { $0.id == "william" })
        // Thomas is untouched — the split adds a person, it never rewrites one.
        let thomas = try #require(snap.profiles["thomas"])
        #expect(thomas.firstName == "Thomas")
        #expect(thomas.birthDate?.bestYear == 1861)
    }
}
