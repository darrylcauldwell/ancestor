import Foundation

/// Central registry of all data quality rules.
/// Used by audit engine, discrepancy engine, and merge engine.
@MainActor @Observable
final class DataQualityRuleRegistry {
    private(set) var rules: [any DataQualityRule] = []

    func register(_ rule: any DataQualityRule) {
        rules.append(rule)
    }

    /// Register all built-in rules.
    func registerBuiltins() {
        // Port from AuditRules.builtIn — same rules, new protocol
        for rule in AuditRules.builtIn {
            register(AuditRuleAdapter(legacyRule: rule))
        }
    }

    /// Evaluate all rules in the existingTree context.
    func evaluateExistingTree(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.existingTree) }
            .flatMap { $0.evaluate(profile: profile, snapshot: snapshot) }
    }

    /// Evaluate all rules in the newRecord context.
    func evaluateNewRecord(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.newRecord) }
            .flatMap { $0.evaluate(record: record, profile: profile, snapshot: snapshot) }
    }

    /// Evaluate all rules in the multipleSourceMerge context.
    func evaluateMerge(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.multipleSourceMerge) }
            .flatMap { $0.evaluate(field: field, sources: sources, profile: profile) }
    }
}

/// Adapter that wraps existing AuditRuleDefinition as a DataQualityRule.
/// This allows the existing 18 rules to work in the new registry without rewriting them.
/// Each rule gets existingTree context automatically. Rules that are also applicable to
/// newRecord context will be enhanced in future phases.
nonisolated struct AuditRuleAdapter: DataQualityRule {
    let legacyRule: any AuditRuleDefinition

    var id: String { legacyRule.id }
    var displayName: String { legacyRule.displayName }
    var description: String { legacyRule.description }
    var fireCondition: String { legacyRule.fireCondition }
    var warningCondition: String? { legacyRule.warningCondition }
    var workedExample: String { legacyRule.workedExample }

    var severity: RuleSeverity {
        switch legacyRule.defaultSeverity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        }
    }

    var triggerContexts: Set<RuleTriggerContext> { [.existingTree] }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
        legacyRule.evaluate(profile: profile, snapshot: snapshot).map { auditResult in
            RuleResult(
                ruleID: auditResult.ruleID,
                profileID: auditResult.profileID,
                profileName: auditResult.profileName,
                field: nil,
                severity: mapSeverity(auditResult.severity),
                context: .existingTree,
                message: auditResult.message
            )
        }
    }

    private func mapSeverity(_ s: Severity) -> RuleSeverity {
        switch s {
        case .error: .error
        case .warning: .warning
        case .info: .info
        }
    }
}
