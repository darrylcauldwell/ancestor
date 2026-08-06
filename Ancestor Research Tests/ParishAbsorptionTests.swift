import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// PARISH_ABSORPTION_SPEC Changes A–C — a FreeREG parish register entry
/// carries a fully-typed payload (both spouses, both sets of parents,
/// occupations, abodes, church, witnesses) that, before this, evaporated on
/// apply. These tests pin the fact-level absorption: implied birth/death
/// dates (A), spouse-edge fill via a synthesized marriage (B), and derived
/// occupation/residence events (C).
struct ParishAbsorptionTests {

    // MARK: Fixtures

    private func common(id: String, given: String, surname: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: "freereg", name: "\(given) \(surname)",
                     surname: surname, givenName: given, rawFields: [:])
    }

    /// The Ernest Cauldwell × Mary Ward 1915 marriage (Kirk Ireton, Holy
    /// Trinity) — the record that motivated the spec.
    private func marriage(
        subjectGiven: String = "Ernest", subjectSurname: String = "Cauldwell",
        groomAge: String? = "26", brideAge: String? = "25",
        groomOccupation: String? = "Collier", groomAbode: String? = "Loscoe, Heanor",
        brideSurnamePresent: Bool = true
    ) -> ParishRecord {
        let marriage = FreeREGMarriage(
            groom: FreeREGPerson(forename: "Ernest", surname: "Cauldwell", age: groomAge,
                                 condition: "bachelor", occupation: groomOccupation, abode: groomAbode),
            bride: FreeREGPerson(forename: "Mary", surname: brideSurnamePresent ? "Ward" : nil,
                                 age: brideAge, condition: "spinster"),
            groomFather: FreeREGPerson(forename: "John", occupation: "Labourer"),
            brideFather: FreeREGPerson(forename: "George", surname: "Ward", occupation: "Labourer"),
            marriageDate: "30 Jan 1915")
        return ParishRecord(
            common: common(id: "m1", given: subjectGiven, surname: subjectSurname),
            eventType: "marriage", eventDate: "30 Jan 1915", eventYear: 1915,
            parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .marriage(marriage), churchName: "Holy Trinity"))
    }

    private func burial(age: String?, deathDate: String? = nil) -> ParishRecord {
        let burial = FreeREGBurial(
            deceased: FreeREGPerson(forename: "Ann", surname: "Smith", age: age),
            burialDate: "5 Mar 1880", deathDate: deathDate,
            causeOfDeath: "Consumption", placeOfDeath: "Belper")
        return ParishRecord(
            common: common(id: "bu1", given: "Ann", surname: "Smith"),
            eventType: "burial", eventDate: "5 Mar 1880", eventYear: 1880,
            parish: "Belper", county: "Derbyshire",
            detail: FreeREGDetail(event: .burial(burial)))
    }

    private func baptism(birthDate: String?) -> ParishRecord {
        let bap = FreeREGBaptism(
            child: FreeREGPerson(forename: "Sarah", surname: "Ward"),
            birthDate: birthDate, baptismDate: "12 Apr 1888")
        return ParishRecord(
            common: common(id: "ba1", given: "Sarah", surname: "Ward"),
            eventType: "baptism", eventDate: "12 Apr 1888", eventYear: 1888,
            parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .baptism(bap)))
    }

    // MARK: - Change A — implied dates

    @Test func marriageAgeImpliesCalculatedBirth() {
        // Groom aged 26 at the 1915 marriage → born 1888 or 1889 (calculated).
        let d = ApplyEngine.impliedBirthDate(for: .parish(marriage()))
        #expect(d?.earliest == 1888)
        #expect(d?.latest == 1889)
        #expect(d?.qualifier == .calculated)
    }

    @Test func marriageBrideSubjectResolvesBrideAge() {
        // A bride-subject record contributes the BRIDE's age (25), not the groom's.
        let rec = marriage(subjectGiven: "Mary", subjectSurname: "Ward")
        let d = ApplyEngine.impliedBirthDate(for: .parish(rec))
        #expect(d?.earliest == 1889)
        #expect(d?.latest == 1890)
    }

    @Test func marriageUnparseableAgeYieldsNoBirth() {
        let rec = marriage(groomAge: "full age")
        #expect(ApplyEngine.impliedBirthDate(for: .parish(rec)) == nil)
    }

    @Test func burialDeceasedAgeImpliesBirthAndDeathDate() {
        // Ann Smith, buried 1880 aged 70 → born ~1809–1810; death dated to burial.
        let rec = burial(age: "70")
        let birth = ApplyEngine.impliedBirthDate(for: .parish(rec))
        #expect(birth?.earliest == 1809)
        #expect(birth?.latest == 1810)
        let death = ApplyEngine.impliedDeathDate(for: .parish(rec))
        #expect(death?.latest == 1880)
    }

    @Test func burialPrefersExplicitDeathDate() {
        let rec = burial(age: "70", deathDate: "1 Mar 1880")
        let death = ApplyEngine.impliedDeathDate(for: .parish(rec))
        #expect(death?.original.contains("1880") == true)
    }

    @Test func baptismExplicitBirthDateIsPrecise() {
        // A late baptism records an explicit birth date — a precise birth.
        let d = ApplyEngine.impliedBirthDate(for: .parish(baptism(birthDate: "3 Jan 1888")))
        #expect(d?.earliest == 1888)
        #expect(d?.qualifier != .calculated)
    }

    @Test func baptismDateIsNeverTreatedAsBirthDate() {
        // No explicit birth_date → no implied birth (the baptism DATE is not one).
        #expect(ApplyEngine.impliedBirthDate(for: .parish(baptism(birthDate: nil))) == nil)
    }

    // MARK: - Change B — synthesized marriage → spouse edge

    @Test func groomSubjectSynthesizesBrideAsSpouse() {
        let synth = marriage().syntheticMarriageRecord
        #expect(synth?.spouseName == "Mary Ward")
        #expect(synth?.marriageYear == 1915)
        #expect(synth?.marriagePlace == "Kirk Ireton, Derbyshire")
    }

    @Test func brideSubjectSynthesizesGroomAsSpouse() {
        let synth = marriage(subjectGiven: "Mary", subjectSurname: "Ward").syntheticMarriageRecord
        #expect(synth?.spouseName == "Ernest Cauldwell")
    }

    @Test func forenameOnlySpouseStatesNoSpouseColumn() {
        // A forename-only other party can't be surname-matched to an edge, so
        // the stated spouse column stays nil (no spurious mismatch dispute).
        let synth = marriage(brideSurnamePresent: false).syntheticMarriageRecord
        #expect(synth?.spouseName == nil)
    }

    @Test func nonMarriageParishSynthesizesNoMarriage() {
        #expect(burial(age: "70").syntheticMarriageRecord == nil)
        #expect(baptism(birthDate: nil).syntheticMarriageRecord == nil)
    }

    @Test func absorptionPlanForParishMarriageEmitsSpouseEdge() {
        let plan = SourceRecord.parish(marriage()).absorptionPlan(profileID: "subj")
        let hasSpouseEdge = plan.contains { if case .spouseEdge = $0 { return true } else { return false } }
        #expect(hasSpouseEdge)
    }

    // MARK: - Change C — derived occupation / residence events

    @Test func marriagePrincipalOccupationAndAbodeBecomeEvents() {
        let events = SourceRecord.parish(marriage()).projectToLifeEvents(profileID: "subj")
        let occ = events.first { $0.type == .occupation }
        let res = events.first { $0.type == .residence }
        #expect(occ?.description == "Collier")
        #expect(occ?.date?.bestYear == 1915)
        #expect(res?.location == "Loscoe, Heanor")
        // Residence window closed to the wedding year.
        #expect(res?.endDate?.bestYear == 1915)
        // Distinct stable IDs — no collision with each other.
        #expect(occ?.id != res?.id)
    }

    @Test func brideSubjectContributesNoGroomOccupation() {
        // The bride's block has no occupation, so a bride-subject record
        // yields no occupation event from the groom's "Collier".
        let rec = marriage(subjectGiven: "Mary", subjectSurname: "Ward")
        let events = SourceRecord.parish(rec).projectToLifeEvents(profileID: "subj")
        #expect(events.first { $0.type == .occupation } == nil)
    }

    @Test func emptyOccupationAndAbodeYieldNoDerivedEvents() {
        let rec = marriage(groomOccupation: nil, groomAbode: nil)
        let events = SourceRecord.parish(rec).projectToLifeEvents(profileID: "subj")
        #expect(events.first { $0.type == .occupation } == nil)
        #expect(events.first { $0.type == .residence } == nil)
    }

    @Test func burialEventCarriesCauseAndPlaceInDescription() {
        let ev = SourceRecord.parish(burial(age: "70")).projectToLifeEvent(profileID: "subj")
        #expect(ev?.type == .burial)
        #expect(ev?.description?.contains("Consumption") == true)
        #expect(ev?.description?.contains("Belper") == true)
    }
}
