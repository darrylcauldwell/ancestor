import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `ResearchFocus` and its plumbing into `ResearchState.init`.
/// Pure-function — no DB, no view. Covers the two contracts the rest of
/// the engine relies on:
///   1. Each focus maps to a non-empty `recordTypes` set with no overlap
///      surprises across cases.
///   2. `ResearchState.init(subject:)` honours `subject.focus` when set
///      and falls back to the full default set when not.
///   3. `CompletenessCheck.researchFocus` maps the engine-researchable
///      gaps and returns nil for identity / structural fields.
///
/// `@MainActor` because `ResearchState` (and the `ResearchSubject`
/// initializer it consumes) inherit MainActor isolation from the
/// project's Swift 6.2 default — see the user-level Swift conventions
/// in `~/.claude/CLAUDE.md`.
@MainActor
struct ResearchFocusTests {

    // MARK: - Record-type mapping

    @Test func parentsFocusCoversBirthCensusAndBaptism() {
        #expect(ResearchFocus.parents.recordTypes == [.birth, .census, .baptism])
    }

    @Test func deathFocusCoversAllDeathShapeSources() {
        #expect(ResearchFocus.death.recordTypes == [.death, .burial, .probate, .military])
    }

    @Test func everyFocusYieldsNonEmptyRecordTypes() {
        // Empty record-type sets would silently disable the run with no
        // diagnostic — defensive check so adding a new focus case can't
        // ship a no-op by accident.
        for focus in ResearchFocus.allCases {
            #expect(!focus.recordTypes.isEmpty, "\(focus) has empty record types")
        }
    }

    // MARK: - ResearchState honours focus

    private func subject(focus: ResearchFocus?) -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell", givenName: "Ernest",
            mode: .extend, focus: focus,
            homeChapmanCode: "DBY"
        )
    }

    @Test func researchStateUsesFullDefaultSetWhenFocusNil() {
        let state = ResearchState(subject: subject(focus: nil))
        let expected: Set<RecordType> = [.birth, .death, .marriage, .census, .burial, .probate, .parish, .pedigree]
        #expect(state.activeRecordTypes == expected)
    }

    @Test func researchStateNarrowsToFocusWhenSet() {
        let state = ResearchState(subject: subject(focus: .siblings))
        #expect(state.activeRecordTypes == [.birth])
    }

    @Test func researchStateNarrowsDeathFocusToDeathShapeTypesOnly() {
        // Regression catcher for the macro shape — `.death` covers more
        // than one record type and the state init must respect all of
        // them, not just .death.
        let state = ResearchState(subject: subject(focus: .death))
        #expect(state.activeRecordTypes == [.death, .burial, .probate, .military])
        #expect(!state.activeRecordTypes.contains(.census),
                "Death focus should not pull census — that's an occupation/parents path")
    }

    // MARK: - CompletenessCheck → ResearchFocus mapping

    @Test func hasParentsGapMapsToParentsFocus() {
        #expect(CompletenessCheck.hasParents.researchFocus == .parents)
    }

    @Test func deathFieldGapsMapToDeathFocus() {
        #expect(CompletenessCheck.field(.deathDate).researchFocus == .death)
        #expect(CompletenessCheck.field(.deathLocation).researchFocus == .death)
    }

    @Test func birthFieldGapsMapToBirthFocus() {
        #expect(CompletenessCheck.field(.birthDate).researchFocus == .birth)
        #expect(CompletenessCheck.field(.birthLocation).researchFocus == .birth)
    }

    @Test func mothersMaidenNameMapsToParentsFocus() {
        // MMN comes from the subject's own birth record's MMN field —
        // researching it is a parent-shape problem.
        #expect(CompletenessCheck.field(.mothersMaidenName).researchFocus == .parents)
    }

    @Test func identityFieldsReturnNilFocus() {
        // Names / gender / bio aren't engine-researchable — the UI
        // surfaces them with a "Manual" placeholder rather than a
        // promise the engine can't keep.
        let untargetable: [CompletenessCheck] = [
            .field(.firstName), .field(.lastName), .field(.middleName),
            .field(.nickName), .field(.gender), .field(.bio)
        ]
        for gap in untargetable {
            #expect(gap.researchFocus == nil, "\(gap) should not have a research focus")
        }
    }
}
