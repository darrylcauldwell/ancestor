import Testing
import Foundation
@testable import Ancestor_Research

struct MergeEngineTests {

    // MARK: - Date Merge

    @Test func dateReplace_whenNoExisting() {
        let incoming = GenealogicalDate(parsing: "1887")
        let action = MergeEngine.mergeDateAction(existing: nil, incoming: incoming)
        guard case .replace = action else {
            Issue.record("Expected .replace, got \(action)")
            return
        }
    }

    @Test func dateCorroborate_identicalRanges() {
        let existing = GenealogicalDate(parsing: "1887")
        let incoming = GenealogicalDate(parsing: "1887")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .corroborate = action else {
            Issue.record("Expected .corroborate, got \(action)")
            return
        }
    }

    @Test func dateIntersect_complementaryUnbounded() {
        // AFT 1870 (1870, nil) + BEF 1890 (nil, 1890) → (1870, 1890)
        let existing = GenealogicalDate(parsing: "AFT 1870")
        let incoming = GenealogicalDate(parsing: "BEF 1890")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .intersect(let merged) = action else {
            Issue.record("Expected .intersect, got \(action)")
            return
        }
        #expect(merged.earliest == 1870)
        #expect(merged.latest == 1890)
    }

    @Test func dateIntersect_narrowPlusOverlap() {
        // Exact 1887 + ABT 1890 (1885-1895) → 1887 is in range → intersect
        let existing = GenealogicalDate(parsing: "1887")
        let incoming = GenealogicalDate(parsing: "ABT 1890")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .intersect = action else {
            Issue.record("Expected .intersect, got \(action)")
            return
        }
    }

    @Test func dateDispute_bothApproximatePartialOverlap() {
        // ABT 1887 (1882-1892) + ABT 1895 (1890-1900) → partial overlap → dispute
        let existing = GenealogicalDate(parsing: "ABT 1887")
        let incoming = GenealogicalDate(parsing: "ABT 1895")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .dispute(.approximateOverlap) = action else {
            Issue.record("Expected .dispute(.approximateOverlap), got \(action)")
            return
        }
    }

    @Test func dateDispute_noOverlap() {
        // 1887 + 1920 → no overlap
        let existing = GenealogicalDate(parsing: "1887")
        let incoming = GenealogicalDate(parsing: "1920")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .dispute(.noOverlap) = action else {
            Issue.record("Expected .dispute(.noOverlap), got \(action)")
            return
        }
    }

    @Test func dateCorroborate_identicalApproximate() {
        // ABT 1887 + ABT 1887 → identical ranges → corroborate
        let existing = GenealogicalDate(parsing: "ABT 1887")
        let incoming = GenealogicalDate(parsing: "ABT 1887")
        let action = MergeEngine.mergeDateAction(existing: existing, incoming: incoming)
        guard case .corroborate = action else {
            Issue.record("Expected .corroborate, got \(action)")
            return
        }
    }

    // MARK: - String Merge

    @Test func stringReplace_whenNoExisting() {
        let action = MergeEngine.mergeStringAction(existing: nil, incoming: "Belper")
        guard case .replace = action else {
            Issue.record("Expected .replace")
            return
        }
    }

    @Test func stringCorroborate_identical() {
        let action = MergeEngine.mergeStringAction(existing: "Belper", incoming: "Belper")
        guard case .corroborate = action else {
            Issue.record("Expected .corroborate")
            return
        }
    }

    @Test func stringCorroborate_caseInsensitive() {
        let action = MergeEngine.mergeStringAction(existing: "BELPER", incoming: "Belper")
        guard case .corroborate = action else {
            Issue.record("Expected .corroborate for case-insensitive match")
            return
        }
    }

    @Test func stringDispute_differentValues() {
        let action = MergeEngine.mergeStringAction(existing: "Belper", incoming: "Derby")
        guard case .dispute(.valueMismatch) = action else {
            Issue.record("Expected .dispute(.valueMismatch)")
            return
        }
    }
}
