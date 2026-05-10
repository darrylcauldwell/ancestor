import Testing
import Foundation
@testable import Ancestor_Research

/// Tests covering the `SourceDefaults` foundation (M16.5). These are
/// pure-function tests — no AppState, no DB. The wiring into
/// AddPersonView/AddFamilyView/OnboardingWizardBuilder is exercised
/// here via context construction.
struct SourceDefaultsTests {

    @Test func defaultSourceForHomePersonReturnsManualMemory() {
        let result = SourceDefaults.defaultSource(context: .homePerson)
        #expect(result == .manualMemory)
    }

    @Test func defaultSourceForGrandparentReturnsManualMemory() {
        let result = SourceDefaults.defaultSource(context: .grandparent)
        #expect(result == .manualMemory)
    }

    @Test func defaultSourceForRelativeOfManualPersonInheritsManual() {
        // Adding a relative of someone whose primary source is .manualDocument
        // should inherit Document — that's the whole point of context-aware
        // defaults: the user typed it once, we don't re-ask.
        let context = EntryContext.relativeOf(
            profileID: "p1",
            primarySource: .manualDocument
        )
        let result = SourceDefaults.defaultSource(context: context)
        #expect(result == .manualDocument)
    }

    @Test func defaultSourceForRelativeOfGEDCOMPersonReturnsManualMemory() {
        // GEDCOM-imported people hold .gedcom as their primary source. A
        // user-added relative of them ISN'T from the original GEDCOM file,
        // so we must not claim that — fall back to .manualMemory.
        let context = EntryContext.relativeOf(
            profileID: "p1",
            primarySource: .gedcom
        )
        let result = SourceDefaults.defaultSource(context: context)
        #expect(result == .manualMemory)
    }

    @Test func defaultSourceForSiblingInheritsExistingSiblingSource() {
        // Sibling shortcut: when the user is adding a sibling of someone
        // whose source is `.manualRecord`, the new sibling inherits it
        // because the same record (e.g. a census) usually lists them too.
        let context = EntryContext.sibling(of: "p1", inherited: .manualRecord)
        let result = SourceDefaults.defaultSource(context: context)
        #expect(result == .manualRecord)
    }
}
