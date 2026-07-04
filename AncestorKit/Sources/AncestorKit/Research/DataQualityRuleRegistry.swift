import Foundation

/// Central registry of all data quality rules.
/// Used by audit engine, discrepancy engine, and merge engine.
@MainActor @Observable
public final class DataQualityRuleRegistry {
    public private(set) var rules: [any DataQualityRule] = []

    public init() {}

    public func register(_ rule: any DataQualityRule) {
        rules.append(rule)
    }

    /// Register all built-in rules.
    public func registerBuiltins() {
        // Port from AuditRules.builtIn — same rules, new protocol
        for rule in AuditRules.builtIn {
            register(AuditRuleAdapter(legacyRule: rule))
        }
    }

    /// Evaluate all rules in the existingTree context.
    public func evaluateExistingTree(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.existingTree) }
            .flatMap { $0.evaluate(profile: profile, snapshot: snapshot) }
    }

    /// Evaluate all rules in the newRecord context.
    public func evaluateNewRecord(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.newRecord) }
            .flatMap { $0.evaluate(record: record, profile: profile, snapshot: snapshot) }
    }

    /// Evaluate all rules in the multipleSourceMerge context.
    public func evaluateMerge(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult] {
        rules
            .filter { $0.triggerContexts.contains(.multipleSourceMerge) }
            .flatMap { $0.evaluate(field: field, sources: sources, profile: profile) }
    }
}

/// Adapter that wraps existing AuditRuleDefinition as a DataQualityRule.
/// This allows the existing 18 rules to work in the new registry without rewriting them.
/// Each rule gets existingTree context automatically. Rules that are also applicable to
/// newRecord context will be enhanced in future phases.
public nonisolated struct AuditRuleAdapter: DataQualityRule {
    public let legacyRule: any AuditRuleDefinition

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(legacyRule: any AuditRuleDefinition) {
        self.legacyRule = legacyRule
    }


    public var id: String { legacyRule.id }
    public var displayName: String { legacyRule.displayName }
    public var description: String { legacyRule.description }
    public var fireCondition: String { legacyRule.fireCondition }
    public var warningCondition: String? { legacyRule.warningCondition }
    public var workedExample: String { legacyRule.workedExample }

    public var severity: RuleSeverity {
        switch legacyRule.defaultSeverity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        }
    }

    public var triggerContexts: Set<RuleTriggerContext> { [.existingTree] }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] {
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
