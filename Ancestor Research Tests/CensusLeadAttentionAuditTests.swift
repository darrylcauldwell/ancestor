import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Owner dogfood 2026-08-25 — Emma Gladwin's 1891 FreeCen record sat as an
/// UNAPPLIED lead from 21 Jul to 25 Aug while carrying a loaded household that
/// named an unrecorded sibling, an unrecorded grandchild (and so an unrecorded
/// married daughter), and a birthplace contradicting the tree. Nothing said so
/// anywhere: `censusUnabsorbed` fires on APPLIED evidence only.
struct CensusLeadAttentionAuditTests {

    private func member(
        _ name: String, _ relationship: String, age: Int?,
        birthPlace: String? = "Belper", isTarget: Bool? = nil
    ) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age,
                        birthPlace: birthPlace, isTarget: isTarget)
    }

    /// The 1891 roster: Emma with her mother (both on the tree), a sister and a
    /// grandson who are not.
    private func gladwinHousehold() -> [HouseholdMember] {
        [
            member("Sarah GLADWIN", "Head", age: 55),
            member("Emma GLADWIN", "Daur", age: 24, isTarget: true),
            member("Alice GLADWIN", "Daur", age: 17),
            member("John SMITH", "Grandson", age: 2),
        ]
    }

    private func censusLead(
        _ household: [HouseholdMember], censusYear: Int = 1891,
        verdict: RecordVerdict = .lead, userStatus: UserReviewStatus = .unreviewed,
        appliedAt: Date? = nil
    ) -> EvidenceRecord {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "fc1891", sourceID: "freecen", name: nil,
                                 surname: "GLADWIN", givenName: "EMMA",
                                 detailURL: "https://www.freecen.org.uk/1891/gladwin",
                                 rawFields: [:]),
            censusYear: censusYear, age: 24, birthPlace: "Belper",
            district: "Belper", household: household))
        return EvidenceRecord(
            id: "@EMMA@|fc1891", profileID: "@EMMA@", sourceID: "freecen",
            sourceRecordID: "fc1891", recordType: .census,
            verdict: verdict, record: record,
            citationFull: "FreeCen 1891, Belper", citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: userStatus,
            appliedAt: appliedAt,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "1891 census, Belper")
    }

    private func emma(birthLocation: String? = "Belper, Derbyshire") -> Profile {
        Profile(id: "@EMMA@", firstName: "Emma", lastName: "Gladwin", gender: .female,
                birthDate: GenealogicalDate(parsing: "1867"),
                birthLocation: birthLocation, isDeleted: false,
                sources: [:], disputes: [:])
    }

    private func sarah(birthLocation: String? = "Belper, Derbyshire") -> Profile {
        Profile(id: "@SARAH@", firstName: "Sarah", lastName: "Gladwin", gender: .female,
                birthDate: GenealogicalDate(parsing: "1836"),
                birthLocation: birthLocation, isDeleted: false,
                sources: [:], disputes: [:])
    }

    private func index(_ profiles: [Profile]) -> CensusLeadAttentionAudit.TreeIndex {
        CensusLeadAttentionAudit.TreeIndex(FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: []))
    }

    // MARK: - Kin the tree doesn't hold (gap-class)

    @Test func aLeadHouseholdNamingPeopleNotOnTheTreeRaisesAGap() {
        let subject = emma()
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold())],
            index: index([subject, sarah()]))

        #expect(results.count == 1)
        let finding = results.first
        #expect(finding?.ruleID == "censusLeadUnabsorbed")
        #expect(finding?.category == .gap,
                "evidence present but not carried across is a gap, not a wrong value")
        #expect(finding?.severity == .warning)
        #expect(finding?.message.contains("2 household members not on the tree") == true)
        #expect(finding?.message.contains("Alice GLADWIN") == true)
        #expect(finding?.message.contains("John SMITH") == true)
        #expect(finding?.message.contains("Sarah GLADWIN") == false,
                "the mother IS on the tree")
    }

    @Test func relativesAlreadyOnTheTreeAreNotCountedMissing() {
        let subject = emma()
        let alice = Profile(
            id: "@ALICE@", firstName: "Alice", lastName: "Gladwin", gender: .female,
            birthDate: GenealogicalDate(parsing: "1874"),
            birthLocation: "Belper, Derbyshire", isDeleted: false,
            sources: [:], disputes: [:])
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold())],
            index: index([subject, sarah(), alice]))

        #expect(results.count == 1)
        #expect(results.first?.message.contains("1 household member not on the tree") == true)
        #expect(results.first?.message.contains("Alice") == false)
    }

    // MARK: - Contradiction of an applied fact (issue-class)

    @Test func aLeadRowContradictingAnAppliedBirthplaceIsAnIssue() {
        // The tree (from GEDCOM) says Wirksworth; the roster row enumerates her
        // born Belper. One of the two is wrong and only a human can say which.
        let subject = emma(birthLocation: "Wirksworth, Derbyshire")
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold())],
            index: index([subject, sarah()]))

        let issue = results.first { $0.category == .issue }
        #expect(issue?.ruleID == "censusLeadContradiction")
        #expect(issue?.message.contains("Wirksworth") == true)
        #expect(issue?.message.contains("Belper") == true)
        #expect(issue?.relatedProfileIDs == ["@EMMA@"])
        #expect(results.contains { $0.category == .gap },
                "the unabsorbed kin are still their own finding")
    }

    @Test func aRelativesBirthplaceIsCheckedToo() {
        let subject = emma()
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold())],
            index: index([subject, sarah(birthLocation: "Ashbourne, Derbyshire")]))

        let issue = results.first { $0.category == .issue }
        #expect(issue?.relatedProfileIDs == ["@SARAH@"])
        #expect(issue?.message.contains("Sarah Gladwin") == true)
    }

    @Test func agreeingPlacesRaiseNoIssue() {
        // "Belper" vs "Belper, Derbyshire" is the same town with a county tail.
        let subject = emma()
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold())],
            index: index([subject, sarah()]))
        #expect(results.allSatisfy { $0.category == .gap })
    }

    // MARK: - What must stay silent

    @Test func anAppliedCensusIsTheOtherSweepsJob() {
        // `censusUnabsorbed` already covers applied evidence; two rules over
        // one household must not both fire.
        let subject = emma()
        let applied = censusLead(gladwinHousehold(),
                                 appliedAt: Date(timeIntervalSince1970: 100))
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [applied], index: index([subject, sarah()])).isEmpty)
    }

    @Test func aDiscardedLeadRaisesNothing() {
        let subject = emma()
        let discarded = censusLead(gladwinHousehold(), userStatus: .discarded)
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [discarded], index: index([subject, sarah()])).isEmpty)
    }

    @Test func anImpossibleVerdictRaisesNothing() {
        let subject = emma()
        let ruled = censusLead(gladwinHousehold(), verdict: .impossible)
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [ruled], index: index([subject, sarah()])).isEmpty)
    }

    /// The gate that keeps this from becoming noise: a lead is a PROPOSAL, so a
    /// roster that doesn't place the subject in the house is a namesake's
    /// family — flagging its members as "kin missing from the tree" would be
    /// pure invention.
    @Test func aNamesakeHouseholdWithoutTheSubjectIsSilent() {
        let subject = emma()
        let namesake = [
            member("Mary GLADWIN", "Head", age: 40, isTarget: true),
            member("Alice GLADWIN", "Daur", age: 17),
        ]
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(namesake)],
            index: index([subject, sarah()])).isEmpty)
    }

    @Test func servantsAndBoardersAreNotMissingKin() {
        let subject = emma()
        let withStaff = gladwinHousehold() + [
            member("Jane BROWN", "Servant", age: 19),
            member("Thomas WELCH", "Boarder", age: 30),
        ]
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(withStaff)],
            index: index([subject, sarah()]))

        #expect(results.count == 1)
        #expect(results.first?.message.contains("2 household members not on the tree") == true)
        #expect(results.first?.message.contains("Jane BROWN") == false)
        #expect(results.first?.message.contains("Thomas WELCH") == false)
    }

    /// A subject enumerated as a BOARDER is not in their own family's house, so
    /// the roster names nobody the tree is missing.
    @Test func aSubjectLodgingElsewhereIsSilent() {
        let subject = emma()
        let lodging = [
            member("William TAYLOR", "Head", age: 50),
            member("Emma GLADWIN", "Boarder", age: 24, isTarget: true),
        ]
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(lodging)],
            index: index([subject, sarah()])).isEmpty)
    }

    @Test func aRosterlessLeadRaisesNothing() {
        let subject = emma()
        #expect(CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead([])],
            index: index([subject, sarah()])).isEmpty)
    }

    // MARK: - An unapplied FACT is the same silence

    /// The condition is UNAPPLIED, not the verdict. A `.fact` census nobody has
    /// applied holds its household exactly as silently as a `.lead`.
    @Test func anUnappliedFactCensusIsCoveredToo() {
        let subject = emma()
        let results = CensusLeadAttentionAudit.findings(
            for: subject, evidence: [censusLead(gladwinHousehold(), verdict: .fact)],
            index: index([subject, sarah()]))
        #expect(results.contains { $0.ruleID == "censusLeadUnabsorbed" })
    }
}
