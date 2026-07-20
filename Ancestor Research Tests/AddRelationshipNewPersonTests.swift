import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// AddRelationshipView.buildProfile — turns a census household member into a new
/// Profile ready to link (name split, shouty surname title-cased, gender from
/// sex column, calculated birth year).
@MainActor
struct AddRelationshipNewPersonTests {

    @Test func splitsNameAndTitleCasesSurname() {
        let p = AddRelationshipView.buildProfile(from: .init(
            name: "John Henry CAULDWELL", birthYear: 1881, birthPlace: "Turnditch", sex: "M"))
        #expect(p.firstName == "John Henry")
        #expect(p.lastName == "Cauldwell")
        #expect(p.gender == .male)
        #expect(p.birthLocation == "Turnditch")
    }

    @Test func birthYearIsCalculatedQualifier() {
        let p = AddRelationshipView.buildProfile(from: .init(
            name: "Robert CAULDWELL", birthYear: 1885, birthPlace: nil, sex: "M"))
        #expect(p.birthDate?.bestYear == 1885)
        #expect(p.birthDate?.qualifier == .calculated)   // CAL, ±1 — not asserted precise
    }

    @Test func femaleAndSingleName() {
        let p = AddRelationshipView.buildProfile(from: .init(
            name: "Martha", birthYear: nil, birthPlace: nil, sex: "F"))
        #expect(p.firstName == "Martha")
        #expect(p.lastName == nil)
        #expect(p.gender == .female)
        #expect(p.birthDate == nil)
    }

    @Test func unknownSexLeavesGenderNil() {
        let p = AddRelationshipView.buildProfile(from: .init(
            name: "Sam CAULDWELL", birthYear: nil, birthPlace: nil, sex: nil))
        #expect(p.gender == nil)
    }
}
