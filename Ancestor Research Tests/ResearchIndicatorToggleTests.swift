import Testing
import Foundation
@testable import Ancestor_Research

/// M16.11 — pure tests of the `TreeIndicatorVisibility` gate. The Settings
/// toggle drives a single boolean across four indicator types; we cover
/// each combination so a bug in one branch can't be masked by tests on
/// another.
struct ResearchIndicatorToggleTests {

    private func makeFocusSet(profileIDs: [String]) -> FocusSet {
        FocusSet(
            id: UUID(), title: nil,
            profileIDs: profileIDs,
            createdAt: Date(), lastActiveAt: Date()
        )
    }

    @Test func treeNodeHidesNoteIconWhenIndicatorsOff() {
        #expect(
            TreeIndicatorVisibility.noteVisible(
                hasNote: true,
                showResearchIndicators: false
            ) == false
        )
    }

    @Test func treeNodeShowsNoteIconWhenIndicatorsOn() {
        #expect(
            TreeIndicatorVisibility.noteVisible(
                hasNote: true,
                showResearchIndicators: true
            ) == true
        )
    }

    @Test func treeNodeHidesQuestionIconWhenIndicatorsOff() {
        #expect(
            TreeIndicatorVisibility.questionVisible(
                hasOpenQuestion: true,
                showResearchIndicators: false
            ) == false
        )
    }

    @Test func treeNodeHidesFocusRingWhenIndicatorsOff() {
        let set = makeFocusSet(profileIDs: ["p1"])
        #expect(
            TreeIndicatorVisibility.focusRingVisible(
                nodeID: "p1",
                activeFocusSet: set,
                showResearchIndicators: false
            ) == false
        )
    }

    @Test func treeNodeShowsFocusRingWhenIndicatorsOnAndProfileInSet() {
        let set = makeFocusSet(profileIDs: ["p1"])
        #expect(
            TreeIndicatorVisibility.focusRingVisible(
                nodeID: "p1",
                activeFocusSet: set,
                showResearchIndicators: true
            ) == true
        )
    }

    @Test func treeNodeHidesTentativeGlyphWhenIndicatorsOff() {
        #expect(
            TreeIndicatorVisibility.tentativeVisible(
                hasTentativeFact: true,
                showResearchIndicators: false
            ) == false
        )
    }
}
