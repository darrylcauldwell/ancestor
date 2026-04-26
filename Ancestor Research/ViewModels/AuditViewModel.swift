import SwiftUI

/// View model for audit results — unified view of issues and gaps.
@MainActor @Observable
final class AuditViewModel {
    var summary: AuditSummary?
    var isRunning = false
    var filterSeverity: Severity?
    var filterCategory: AuditCategory?
    var searchText = ""

    func runAudit(snapshot: FamilyGraphSnapshot, disabledRuleIDs: Set<String> = []) {
        isRunning = true
        summary = AuditEngine.auditGrouped(snapshot, disabledRuleIDs: disabledRuleIDs)
        isRunning = false
    }

    var filteredResults: [AuditResult] {
        guard let summary else { return [] }

        var all: [AuditResult]
        if let severity = filterSeverity {
            switch severity {
            case .error: all = summary.errors
            case .warning: all = summary.warnings
            case .info: all = summary.info
            }
        } else {
            all = summary.errors + summary.warnings + summary.info
        }

        if let category = filterCategory {
            all = all.filter { $0.category == category }
        }

        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.profileName.lowercased().contains(query) ||
            $0.message.lowercased().contains(query)
        }
    }

    var issueCount: Int {
        guard let summary else { return 0 }
        return (summary.errors + summary.warnings + summary.info).filter { $0.category == .issue }.count
    }

    var gapCount: Int {
        guard let summary else { return 0 }
        return (summary.errors + summary.warnings + summary.info).filter { $0.category == .gap }.count
    }
}
