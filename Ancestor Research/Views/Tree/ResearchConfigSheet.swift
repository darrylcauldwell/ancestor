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
    @State private var scope: ResearchScope

    init(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        onRun: @escaping (ResearchRequest) -> Void
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.onRun = onRun
        let initialMode = Self.defaultMode(for: profile, snapshot: snapshot)
        self._mode = State(initialValue: initialMode)
        self._scope = State(initialValue: Self.defaultScope(for: initialMode))
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
                // 5-option hierarchy: parish → district → county → adjacent
                // → national. Menu style keeps the sheet width manageable
                // (segmented would be too wide for 5 options at 420pt).
                Picker("Scope", selection: $scope) {
                    Text("Parish").tag(ResearchScope.parish)
                    Text("District").tag(ResearchScope.district)
                    Text("County").tag(ResearchScope.county)
                    Text("County + adjacent").tag(ResearchScope.adjacent)
                    Text("National").tag(ResearchScope.national)
                }
                .pickerStyle(.menu)
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
    static func defaultMode(for profile: Profile, snapshot: FamilyGraphSnapshot) -> ResearchMode {
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

    /// Default scope derived from depth alone — RESEARCH_AXES_SPEC §4.
    /// Profile completeness doesn't factor in (single-input precedence rule
    /// avoids the failure modes of a depth × completeness matrix). The user
    /// can override per-run from the sheet.
    static func defaultScope(for mode: ResearchMode) -> ResearchScope {
        switch mode {
        case .verify:   return .district
        case .extend:   return .county
        case .discover: return .adjacent
        case .all:      return .national
        }
    }

    private var modeDescription: String {
        let estimate = Self.estimatedDuration(mode: mode, scope: scope)
        let intent: String
        let strictnessHint: String
        switch mode {
        case .verify:
            intent = "Confirm what's already known against sources. Stops early when corroborated."
            strictnessHint = "Exact-name matches only — no phonetic or variant fan-out."
        case .extend:
            intent = "Fill missing facts (death, marriage, location). Standard depth."
            strictnessHint = "Tries exact match first; broadens to phonetic on empty per source."
        case .discover:
            intent = "Broad search from scratch. Use for ghost profiles or unfamiliar ancestors."
            strictnessHint = "Starts with phonetic match; escalates to spelling-variant fan-out if empty."
        case .all:
            intent = "Most thorough preset. Maximum iterations, highest fact cap, no early stop."
            strictnessHint = "Runs every match tier (exact, phonetic, variants) and dedupes."
        }
        return "\(intent) \(strictnessHint) Estimated \(estimate)."
    }

    private var scopeDescription: String {
        switch scope {
        case .parish:   "Home parish only. Limited to FreeREG / FreeCen / Wirksworth (parish-supporting sources)."
        case .district: "Home registration district. Today falls through to county scope until structured location codes ship."
        case .county:   "Home county's registration districts — the current local-scope behaviour."
        case .adjacent: "Home county plus counties bordering it (single hop). Useful for ancestors near a county border."
        case .national: "Every UK registration district (~1,125 districts, year-filtered)."
        }
    }

    /// Rough duration estimate per (depth × scope) combination. Values assume the
    /// 500ms inter-request throttle and serial dispatch per source — accurate to
    /// within ~50% for typical profiles, depending on how many record types apply.
    /// Shown in the sheet so the user understands the trade-off before clicking Run.
    /// See RESEARCH_AXES_SPEC §4 for the locked 5×4 table.
    static func estimatedDuration(mode: ResearchMode, scope: ResearchScope) -> String {
        switch (mode, scope) {
        case (.verify, .parish):      return "5–15 sec (often stops early)"
        case (.verify, .district):    return "10–30 sec (often stops early)"
        case (.verify, .county):      return "30 sec–1 min (often stops early)"
        case (.verify, .adjacent):    return "1–3 min (often stops early)"
        case (.verify, .national):    return "3–8 min (often stops early)"
        case (.extend, .parish):      return "10–30 sec"
        case (.extend, .district):    return "30 sec–1 min"
        case (.extend, .county):      return "1–2 min"
        case (.extend, .adjacent):    return "2–5 min"
        case (.extend, .national):    return "5–12 min"
        case (.discover, .parish):    return "15–45 sec"
        case (.discover, .district):  return "1–2 min"
        case (.discover, .county):    return "2–4 min"
        case (.discover, .adjacent):  return "3–8 min"
        case (.discover, .national):  return "5–15 min"
        case (.all, .parish):         return "30 sec–1 min"
        case (.all, .district):       return "2–4 min"
        case (.all, .county):         return "3–6 min"
        case (.all, .adjacent):       return "5–12 min"
        case (.all, .national):       return "8–20 min"
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
