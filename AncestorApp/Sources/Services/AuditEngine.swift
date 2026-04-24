import Foundation

/// Runs all audit rules against a FamilyGraphSnapshot.
struct AuditEngine {

    /// Run all built-in rules against every profile in the snapshot.
    static func audit(_ snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        var results: [AuditResult] = []

        for profile in snapshot.profiles.values {
            for rule in AuditRules.builtIn {
                let ruleResults = rule.evaluate(profile: profile, snapshot: snapshot)
                results.append(contentsOf: ruleResults)
            }
        }

        // Sort: errors first, then warnings, then info. Within severity, by profile name.
        results.sort { a, b in
            if a.severity != b.severity {
                return a.severity.sortOrder < b.severity.sortOrder
            }
            return a.profileName < b.profileName
        }

        return results
    }

    /// Run audit and return results grouped by severity.
    static func auditGrouped(_ snapshot: FamilyGraphSnapshot) -> AuditSummary {
        let all = audit(snapshot)
        return AuditSummary(
            errors: all.filter { $0.severity == .error },
            warnings: all.filter { $0.severity == .warning },
            info: all.filter { $0.severity == .info },
            total: all.count,
            profilesChecked: snapshot.profiles.count
        )
    }
}

struct AuditSummary: Sendable {
    let errors: [AuditResult]
    let warnings: [AuditResult]
    let info: [AuditResult]
    let total: Int
    let profilesChecked: Int
}

extension Severity {
    var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        }
    }
}
