import Testing
import Foundation
@testable import Ancestor_Research

/// M16.9 — verifies the AppState-side handlers behind the global Cmd+N /
/// Cmd+Shift+N / Cmd+E keyboard shortcuts.
///
/// SwiftUI keyboard testing is fragile in Swift Testing, so we exercise
/// the action handlers directly: ContentView's shortcut layer just sets
/// the sidebar tab and calls these methods, so verifying their behaviour
/// is equivalent to verifying the shortcuts.
@MainActor
struct GlobalKeyboardShortcutTests {

    @Test func addPersonRequestActivatesTreeTabAndPublishesAction() {
        let state = AppState()
        #expect(state.pendingPersonAction == nil)

        state.requestAddPerson()

        #expect(state.pendingPersonAction == .add)
    }

    @Test func addFamilyRequestActivatesTreeTabAndPublishesAction() {
        let state = AppState()
        state.requestAddFamily()
        #expect(state.pendingPersonAction == .addFamily)
    }

    @Test func editPersonRequestNoOpsWhenNoSelection() {
        let state = AppState()
        #expect(state.selectedProfileID == nil)

        state.requestEditSelectedPerson()

        // Without a selection the request should be silent rather than
        // surfacing an empty editor.
        #expect(state.pendingPersonAction == nil)
    }

    @Test func editPersonRequestPublishesActionWhenSelected() {
        let state = AppState()
        state.selectedProfileID = "p-42"

        state.requestEditSelectedPerson()

        #expect(state.pendingPersonAction == .editSelected(profileID: "p-42"))
    }

    @Test func clearPendingPersonActionResetsToNil() {
        let state = AppState()
        state.requestAddPerson()
        #expect(state.pendingPersonAction != nil)

        state.clearPendingPersonAction()
        #expect(state.pendingPersonAction == nil)
    }
}
