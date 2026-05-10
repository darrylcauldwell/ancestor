import SwiftUI

/// Settings → Audit Rules. M18 (DESIGN.md §13).
///
/// For each built-in rule, exposes:
///   - Enable/disable toggle (global override)
///   - Tunable thresholds as sliders (rules opt in via `tunableThresholds`)
///   - "Snooze 7 days" / "Cancel snooze" button
///   - Per-rule "Reset" button (deletes the global override row)
///
/// All persistence goes through `AppState.upsertAuditRuleOverride(_:)` /
/// `AppState.deleteAuditRuleOverride(id:)` — this view never touches the DB
/// directly. Loading is on-demand via `appState.loadAuditRuleOverrides()`,
/// cached locally and refreshed after every mutation.
struct AuditRulesView: View {
    @Environment(AppState.self) private var appState

    @State private var overrides: [AuditRuleOverride] = []
    @State private var showingResetAllConfirm = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Disable a rule, snooze it for a week, or tune its thresholds. Changes apply across the whole project.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        showingResetAllConfirm = true
                    } label: {
                        Text("Reset all")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(globalOverrides.isEmpty)
                }
            }

            Section("Built-in rules (\(AuditRules.builtIn.count))") {
                ForEach(AuditRules.builtIn, id: \.id) { rule in
                    AuditRuleRow(
                        rule: rule,
                        override: globalOverride(for: rule.id),
                        onToggle: { enabled in setEnabled(rule: rule, enabled: enabled) },
                        onThresholdChange: { key, value in setThreshold(rule: rule, key: key, value: value) },
                        onSnooze: { snooze(rule: rule) },
                        onCancelSnooze: { cancelSnooze(rule: rule) },
                        onReset: { reset(rule: rule) }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audit Rules")
        .onAppear { reload() }
        .confirmationDialog(
            "Reset all audit rule overrides?",
            isPresented: $showingResetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset all", role: .destructive) { resetAllGlobal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every global override. Per-profile snoozes are kept.")
        }
    }

    // MARK: - Override resolution

    private var globalOverrides: [AuditRuleOverride] {
        overrides.filter { if case .global = $0.scope { return true } else { return false } }
    }

    private func globalOverride(for ruleID: String) -> AuditRuleOverride? {
        globalOverrides.first { $0.ruleID == ruleID }
    }

    private func reload() {
        overrides = appState.loadAuditRuleOverrides()
    }

    // MARK: - Mutations

    private func setEnabled(rule: AuditRuleDefinition, enabled: Bool) {
        let existing = globalOverride(for: rule.id)
        var ov = existing ?? AuditRuleOverride(
            id: UUID(), ruleID: rule.id, scope: .global,
            enabled: true, snoozedUntil: nil, thresholds: [:]
        )
        ov.enabled = enabled
        appState.upsertAuditRuleOverride(ov)
        reload()
    }

    private func setThreshold(rule: AuditRuleDefinition, key: String, value: Double) {
        let existing = globalOverride(for: rule.id)
        var ov = existing ?? AuditRuleOverride(
            id: UUID(), ruleID: rule.id, scope: .global,
            enabled: true, snoozedUntil: nil, thresholds: [:]
        )
        ov.thresholds[key] = value
        appState.upsertAuditRuleOverride(ov)
        reload()
    }

    private func snooze(rule: AuditRuleDefinition) {
        appState.snoozeAuditRule(ruleID: rule.id, scope: .global, days: 7)
        reload()
    }

    private func cancelSnooze(rule: AuditRuleDefinition) {
        guard var ov = globalOverride(for: rule.id) else { return }
        ov.snoozedUntil = nil
        // If the override is otherwise default (enabled, no thresholds, no
        // snooze), drop it entirely — keeps the row pristine.
        if ov.enabled && ov.thresholds.isEmpty {
            appState.deleteAuditRuleOverride(id: ov.id)
        } else {
            appState.upsertAuditRuleOverride(ov)
        }
        reload()
    }

    private func reset(rule: AuditRuleDefinition) {
        guard let ov = globalOverride(for: rule.id) else { return }
        appState.deleteAuditRuleOverride(id: ov.id)
        reload()
    }

    private func resetAllGlobal() {
        for ov in globalOverrides {
            appState.deleteAuditRuleOverride(id: ov.id)
        }
        reload()
    }
}

// MARK: - Row

private struct AuditRuleRow: View {
    let rule: AuditRuleDefinition
    let override: AuditRuleOverride?
    let onToggle: (Bool) -> Void
    let onThresholdChange: (String, Double) -> Void
    let onSnooze: () -> Void
    let onCancelSnooze: () -> Void
    let onReset: () -> Void

    private var isEnabled: Bool { override?.enabled ?? true }
    private var hasOverride: Bool { override != nil }
    private var snoozedUntil: Date? { override?.snoozedUntil }
    private var isSnoozed: Bool {
        if let until = snoozedUntil { return until > Date() }
        return false
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(rule.description)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)

                if !rule.tunableThresholds.isEmpty {
                    Divider()
                    ForEach(rule.tunableThresholds, id: \.key) { tt in
                        ThresholdSlider(
                            threshold: tt,
                            value: override?.thresholds[tt.key] ?? tt.defaultValue,
                            onChange: { onThresholdChange(tt.key, $0) }
                        )
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    if isSnoozed, let until = snoozedUntil {
                        Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))")
                            .font(AppTypography.badge)
                            .foregroundStyle(.orange)
                        Button("Cancel snooze") { onCancelSnooze() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    } else {
                        Button("Snooze 7 days") { onSnooze() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(!isEnabled)
                    }

                    Spacer()

                    Button(role: .destructive) { onReset() } label: {
                        Text("Reset")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!hasOverride)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: rule.defaultSeverity.iconName)
                    .foregroundStyle(isEnabled && !isSnoozed ? rule.defaultSeverity.color : .secondary.opacity(0.4))
                    .accessibilityLabel("Severity \(rule.defaultSeverity.rawValue)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName)
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if isSnoozed, let until = snoozedUntil {
                        Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))")
                            .font(AppTypography.badge)
                            .foregroundStyle(.orange)
                    } else if !isEnabled {
                        Text("Disabled")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Slider for one tunable threshold

private struct ThresholdSlider: View {
    let threshold: TunableThreshold
    let value: Double
    let onChange: (Double) -> Void

    @State private var localValue: Double

    init(threshold: TunableThreshold, value: Double, onChange: @escaping (Double) -> Void) {
        self.threshold = threshold
        self.value = value
        self.onChange = onChange
        _localValue = State(initialValue: value)
    }

    private var displayValue: String {
        let intVal = Int(localValue.rounded())
        if let unit = threshold.unit {
            return "\(intVal) \(unit)"
        }
        return "\(intVal)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(threshold.displayName)
                    .font(AppTypography.controlLabel)
                Spacer()
                Text(displayValue)
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { localValue },
                    set: { newVal in
                        localValue = newVal
                        onChange(newVal)
                    }
                ),
                in: threshold.minimum...threshold.maximum,
                step: 1
            )
        }
        .onChange(of: value) { _, newVal in
            // External update — keep slider in sync after reload.
            if abs(newVal - localValue) > 0.5 { localValue = newVal }
        }
    }
}
