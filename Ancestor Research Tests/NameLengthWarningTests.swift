import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the 100-char soft warning helper (M17.3, DESIGN.md §7.5.3).
struct NameLengthWarningTests {

    @Test func nameWarningNilBelow100() {
        // A normal name — no warning surfaces.
        #expect(NameLengthWarning.warningText(forName: "Margaret") == nil)
        // 99 trimmed chars — still under the threshold.
        let almost = String(repeating: "a", count: 99)
        #expect(NameLengthWarning.warningText(forName: almost) == nil)
        // Empty / nil inputs — no warning.
        #expect(NameLengthWarning.warningText(forName: "") == nil)
        #expect(NameLengthWarning.warningText(forName: nil) == nil)
        // Whitespace-only is trimmed to zero length — no warning.
        #expect(NameLengthWarning.warningText(forName: "   ") == nil)
    }

    @Test func nameWarningPresentAt100() {
        // 100 trimmed chars triggers the warning at the lower edge.
        let exact = String(repeating: "b", count: 100)
        let warning = NameLengthWarning.warningText(forName: exact)
        #expect(warning == "Names this long are unusual — double-check for typos.")

        // Surrounding whitespace should be trimmed before counting — so
        // a 100-char string padded by spaces still triggers.
        let padded = "  " + String(repeating: "c", count: 100) + "  "
        #expect(NameLengthWarning.warningText(forName: padded) != nil)
    }

    @Test func nameWarningStillPresentBelow500() {
        // 499 chars — still in warning zone.
        let high = String(repeating: "d", count: 499)
        #expect(NameLengthWarning.warningText(forName: high) ==
                "Names this long are unusual — double-check for typos.")

        // 500+ chars hand off to the hard-limit save blocker; this helper
        // returns nil so it doesn't fight with the disabled Save button.
        let over = String(repeating: "e", count: 500)
        #expect(NameLengthWarning.warningText(forName: over) == nil)
    }
}
