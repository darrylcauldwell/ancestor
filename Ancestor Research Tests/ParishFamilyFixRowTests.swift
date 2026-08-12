import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Pins the parish-family roster's role labelling — the small pure logic added
/// when the parish absorb offer was extracted into `ParishFamilyFixRow` (the
/// FreeREG twin of `CensusHouseholdFixRow`) and hosted in both the profile card
/// and the Health tab's `parishFamilyUnabsorbed` finding.
struct ParishFamilyFixRowTests {

    private func link(_ relation: AppState.ParishFamilyLink.Relation,
                      _ gender: Gender?) -> AppState.ParishFamilyLink {
        AppState.ParishFamilyLink(
            relation: relation, given: "Test", birthSurname: "Person",
            marriedSurname: nil, gender: gender)
    }

    @Test func roleWordSexesParentsAndNamesSpouse() {
        #expect(ParishFamilyFixRow.roleWord(link(.spouse, .female)) == "spouse")
        #expect(ParishFamilyFixRow.roleWord(link(.spouse, nil)) == "spouse")
        #expect(ParishFamilyFixRow.roleWord(link(.parent, .male)) == "father")
        #expect(ParishFamilyFixRow.roleWord(link(.parent, .female)) == "mother")
        // Unknown-gender parent falls back to the neutral word, never guesses.
        #expect(ParishFamilyFixRow.roleWord(link(.parent, nil)) == "parent")
    }

    @Test func displayNameJoinsGivenAndBestSurname() {
        #expect(link(.parent, .male).displayName == "Test Person")
    }
}
