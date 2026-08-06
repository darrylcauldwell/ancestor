import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// PARISH_ABSORPTION_SPEC Change D — the relatives-offer half. A parish record
/// names family (a marriage's spouse + the subject's parents, a baptism's two
/// parents, a burial's "son of"/"dau of" parent); `parishFamilyLinks` lifts
/// exactly the subject's kin (never the other party's), and inherits an absent
/// surname the way the BMD parent path does.
struct ParishFamilyProposalTests {

    private func common(id: String, given: String, surname: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: "freereg", name: "\(given) \(surname)",
                     surname: surname, givenName: given, rawFields: [:])
    }

    private func subject(given: String, surname: String, gender: Gender) -> Profile {
        Profile(id: "subj", externalIDs: [:], firstName: given, middleName: nil,
                lastName: surname, marriedSurname: nil, gender: gender, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// Ernest Cauldwell × Mary Ward, 1915 — groom's father John (surname
    /// omitted in the register, shares the groom's), bride's father George Ward.
    private func marriage(subjectGiven: String = "Ernest", subjectSurname: String = "Cauldwell") -> ParishRecord {
        let m = FreeREGMarriage(
            groom: FreeREGPerson(forename: "Ernest", surname: "Cauldwell", occupation: "Collier"),
            bride: FreeREGPerson(forename: "Mary", surname: "Ward"),
            groomFather: FreeREGPerson(forename: "John", occupation: "Labourer"),
            brideFather: FreeREGPerson(forename: "George", surname: "Ward", occupation: "Labourer"),
            marriageDate: "30 Jan 1915")
        return ParishRecord(
            common: common(id: "m1", given: subjectGiven, surname: subjectSurname),
            eventType: "marriage", eventDate: "30 Jan 1915", eventYear: 1915,
            parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .marriage(m)))
    }

    @Test func marriageGroomSubjectProposesBrideAndGroomsFather() {
        let rec = marriage()
        let subj = subject(given: "Ernest", surname: "Cauldwell", gender: .male)
        let (links, kind) = AppState.parishFamilyLinks(subject: subj, record: rec, detail: rec.detail!)
        #expect(kind == .marriage)
        let spouse = links.first { $0.relation == .spouse }
        #expect(spouse?.given == "Mary")
        #expect(spouse?.birthSurname == "Ward")            // bride's MAIDEN surname
        #expect(spouse?.marriedSurname == "Cauldwell")     // her married name
        #expect(spouse?.gender == .female)
        let father = links.first { $0.relation == .parent }
        #expect(father?.given == "John")
        #expect(father?.birthSurname == "Cauldwell")        // inherited from subject
        #expect(father?.gender == .male)
        // The BRIDE's father (George Ward) is the spouse's kin, NOT proposed.
        #expect(!links.contains { $0.given == "George" })
    }

    @Test func marriageBrideSubjectIsSymmetric() {
        let rec = marriage(subjectGiven: "Mary", subjectSurname: "Ward")
        let subj = subject(given: "Mary", surname: "Ward", gender: .female)
        let (links, _) = AppState.parishFamilyLinks(subject: subj, record: rec, detail: rec.detail!)
        let spouse = links.first { $0.relation == .spouse }
        #expect(spouse?.given == "Ernest")
        #expect(spouse?.gender == .male)
        // Bride's father George Ward is now the subject's own parent.
        #expect(links.contains { $0.given == "George" && $0.relation == .parent })
        // Groom's father John is the spouse's kin now — not proposed.
        #expect(!links.contains { $0.given == "John" })
    }

    @Test func baptismProposesBothParents() {
        let bap = FreeREGBaptism(
            child: FreeREGPerson(forename: "Sarah", surname: "Ward"),
            father: FreeREGPerson(forename: "George", surname: "Ward", occupation: "Labourer"),
            mother: FreeREGMother(person: FreeREGPerson(forename: "Mary")))
        let rec = ParishRecord(
            common: common(id: "ba2", given: "Sarah", surname: "Ward"),
            eventType: "baptism", eventYear: 1888, parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .baptism(bap)))
        let subj = subject(given: "Sarah", surname: "Ward", gender: .female)
        let (links, kind) = AppState.parishFamilyLinks(subject: subj, record: rec, detail: rec.detail!)
        #expect(kind == .baptism)
        #expect(links.count == 2)
        #expect(links.contains { $0.given == "George" && $0.gender == .male })
        // Mother's maiden unknown → married name inherits the child's surname.
        let mother = links.first { $0.gender == .female }
        #expect(mother?.given == "Mary")
        #expect(mother?.marriedSurname == "Ward")
    }

    @Test func burialDauOfProposesParent() {
        let b = FreeREGBurial(
            deceased: FreeREGPerson(forename: "Ann", surname: "Smith", age: "4"),
            relationship: "dau of",
            relative: FreeREGPerson(forename: "John", surname: "Smith", sex: "M"))
        let rec = ParishRecord(
            common: common(id: "bu2", given: "Ann", surname: "Smith"),
            eventType: "burial", eventYear: 1880, parish: "Belper", county: "Derbyshire",
            detail: FreeREGDetail(event: .burial(b)))
        let subj = subject(given: "Ann", surname: "Smith", gender: .female)
        let (links, kind) = AppState.parishFamilyLinks(subject: subj, record: rec, detail: rec.detail!)
        #expect(kind == .burial)
        #expect(links.count == 1)
        #expect(links.first?.relation == .parent)
        #expect(links.first?.given == "John")
        #expect(links.first?.gender == .male)
    }

    @Test func burialWithoutParentRelationshipProposesNoParent() {
        // "wife of" is not a parent relationship — nothing proposed.
        let b = FreeREGBurial(
            deceased: FreeREGPerson(forename: "Ann", surname: "Smith"),
            relationship: "wife of",
            relative: FreeREGPerson(forename: "John", surname: "Smith"))
        let rec = ParishRecord(
            common: common(id: "bu3", given: "Ann", surname: "Smith"),
            eventType: "burial", eventYear: 1880, detail: FreeREGDetail(event: .burial(b)))
        let subj = subject(given: "Ann", surname: "Smith", gender: .female)
        let (links, _) = AppState.parishFamilyLinks(subject: subj, record: rec, detail: rec.detail!)
        #expect(links.isEmpty)
    }
}
