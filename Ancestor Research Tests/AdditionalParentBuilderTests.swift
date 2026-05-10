import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the M17.1 wizard "Add stepparent" extension.
/// Verifies that `OnboardingWizardBuilder.Input.stepparent` round-trips into a
/// third parent edge with `RelationshipSubtype.step`, while leaving the default
/// two-parent flow untouched.
struct AdditionalParentBuilderTests {

    private func person(
        first: String = "",
        last: String = "",
        gender: Gender? = nil
    ) -> OnboardingWizardBuilder.PersonInput {
        OnboardingWizardBuilder.PersonInput(
            firstName: first, lastName: last, gender: gender,
            birthDateText: "", birthLocation: ""
        )
    }

    private func baseInput(_ you: OnboardingWizardBuilder.PersonInput)
        -> OnboardingWizardBuilder.Input
    {
        var input = OnboardingWizardBuilder.Input.blank
        input.you = you
        return input
    }

    @Test func wizardBuilderProducesThreeParentRelationshipsWhenStepparentProvided() {
        var input = baseInput(person(first: "Alice"))
        input.father = person(first: "Bob", last: "Cauldwell", gender: .male)
        input.mother = person(first: "Carol", last: "Smith", gender: .female)
        input.stepparent = person(first: "Steve", last: "Jones", gender: .male)

        let result = OnboardingWizardBuilder.build(input)!

        let parentEdges = result.relationships.filter { $0.type == .parent }
        #expect(parentEdges.count == 3)

        let stepEdges = parentEdges.filter { $0.subtype == .step }
        #expect(stepEdges.count == 1)
        // The step edge should land on the home person.
        #expect(stepEdges.first?.to == result.homePersonID)
    }

    @Test func wizardBuilderProducesTwoParentRelationshipsByDefault() {
        var input = baseInput(person(first: "Alice"))
        input.father = person(first: "Bob")
        input.mother = person(first: "Carol")
        // stepparent left nil

        let result = OnboardingWizardBuilder.build(input)!

        let parentEdges = result.relationships.filter { $0.type == .parent }
        #expect(parentEdges.count == 2)
        #expect(parentEdges.allSatisfy { $0.subtype != .step })
    }

    @Test func addingStepparentInWizardEmitsCorrectStateUpdate() {
        // Start from blank input — mimic the user opening the wizard.
        var input = baseInput(person(first: "Alice"))
        #expect(input.stepparent == nil)

        // User taps "Add stepparent" — wizard appends a blank PersonInput.
        input.stepparent = person()
        // Empty stepparent → builder must NOT emit a third edge.
        var resultEmpty = OnboardingWizardBuilder.build(input)!
        #expect(resultEmpty.relationships.filter { $0.type == .parent }.isEmpty)

        // User fills in details → builder emits the third edge.
        input.stepparent = person(first: "Steve", gender: .male)
        let resultPopulated = OnboardingWizardBuilder.build(input)!
        let stepEdges = resultPopulated.relationships.filter { $0.subtype == .step }
        #expect(stepEdges.count == 1)
        #expect(stepEdges.first?.role == .father)

        // User removes stepparent again — clearing the slot drops the edge.
        input.stepparent = nil
        resultEmpty = OnboardingWizardBuilder.build(input)!
        #expect(resultEmpty.relationships.filter { $0.subtype == .step }.isEmpty)
    }
}
