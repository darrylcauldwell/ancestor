import Foundation

/// One protocol, three trigger contexts.
/// Replaces the separate AuditRuleDefinition protocol.
/// A single rule like BirthBeforeDeathRule can:
/// - Audit the existing tree (existingTree)
/// - Detect contradictions from new source records (newRecord)
/// - Flag conflicts during multi-source merge (multipleSourceMerge)
protocol DataQualityRule: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var fireCondition: String { get }
    var warningCondition: String? { get }
    var workedExample: String { get }
    var severity: RuleSeverity { get }
    var triggerContexts: Set<RuleTriggerContext> { get }

    /// Audit context: existing tree alone.
    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult]

    /// Discrepancy context: a new source record vs the existing tree.
    func evaluate(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult]

    /// Merge context: multiple sources for one field.
    func evaluate(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult]
}

// Default no-op implementations — rules opt in by overriding.
extension DataQualityRule {
    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    func evaluate(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    func evaluate(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult] { [] }
}

/// When a rule fires.
nonisolated enum RuleTriggerContext: Sendable, Hashable {
    case existingTree           // audit
    case newRecord              // discrepancy detection
    case multipleSourceMerge    // corroboration / merge policy
}

/// How severe a rule finding is.
nonisolated enum RuleSeverity: String, Sendable, Codable, Comparable {
    case info, warning, error

    private var rank: Int {
        switch self { case .info: 0; case .warning: 1; case .error: 2 }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A finding from a data quality rule.
nonisolated struct RuleResult: Sendable, Identifiable {
    let id = UUID()
    let ruleID: String
    let profileID: String
    let profileName: String
    let field: ProfileField?
    let severity: RuleSeverity
    let context: RuleTriggerContext
    let message: String
}
