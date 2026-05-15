import SwiftUI

/// Sheet presented from a profile's detail view to configure and trigger a
/// research run. Picks smart default mode based on what's missing on the profile
/// — Discover for sparse profiles (no parents / no key dates), Extend when
/// filling gaps, Verify when mostly complete.
struct ResearchConfigSheet: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    let onRun: (ResearchRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ResearchMode
    @State private var scope: ResearchScope = .local

    init(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        onRun: @escaping (ResearchRequest) -> Void
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.onRun = onRun
        self._mode = State(initialValue: Self.defaultMode(for: profile, snapshot: snapshot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Research")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Depth")
                    .font(.headline)
                Picker("Depth", selection: $mode) {
                    Text("Verify").tag(ResearchMode.verify)
                    Text("Extend").tag(ResearchMode.extend)
                    Text("Discover").tag(ResearchMode.discover)
                    Text("All").tag(ResearchMode.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Scope")
                    .font(.headline)
                Picker("Scope", selection: $scope) {
                    Text("Local").tag(ResearchScope.local)
                    Text("National").tag(ResearchScope.national)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(scopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Hint: what's missing on this profile — primes the user on what
            // research can plausibly find.
            let gaps = visibleGaps
            if !gaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gaps research could fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(gaps, id: \.self) { gap in
                        Text("• \(gap)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onRun(ResearchRequest(profileID: profile.id, mode: mode, scope: scope))
                } label: {
                    Label("Run research", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    /// Default mode picked by what's missing. Sparse profile (no parents +
    /// minimal data) → Discover. Has identity but missing dates → Extend.
    /// Mostly complete → Verify.
    private static func defaultMode(for profile: Profile, snapshot: FamilyGraphSnapshot) -> ResearchMode {
        let completeness = snapshot.completeness(for: profile.id)
        let hasParents = snapshot.parentsOf(profile.id).isEmpty == false
        let hasGivenName = (profile.firstName ?? "").isEmpty == false

        // Ghost-shaped profiles (surname only, no parents) → Discover
        if !hasGivenName || !hasParents { return .discover }
        // Mostly complete → Verify
        if completeness.score >= completeness.maximum - 1 { return .verify }
        // Default for "has gaps" → Extend
        return .extend
    }

    private var modeDescription: String {
        let estimate = Self.estimatedDuration(mode: mode, scope: scope)
        let intent: String
        switch mode {
        case .verify:   intent = "Confirm what's already known against sources. Stops early when corroborated."
        case .extend:   intent = "Fill missing facts (death, marriage, location). Standard depth."
        case .discover: intent = "Broad search from scratch. Use for ghost profiles or unfamiliar ancestors."
        case .all:      intent = "Most thorough preset. Maximum iterations, highest fact cap, no early stop."
        }
        return "\(intent) Estimated \(estimate)."
    }

    private var scopeDescription: String {
        switch scope {
        case .local:    "Home region only — the 12 Derbyshire registration districts."
        case .national: "Every UK registration district (~1,125 districts, year-filtered)."
        }
    }

    /// Rough duration estimate per (depth × scope) combination. Values assume the
    /// 500ms inter-request throttle and serial dispatch per source — accurate to
    /// within ~50% for typical profiles, depending on how many record types apply.
    /// Shown in the sheet so the user understands the trade-off before clicking Run.
    static func estimatedDuration(mode: ResearchMode, scope: ResearchScope) -> String {
        switch (mode, scope) {
        case (.verify, .local):     return "10–30 sec (often stops early)"
        case (.extend, .local):     return "1–2 min"
        case (.discover, .local):   return "1–2 min"
        case (.all, .local):        return "2–3 min"
        case (.verify, .national):  return "5–15 min (often stops early)"
        case (.extend, .national):  return "15–30 min"
        case (.discover, .national):return "15–30 min"
        case (.all, .national):     return "30–60 min"
        }
    }

    /// One-line gap descriptions for the hint section.
    private var visibleGaps: [String] {
        var gaps: [String] = []
        if (profile.firstName ?? "").isEmpty { gaps.append("First name") }
        if profile.birthDate == nil { gaps.append("Birth date") }
        if (profile.birthLocation ?? "").isEmpty { gaps.append("Birth location") }
        if profile.deathDate == nil, snapshot.completeness(for: profile.id).potentiallyLiving == false {
            gaps.append("Death date")
        }
        if snapshot.parentsOf(profile.id).isEmpty { gaps.append("Parents") }
        if snapshot.spousesOf(profile.id).isEmpty { gaps.append("Spouse / marriage") }
        return gaps
    }
}
