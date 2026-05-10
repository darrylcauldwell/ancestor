import Foundation

/// Runs all audit rules against a FamilyGraphSnapshot.
nonisolated struct AuditEngine {

    /// Run all enabled built-in rules against every profile in the snapshot.
    /// When `isManualGuidanceMode` is true, results carry a `guidanceMessage`
    /// so the UI can frame gaps as suggestions ("you might add…") instead
    /// of warnings. Errors and consistency issues are unaffected — a rule
    /// only opts in via `AuditRuleDefinition.guidanceMessage(profile:)`.
    ///
    /// `overrides` (M18) lets the user disable rules per-project, snooze
    /// rules until a future date, and silence a rule for a specific profile
    /// only ("snooze this rule for this person"). Defaults to empty so
    /// existing callers stay unchanged.
    static func audit(
        _ snapshot: FamilyGraphSnapshot,
        disabledRuleIDs: Set<String> = [],
        isManualGuidanceMode: Bool = false,
        overrides: [AuditRuleOverride] = [],
        now: Date = Date()
    ) -> [AuditResult] {
        var results: [AuditResult] = []
        // Apply legacy disabledRuleIDs first, then global overrides; the
        // latter is the source of truth post-M18 but we keep the old param
        // for the existing AppState call site.
        let globallyMutedRuleIDs: Set<String> = Set(
            overrides.lazy
                .filter {
                    if case .global = $0.scope { return $0.isCurrentlyMuted(asOf: now) }
                    return false
                }
                .map(\.ruleID)
        )
        let mutedRuleIDs = disabledRuleIDs.union(globallyMutedRuleIDs)
        let enabledRules = AuditRules.builtIn.filter { !mutedRuleIDs.contains($0.id) }

        // Per-profile mutes: ruleID → set of profile IDs the rule is muted for.
        var profileMutes: [String: Set<String>] = [:]
        for ov in overrides {
            guard ov.isCurrentlyMuted(asOf: now) else { continue }
            if case .profile(let profileID) = ov.scope {
                profileMutes[ov.ruleID, default: []].insert(profileID)
            }
        }

        // Per-rule global threshold overrides (M18). A `.global` override
        // contributes its `thresholds` map even when the rule remains enabled —
        // the user is just tuning, not silencing.
        var globalThresholds: [String: [String: Double]] = [:]
        for ov in overrides {
            if case .global = ov.scope, !ov.thresholds.isEmpty {
                globalThresholds[ov.ruleID] = ov.thresholds
            }
        }

        for profile in snapshot.profiles.values {
            for rule in enabledRules {
                if profileMutes[rule.id]?.contains(profile.id) == true { continue }
                let thresholds = globalThresholds[rule.id] ?? [:]
                var ruleResults = rule.evaluate(profile: profile, snapshot: snapshot, thresholds: thresholds)
                if isManualGuidanceMode, let guidance = rule.guidanceMessage(profile: profile) {
                    for i in ruleResults.indices {
                        ruleResults[i].guidanceMessage = guidance
                    }
                }
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
    static func auditGrouped(
        _ snapshot: FamilyGraphSnapshot,
        disabledRuleIDs: Set<String> = [],
        isManualGuidanceMode: Bool = false,
        overrides: [AuditRuleOverride] = [],
        now: Date = Date()
    ) -> AuditSummary {
        let all = audit(
            snapshot,
            disabledRuleIDs: disabledRuleIDs,
            isManualGuidanceMode: isManualGuidanceMode,
            overrides: overrides,
            now: now
        )
        return AuditSummary(
            errors: all.filter { $0.severity == .error },
            warnings: all.filter { $0.severity == .warning },
            info: all.filter { $0.severity == .info },
            total: all.count,
            profilesChecked: snapshot.profiles.count
        )
    }

    /// Date-range-aware research hint for a given profile.
    /// Maps a profile's best-guess birth year to the structured sources that
    /// historically cover that period in England/Wales:
    ///   1538–1837   → parish registers (FreeREG)
    ///   1837–1911   → civil registration + census (FreeBMD, FreeCEN)
    ///   1911–1939   → census + 1939 register
    ///   1939–1990   → electoral rolls
    ///   1990+       → living memory; ask family
    /// Returns nil when the profile has no birth year — there's no useful
    /// hint we can give without one.
    static func guidanceMessage(for profile: Profile) -> String? {
        guard let year = profile.birthDate?.bestYear else {
            return "Add a birth date — even an approximate year unlocks targeted research suggestions."
        }
        switch year {
        case ..<1538:
            return "Pre-1538 records are sparse. Try parish manuscripts and county histories."
        case 1538..<1837:
            return "Try parish registers (FreeREG) for baptism, marriage, and burial."
        case 1837..<1911:
            return "Civil registration began 1837 — try FreeBMD for birth/marriage/death indexes; FreeCEN for census 1841 onwards."
        case 1911..<1939:
            return "Census 1911; the 1939 Register is searchable. CWGC for those who died in the World Wars."
        case 1939..<1990:
            return "Electoral rolls and 1939 Register are useful. Ask family — many sources are still under privacy embargo."
        default:
            return "Likely living. Ask family before searching public records."
        }
    }
}

nonisolated struct AuditSummary: Sendable {
    let errors: [AuditResult]
    let warnings: [AuditResult]
    let info: [AuditResult]
    let total: Int
    let profilesChecked: Int
}

nonisolated extension Severity {
    var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        }
    }
}
