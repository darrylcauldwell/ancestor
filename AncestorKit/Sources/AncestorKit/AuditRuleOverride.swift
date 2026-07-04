import Foundation

/// User customization of an audit rule, stored per-project (M18, DESIGN.md §13).
///
/// Three knobs:
/// - `enabled` — the rule fires at all (false = silenced).
/// - `snoozedUntil` — the rule is silenced until this date, then re-fires.
/// - `thresholds` — numeric tweaks for the rule's tunable values (e.g. the
///   parent-age-gap minimum of 14 years).
///
/// Scope is either `.global` (overrides apply to every profile) or
/// `.profile(id)` (overrides apply to that profile only — used for the
/// "snooze this rule for this person" inline action on the Tasks view).
public nonisolated struct AuditRuleOverride: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let ruleID: String
    public let scope: AuditOverrideScope
    public var enabled: Bool
    public var snoozedUntil: Date?
    public var thresholds: [String: Double]    // key = threshold name, value = override

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, ruleID: String, scope: AuditOverrideScope, enabled: Bool, snoozedUntil: Date? = nil, thresholds: [String: Double]) {
        self.id = id
        self.ruleID = ruleID
        self.scope = scope
        self.enabled = enabled
        self.snoozedUntil = snoozedUntil
        self.thresholds = thresholds
    }


    /// Whether the rule should currently skip evaluation given a reference time.
    public func isCurrentlyMuted(asOf now: Date = Date()) -> Bool {
        if !enabled { return true }
        if let until = snoozedUntil, until > now { return true }
        return false
    }
}

/// Scope of an audit-rule override. Global silences/customises a rule for
/// every profile; profile-scoped is the "snooze for this person" pattern.
public nonisolated enum AuditOverrideScope: Codable, Hashable, Sendable {
    case global
    case profile(id: String)

    public var kind: String {
        switch self {
        case .global: return "global"
        case .profile: return "profile"
        }
    }

    public var profileID: String? {
        switch self {
        case .global: return nil
        case .profile(let id): return id
        }
    }
}

/// A numeric threshold a rule exposes for tuning. The audit engine reads
/// the rule's `tunableThresholds` once (at runtime) so the Settings UI can
/// render labelled sliders or steppers without each rule needing to know
/// about the UI.
public nonisolated struct TunableThreshold: Sendable, Hashable {
    public let key: String                 // Stable identifier, used as JSON key
    public let displayName: String         // Human-readable label
    public let defaultValue: Double
    public let minimum: Double
    public let maximum: Double
    public let unit: String?               // e.g. "years"; nil for unitless

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(key: String, displayName: String, defaultValue: Double, minimum: Double, maximum: Double, unit: String? = nil) {
        self.key = key
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
    }

}
