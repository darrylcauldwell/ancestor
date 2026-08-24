import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// #25 — display-time contradiction of Triage leads against the subject's
/// CURRENT applied vitals. Driver (owner dogfood 2026-08-24): John Wheeldon
/// sr's 1891 census lead was scored 6 Aug, his Sep 1881 death applied 17 Aug
/// — the lead sat in Triage asserting a census for a man ten years dead.
struct LeadContradictionCheckTests {

    private func profile(birth: String? = nil, death: String? = nil) -> Profile {
        var p = Profile(
            id: "p1", externalIDs: [:], firstName: "John", middleName: nil,
            lastName: "Wheeldon", gender: .male, isDeleted: false,
            sources: [:], disputes: [:])
        p.birthDate = birth.flatMap { GenealogicalDate(parsing: $0) }
        p.deathDate = death.flatMap { GenealogicalDate(parsing: $0) }
        return p
    }

    private func lead(id: String = "lead_x", evidence: String,
                      relationship: String? = nil, deathYear: Int? = nil) -> Lead {
        Lead(id: id, profileID: "p1", name: "John Wheeldon",
             surname: "Wheeldon", givenName: "John",
             birthYear: nil, deathYear: deathYear, ageAtDeath: nil, place: nil,
             relationship: relationship, source: .scoredLead, status: .new,
             evidence: evidence, createdAt: Date(),
             investigatedAt: nil, resolvedAt: nil, resolution: nil)
    }

    @Test func censusAfterAppliedDeathIsContradicted() {
        let reason = LeadContradictionCheck.contradiction(
            lead: lead(evidence: "1891 census, Idridgehay"),
            profile: profile(death: "Sep 1881"))
        #expect(reason != nil)
        #expect(reason?.contains("1881") == true)
    }

    @Test func censusBeforeDeathIsFine() {
        #expect(LeadContradictionCheck.contradiction(
            lead: lead(evidence: "1871 census, Holloway"),
            profile: profile(death: "Sep 1881")) == nil)
    }

    @Test func deathLeadFarFromAppliedDeathIsContradicted() {
        let reason = LeadContradictionCheck.contradiction(
            lead: lead(evidence: "death registered 1929", deathYear: 1929),
            profile: profile(death: "Sep 1881"))
        #expect(reason != nil)
    }

    @Test func matchingDeathLeadIsFine() {
        #expect(LeadContradictionCheck.contradiction(
            lead: lead(evidence: "death registered 1881", deathYear: 1881),
            profile: profile(death: "Sep 1881")) == nil)
    }

    @Test func censusPredatingBirthIsContradicted() {
        let reason = LeadContradictionCheck.contradiction(
            lead: lead(evidence: "1841 census, Derby"),
            profile: profile(birth: "9 Sep 1848"))
        #expect(reason != nil)
        #expect(reason?.contains("predates") == true)
    }

    @Test func noAppliedVitalsMeansNoContradiction() {
        #expect(LeadContradictionCheck.contradiction(
            lead: lead(evidence: "1891 census, Idridgehay"),
            profile: profile()) == nil)
        #expect(LeadContradictionCheck.contradiction(
            lead: lead(evidence: "1891 census"), profile: nil) == nil)
    }

    @Test func householdLeadYearComesFromTheIDSuffix() {
        #expect(LeadContradictionCheck.eventYear(
            of: lead(id: "lead_hh_KEZIA_WHEELDON_1891", evidence: "Dau in census, age 29"))
            == 1891)
    }

    @Test func burialLeadEvidenceClassifiesAsDeathShaped() {
        #expect(LeadContradictionCheck.eventKind(
            of: lead(evidence: "Keziah Wheeldon, Leek Cemetery burial")) == "death")
    }
}
