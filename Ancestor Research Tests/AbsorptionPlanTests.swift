import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EVIDENCE_ABSORPTION_SPEC Change 4 — `absorptionPlan` is the single
/// enumeration of what a record absorbs. The write path executes it and
/// (Change 5) the review preview displays it, so these tests pin the contract
/// both sides depend on. Behaviour parity with the old switch is covered by
/// the full apply suite staying green; here we assert the plan's *shape*.
struct AbsorptionPlanTests {

    private func common(_ id: String, _ src: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: src, rawFields: [:])
    }

    private func dateFields(_ plan: [Absorption]) -> [ProfileField] {
        plan.compactMap { if case .dateField(let f, _) = $0 { f } else { nil } }
    }
    private func stringFields(_ plan: [Absorption]) -> [ProfileField] {
        plan.compactMap { if case .stringField(let f, _) = $0 { f } else { nil } }
    }
    private func eventTypes(_ plan: [Absorption]) -> [LifeEventType] {
        plan.compactMap { if case .lifeEvent(let e) = $0 { e.type } else { nil } }
    }
    private func hasSpouseEdge(_ plan: [Absorption]) -> Bool {
        plan.contains { if case .spouseEdge = $0 { true } else { false } }
    }

    @Test func censusPlanRoutesEveryNuggetToItsHome() {
        let plan = SourceRecord.census(CensusRecord(
            common: common("c", "freecen"), censusYear: 1891,
            birthYear: 1888, birthPlace: "Alport", birthCounty: "Derbyshire",
            occupation: "Colliery electrician", address: "3 Mill Lane"))
            .absorptionPlan(profileID: "p")

        #expect(stringFields(plan) == [.birthLocation])          // Change 1
        #expect(dateFields(plan) == [.birthDate])                // Change 3 corroboration
        #expect(Set(eventTypes(plan)) == [.census, .occupation, .residence])  // Change 2
        #expect(!hasSpouseEdge(plan))
    }

    @Test func birthPlanIsIdentityFieldsOnly() {
        let plan = SourceRecord.birth(BirthRecord(
            common: common("b", "freebmd"), birthYear: 1888, birthPlace: "Bakewell"))
            .absorptionPlan(profileID: "p")
        #expect(dateFields(plan) == [.birthDate])
        #expect(stringFields(plan) == [.birthLocation])
        #expect(eventTypes(plan).isEmpty)   // BMD facts live on the profile, not the timeline
    }

    @Test func marriagePlanIsSpouseEdgeOnly() {
        let plan = SourceRecord.marriage(MarriageRecord(
            common: common("m", "freebmd"), marriageYear: 1916, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Bakewell", volume: nil, page: nil,
            spouseName: "Marshall")).absorptionPlan(profileID: "p")
        #expect(hasSpouseEdge(plan))
        #expect(dateFields(plan).isEmpty && stringFields(plan).isEmpty)
        #expect(eventTypes(plan).isEmpty)
    }

    @Test func burialPlanCorroboratesBothDatesAndAddsEvent() {
        // FindAGrave: previously wrote nothing to profile fields.
        let plan = SourceRecord.burial(BurialRecord(
            common: common("g", "findagrave"),
            deathDate: "3 Jan 1951", birthDate: "15 Mar 1888",
            burialLocation: "Youlgreave", isVeteran: false))
            .absorptionPlan(profileID: "p")
        #expect(Set(dateFields(plan)) == [.birthDate, .deathDate])
        #expect(eventTypes(plan) == [.burial])
    }
}
