import Foundation

/// One protocol, three trigger contexts.
/// Replaces the separate AuditRuleDefinition protocol.
/// A single rule like BirthBeforeDeathRule can:
/// - Audit the existing tree (existingTree)
/// - Detect contradictions from new source records (newRecord)
/// - Flag conflicts during multi-source merge (multipleSourceMerge)
public protocol DataQualityRule: Sendable {
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
    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    public func evaluate(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    public func evaluate(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult] { [] }
}

/// When a rule fires.
public nonisolated enum RuleTriggerContext: Sendable, Hashable {
    case existingTree           // audit
    case newRecord              // discrepancy detection
    case multipleSourceMerge    // corroboration / merge policy
}

/// How severe a rule finding is.
public nonisolated enum RuleSeverity: String, Sendable, Codable, Comparable {
    case info, warning, error

    private var rank: Int {
        switch self { case .info: 0; case .warning: 1; case .error: 2 }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A finding from a data quality rule.
public nonisolated struct RuleResult: Sendable, Identifiable {
    public let id = UUID()
    public let ruleID: String
    public let profileID: String
    public let profileName: String
    public let field: ProfileField?
    public let severity: RuleSeverity
    public let context: RuleTriggerContext
    public let message: String

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(ruleID: String, profileID: String, profileName: String, field: ProfileField? = nil, severity: RuleSeverity, context: RuleTriggerContext, message: String) {
        self.ruleID = ruleID
        self.profileID = profileID
        self.profileName = profileName
        self.field = field
        self.severity = severity
        self.context = context
        self.message = message
    }

}
