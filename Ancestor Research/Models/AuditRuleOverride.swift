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
nonisolated struct AuditRuleOverride: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let ruleID: String
    let scope: AuditOverrideScope
    var enabled: Bool
    var snoozedUntil: Date?
    var thresholds: [String: Double]    // key = threshold name, value = override

    /// Whether the rule should currently skip evaluation given a reference time.
    func isCurrentlyMuted(asOf now: Date = Date()) -> Bool {
        if !enabled { return true }
        if let until = snoozedUntil, until > now { return true }
        return false
    }
}

/// Scope of an audit-rule override. Global silences/customises a rule for
/// every profile; profile-scoped is the "snooze for this person" pattern.
nonisolated enum AuditOverrideScope: Codable, Hashable, Sendable {
    case global
    case profile(id: String)

    var kind: String {
        switch self {
        case .global: return "global"
        case .profile: return "profile"
        }
    }

    var profileID: String? {
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
nonisolated struct TunableThreshold: Sendable, Hashable {
    let key: String                 // Stable identifier, used as JSON key
    let displayName: String         // Human-readable label
    let defaultValue: Double
    let minimum: Double
    let maximum: Double
    let unit: String?               // e.g. "years"; nil for unitless
}
