import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the pure logic backing AddPersonView/EditPersonView:
/// AutoSuggestService and the date parse preview wiring.
struct ManualEntryViewTests {

    private func makeProfile(
        id: String = UUID().uuidString,
        firstName: String? = nil,
        lastName: String? = nil,
        gender: Gender? = nil,
        birthLocation: String? = nil,
        deathLocation: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: gender,
            attributes: nil,
            birthDate: nil, birthLocation: birthLocation,
            deathDate: nil, deathLocation: deathLocation,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private func snapshot(_ profiles: [Profile], _ relationships: [Relationship] = []) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    // MARK: - Surname suggestions

    @Test func surnames_siblingShortcut_returnsExistingSurname() {
        let sibling = makeProfile(id: "p1", firstName: "Anne", lastName: "Cauldwell")
        let snap = snapshot([sibling])
        let result = AutoSuggestService.surnames(contextID: "p1", relation: .sibling, snapshot: snap)
        #expect(result == ["Cauldwell"])
    }

    @Test func surnames_childOfContext_returnsContextSurname() {
        let parent = makeProfile(id: "p1", firstName: "John", lastName: "Smith")
        let snap = snapshot([parent])
        let result = AutoSuggestService.surnames(contextID: "p1", relation: .child, snapshot: snap)
        #expect(result == ["Smith"])
    }

    @Test func surnames_spouseOfContext_returnsEmpty() {
        // Spouse comes from a different family — don't suggest the partner's surname.
        let partner = makeProfile(id: "p1", firstName: "John", lastName: "Smith")
        let snap = snapshot([partner])
        let result = AutoSuggestService.surnames(contextID: "p1", relation: .spouse, snapshot: snap)
        #expect(result.isEmpty)
    }

    @Test func surnames_noContext_returnsMostCommon() {
        let p1 = makeProfile(id: "1", lastName: "Smith")
        let p2 = makeProfile(id: "2", lastName: "Smith")
        let p3 = makeProfile(id: "3", lastName: "Jones")
        let snap = snapshot([p1, p2, p3])
        let result = AutoSuggestService.surnames(contextID: nil, relation: .none, snapshot: snap)
        #expect(result.first == "Smith")
        #expect(result.contains("Jones"))
    }

    @Test func surnames_emptyTree_returnsEmpty() {
        let result = AutoSuggestService.surnames(
            contextID: nil, relation: .none, snapshot: .empty
        )
        #expect(result.isEmpty)
    }

    @Test func surnames_contextWithNoSurname_fallsBackToMostCommon() {
        let unnamed = makeProfile(id: "p1", firstName: "Mystery", lastName: nil)
        let other = makeProfile(id: "p2", lastName: "Brown")
        let snap = snapshot([unnamed, other])
        let result = AutoSuggestService.surnames(contextID: "p1", relation: .child, snapshot: snap)
        #expect(result == ["Brown"])
    }

    // MARK: - Location suggestions

    @Test func locations_returnsByFrequency() {
        let p1 = makeProfile(id: "1", birthLocation: "Derby, England")
        let p2 = makeProfile(id: "2", birthLocation: "Derby, England")
        let p3 = makeProfile(id: "3", birthLocation: "London, England")
        let snap = snapshot([p1, p2, p3])
        let result = AutoSuggestService.locations(snapshot: snap)
        #expect(result.first == "Derby, England")
        #expect(result.contains("London, England"))
    }

    @Test func locations_includesDeathLocations() {
        let p1 = makeProfile(id: "1", birthLocation: "York", deathLocation: "York")
        let snap = snapshot([p1])
        let result = AutoSuggestService.locations(snapshot: snap)
        #expect(result == ["York"])
    }

    @Test func locations_emptyTree_returnsEmpty() {
        let result = AutoSuggestService.locations(snapshot: .empty)
        #expect(result.isEmpty)
    }

    @Test func locations_skipsEmptyStrings() {
        let p1 = makeProfile(id: "1", birthLocation: "")
        let snap = snapshot([p1])
        let result = AutoSuggestService.locations(snapshot: snap)
        #expect(result.isEmpty)
    }

    // MARK: - Name normalisation

    @Test func normaliseName_trimsWhitespace() {
        #expect(AutoSuggestService.normaliseName("  John  ") == "John")
    }

    @Test func normaliseName_collapsesInternalSpaces() {
        #expect(AutoSuggestService.normaliseName("John   van  Buren") == "John van Buren")
    }

    @Test func normaliseName_emptyReturnsNil() {
        #expect(AutoSuggestService.normaliseName("") == nil)
        #expect(AutoSuggestService.normaliseName("   ") == nil)
    }

    @Test func normaliseName_preservesCapitalisation() {
        // "de la Cruz" must round-trip unchanged — we don't impose capitalisation rules.
        #expect(AutoSuggestService.normaliseName("de la Cruz") == "de la Cruz")
        #expect(AutoSuggestService.normaliseName("MacDonald") == "MacDonald")
    }

    // MARK: - Minimum data validation

    @Test func hasMinimumData_acceptsFirstNameOnly() {
        #expect(AutoSuggestService.hasMinimumData(firstName: "John", lastName: nil, birthYear: nil))
    }

    @Test func hasMinimumData_acceptsLastNameOnly() {
        #expect(AutoSuggestService.hasMinimumData(firstName: nil, lastName: "Smith", birthYear: nil))
    }

    @Test func hasMinimumData_acceptsBirthYearOnly() {
        // "Mother of John, b. 1820, name unknown" — valid genealogical entry.
        #expect(AutoSuggestService.hasMinimumData(firstName: nil, lastName: nil, birthYear: 1820))
    }

    @Test func hasMinimumData_rejectsAllNil() {
        #expect(!AutoSuggestService.hasMinimumData(firstName: nil, lastName: nil, birthYear: nil))
    }

    @Test func hasMinimumData_rejectsEmptyStrings() {
        #expect(!AutoSuggestService.hasMinimumData(firstName: "", lastName: "", birthYear: nil))
    }

    // MARK: - Date parse preview integration

    @Test func parsePreview_emptyInput_emitsEmptyPreview() {
        let result = GenealogicalDate.parsePreview("")
        #expect(result.displayText.isEmpty)
        #expect(result.isValid)
        #expect(result.parsed == nil)
    }

    @Test func parsePreview_validYear_emitsParsedDate() {
        let result = GenealogicalDate.parsePreview("1887")
        #expect(result.isValid)
        #expect(result.parsed?.bestYear == 1887)
    }

    @Test func parsePreview_invalidInput_marksInvalid() {
        let result = GenealogicalDate.parsePreview("nonsense")
        #expect(!result.isValid)
        #expect(result.parsed == nil)
    }
}
