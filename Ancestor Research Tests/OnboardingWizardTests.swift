import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for OnboardingWizardBuilder — the pure logic that turns wizard
/// input into the (profiles, relationships) tuple AppState.addFamily uses.
struct OnboardingWizardTests {

    private func empty() -> OnboardingWizardBuilder.PersonInput {
        OnboardingWizardBuilder.PersonInput(
            firstName: "", lastName: "", gender: nil,
            birthDateText: "", birthLocation: ""
        )
    }

    private func person(
        first: String = "",
        last: String = "",
        gender: Gender? = nil,
        birth: String = "",
        location: String = ""
    ) -> OnboardingWizardBuilder.PersonInput {
        OnboardingWizardBuilder.PersonInput(
            firstName: first, lastName: last, gender: gender,
            birthDateText: birth, birthLocation: location
        )
    }

    private func baseInput(_ you: OnboardingWizardBuilder.PersonInput)
        -> OnboardingWizardBuilder.Input
    {
        var input = OnboardingWizardBuilder.Input.blank
        input.you = you
        return input
    }

    // MARK: - Minimum data

    @Test func build_returnsNilWhenYouAreEmpty() {
        let result = OnboardingWizardBuilder.build(.blank)
        #expect(result == nil)
    }

    @Test func build_acceptsMinimalYou() {
        let input = baseInput(person(first: "Alice"))
        let result = OnboardingWizardBuilder.build(input)
        #expect(result != nil)
        #expect(result?.profiles.count == 1)
        #expect(result?.profiles.first?.firstName == "Alice")
    }

    @Test func build_setsHomePersonIDToYou() {
        let input = baseInput(person(first: "Alice"))
        let result = OnboardingWizardBuilder.build(input)
        #expect(result?.homePersonID == result?.profiles.first?.id)
    }

    // MARK: - Parents

    @Test func build_createsParentEdges() {
        var input = baseInput(person(first: "Alice", last: "Cauldwell"))
        input.father = person(first: "Bob", last: "Cauldwell")
        input.mother = person(first: "Carol", last: "Smith")

        let result = OnboardingWizardBuilder.build(input)!
        #expect(result.profiles.count == 3)
        // Two parent edges + one spouse edge
        let parentEdges = result.relationships.filter { $0.type == .parent }
        #expect(parentEdges.count == 2)
        let spouseEdges = result.relationships.filter { $0.type == .spouse }
        #expect(spouseEdges.count == 1)
    }

    @Test func build_skippedFatherStillCreatesMotherEdge() {
        var input = baseInput(person(first: "Alice"))
        input.mother = person(first: "Carol")
        // father left empty

        let result = OnboardingWizardBuilder.build(input)!
        #expect(result.profiles.count == 2)
        let parentEdges = result.relationships.filter { $0.type == .parent }
        #expect(parentEdges.count == 1)
        // No spouse edge because there's only one parent
        let spouseEdges = result.relationships.filter { $0.type == .spouse }
        #expect(spouseEdges.isEmpty)
    }

    @Test func build_adoptedStructureMarksParentEdgeAsAdoptive() {
        var input = baseInput(person(first: "Alice"))
        input.structure = .adopted
        input.father = person(first: "Adoptive", last: "Father")

        let result = OnboardingWizardBuilder.build(input)!
        let parentEdge = result.relationships.first { $0.type == .parent }
        #expect(parentEdge?.subtype == .adoptive)
    }

    @Test func build_marriageDateAttachesToSpouseEdge() {
        var input = baseInput(person(first: "Alice"))
        input.father = person(first: "Bob")
        input.mother = person(first: "Carol")
        input.marriageDateText = "1965"

        let result = OnboardingWizardBuilder.build(input)!
        let spouseEdge = result.relationships.first { $0.type == .spouse }
        #expect(spouseEdge?.marriageDate?.bestYear == 1965)
    }

    // MARK: - Grandparents

    @Test func build_paternalGrandparentsAttachToFather() {
        var input = baseInput(person(first: "Alice"))
        input.father = person(first: "Bob")
        input.paternalGrandfather = person(first: "Granddad")
        input.paternalGrandmother = person(first: "Grandma")

        let result = OnboardingWizardBuilder.build(input)!
        // 4 profiles: you, father, paternal grandfather, paternal grandmother
        #expect(result.profiles.count == 4)

        let father = result.profiles.first { $0.firstName == "Bob" }!
        let edgesToFather = result.relationships.filter { $0.type == .parent && $0.to == father.id }
        #expect(edgesToFather.count == 2)
    }

    @Test func build_grandparentsRequireParent() {
        // Skipping the father but providing his parents — those grandparents
        // have nowhere to attach, so they must NOT be created.
        var input = baseInput(person(first: "Alice"))
        // father empty
        input.paternalGrandfather = person(first: "Orphan")

        let result = OnboardingWizardBuilder.build(input)!
        #expect(result.profiles.count == 1)
    }

    @Test func build_maternalGrandparentsAttachToMother() {
        var input = baseInput(person(first: "Alice"))
        input.mother = person(first: "Carol")
        input.maternalGrandfather = person(first: "Mat-GF")

        let result = OnboardingWizardBuilder.build(input)!
        let mother = result.profiles.first { $0.firstName == "Carol" }!
        let parentEdgesOfMother = result.relationships.filter { $0.type == .parent && $0.to == mother.id }
        #expect(parentEdgesOfMother.count == 1)
    }

    // MARK: - Step 4 family

    @Test func build_includeSpouseAndChildren_creates_spouse_and_children() {
        var input = baseInput(person(first: "Alice"))
        input.includeSpouseAndChildren = true
        input.spouse = person(first: "David")
        input.children = [person(first: "Tom"), person(first: "Sue")]

        let result = OnboardingWizardBuilder.build(input)!
        // you + spouse + 2 children = 4
        #expect(result.profiles.count == 4)

        // Each child has 2 parent edges (Alice + David)
        let children = result.profiles.filter { ["Tom", "Sue"].contains($0.firstName ?? "") }
        for child in children {
            let parents = result.relationships.filter { $0.type == .parent && $0.to == child.id }
            #expect(parents.count == 2)
        }
    }

    @Test func build_excludeStep4_omitsSpouseAndChildren() {
        var input = baseInput(person(first: "Alice"))
        input.includeSpouseAndChildren = false
        input.spouse = person(first: "Ignored")
        input.children = [person(first: "AlsoIgnored")]

        let result = OnboardingWizardBuilder.build(input)!
        #expect(result.profiles.count == 1)
    }

    @Test func build_emptyChildrenSkippedEvenWhenIncluded() {
        var input = baseInput(person(first: "Alice"))
        input.includeSpouseAndChildren = true
        input.spouse = person(first: "David")
        input.children = [empty(), person(first: "Tom"), empty()]

        let result = OnboardingWizardBuilder.build(input)!
        let childNames = result.profiles.compactMap(\.firstName).filter { $0 == "Tom" }
        #expect(childNames.count == 1)
    }

    // MARK: - Atomicity round-trip

    @Test func wizardOutput_persistsThroughAddFamily() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)

        var input = baseInput(person(first: "Alice", last: "Cauldwell"))
        input.father = person(first: "Bob", last: "Cauldwell")
        input.mother = person(first: "Carol", last: "Smith")

        let result = OnboardingWizardBuilder.build(input)!
        let tx = try db.addFamily(
            profiles: result.profiles,
            relationships: result.relationships,
            source: .manualMemory
        )
        let snap = try db.buildSnapshot()
        #expect(snap.profiles.count == 3)
        #expect(snap.relationships.count == 3)

        // Single undo removes everything.
        try db.undoStructural(transactionID: tx.id)
        let after = try db.buildSnapshot()
        #expect(after.profiles.isEmpty)
        #expect(after.relationships.isEmpty)
    }
}
