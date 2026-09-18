import SwiftUI

/// View model for audit results — unified view of issues and gaps.
@MainActor @Observable
final class AuditViewModel {
    var summary: AuditSummary?
    var isRunning = false
    var filterSeverity: Severity?
    var filterCategory: AuditCategory?
    var searchText = ""

    func runAudit(
        snapshot: FamilyGraphSnapshot,
        disabledRuleIDs: Set<String> = [],
        overrides: [AuditRuleOverride] = []
    ) {
        isRunning = true
        summary = AuditEngine.auditGrouped(
            snapshot, disabledRuleIDs: disabledRuleIDs, overrides: overrides
        )
        isRunning = false
    }

    /// All results after the text search only — the universe the two facet
    /// toggles (category, severity) then narrow.
    ///
    /// `.research` findings are excluded here at the single choke point
    /// (Health recategorisation #HR2): Health shows defects and
    /// apply-gaps only. Research prompts stay in `AuditSummary` for MCP and
    /// surface through the Workbench research suggestions instead — so the
    /// category pills, severity badges, rule chips and rows all agree.
    private var searchedResults: [AuditResult] {
        guard let summary else { return [] }
        let all = (summary.errors + summary.warnings + summary.info)
            .filter { $0.category != .research }
        guard !searchText.isEmpty else { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.profileName.lowercased().contains(query) ||
            $0.message.lowercased().contains(query)
        }
    }

    /// The list actually shown: both facets AND'd together (category × severity).
    var filteredResults: [AuditResult] {
        searchedResults.filter {
            (filterCategory == nil || $0.category == filterCategory) &&
            (filterSeverity == nil || $0.severity == filterSeverity)
        }
    }

    /// Faceted count for a CATEGORY pill — respects the active severity filter,
    /// so tapping a severity re-counts Issues/Gaps to that severity (and the
    /// numbers always match what tapping the pill would show).
    func categoryCount(_ category: AuditCategory) -> Int {
        searchedResults.filter {
            $0.category == category && (filterSeverity == nil || $0.severity == filterSeverity)
        }.count
    }

    /// Faceted count for a SEVERITY pill — respects the active category filter,
    /// so tapping Issues re-counts Errors/Warnings/Info to issues only.
    func severityCount(_ severity: Severity) -> Int {
        searchedResults.filter {
            $0.severity == severity && (filterCategory == nil || $0.category == filterCategory)
        }.count
    }

    /// Unfaceted totals (whole tree), for headings/summaries that want the raw
    /// category split regardless of the current severity selection.
    var issueCount: Int { searchedResults.filter { $0.category == .issue }.count }
    var gapCount: Int { searchedResults.filter { $0.category == .gap }.count }
}
