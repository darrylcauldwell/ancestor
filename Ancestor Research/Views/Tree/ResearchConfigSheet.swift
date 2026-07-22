import SwiftUI

/// Sheet presented from a profile's detail view to configure and trigger a
/// research run. One adaptive research action (SOURCE_WEIGHTING companion,
/// 2026-07-15): the Depth picker is retired — strictness escalates on miss
/// and staged dispatch owns geography. The profile's shape still seeds the
/// SCOPE default (sparse → wider), which the user can override.
struct ResearchConfigSheet: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    /// Optional pre-selected focus from the caller — set when the user
    /// triggered the sheet from a per-gap "Research parents / siblings /
    /// …" button. The mode default flips to `.discover` when focus is
    /// non-nil. See RESEARCH_PIPELINE_SPEC §11.4.
    let focus: ResearchFocus?
    /// Project-level home-county fallback (the last step of the
    /// derivation chain) — needed to tell whether this subject has ANY
    /// derivable anchor.
    let projectHomeChapmanCode: String
    /// True when no home county is derivable: a geographic bound relative
    /// to a nonexistent anchor is meaningless, so the sheet defaults to
    /// National (owner decision 2026-07-15: "I would have assumed
    /// national") and says why. An explicitly narrowed run still gets the
    /// visible per-source skips.
    let isAnchorless: Bool
    let onRun: (ResearchRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: ResearchScope
    /// User opt-in for the prose-extraction phase. Defaults to off — it's a
    /// ~20-minute MLX workload that's only useful for subjects whose
    /// location overlaps the prose corpora, and the run cost is
    /// substantial for the noisy upside.
    @State private var runProseExtraction: Bool = false

    init(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        focus: ResearchFocus? = nil,
        projectHomeChapmanCode: String = "",
        onRun: @escaping (ResearchRequest) -> Void
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.focus = focus
        self.projectHomeChapmanCode = projectHomeChapmanCode
        self.onRun = onRun
        let anchorless = ResearchSubject.deriveHomeChapmanCode(
            from: profile, projectFallback: projectHomeChapmanCode).isEmpty
        self.isAnchorless = anchorless
        if anchorless {
            self._scope = State(initialValue: .national)
        } else {
            // The legacy shape-based mode heuristic survives ONLY as the
            // scope seed: sparse/focused subjects default wider.
            let seedMode: ResearchMode = focus == nil
                ? Self.defaultMode(for: profile, snapshot: snapshot)
                : .discover
            self._scope = State(initialValue: Self.defaultScope(for: seedMode))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focus?.actionLabel ?? "Research")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let focus {
                    Text("Focused on \(focus.rawValue) — only \(focus.recordTypes.map(\.rawValue).sorted().joined(separator: ", ")) records will be searched.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
                    Text("International").tag(ResearchScope.international)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(scopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isAnchorless {
                    Text("No home county could be derived for this profile, so the default is National — the only scope that lets county-anchored sources (FreeBMD, FreeCen, FreeREG) search at all. Narrower scopes will skip them, visibly.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Prose-extraction opt-in — available on every adaptive run.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $runProseExtraction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prose extraction (AI)")
                            .font(.subheadline)
                        Text("Run the local reasoning model over local-history corpora. Adds roughly 20 minutes; useful when the subject's location matches a registered corpus.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
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

            Text(runDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onRun(ResearchRequest(
                        profileID: profile.id,
                        // SOURCE_WEIGHTING companion (2026-07-15): the sheet
                        // always dispatches the one adaptive action — Depth
                        // is retired; explicit modes remain MCP overrides.
                        mode: .adaptive,
                        scope: scope,
                        focus: focus,
                        runProseExtraction: runProseExtraction
                    ))
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
        case .adaptive: return .county
        }
    }

    private var scopeDescription: String {
        switch scope {
        case .parish:   "Home parish only. Limited to parish-supporting sources (FreeREG, FreeCen)."
        case .district: "Home registration district. Today falls through to county scope until structured location codes ship."
        case .county:   "Home county's registration districts — the current local-scope behaviour."
        case .adjacent: "Home county plus counties bordering it (single hop). Useful for ancestors near a county border."
        case .national: "Every UK registration district (~1,125 districts, year-filtered)."
        case .international: "National coverage plus records outside the UK. Find a Grave searches worldwide, and overseas places surface as reviewable leads instead of being dropped — for emigrant / colonial ancestors."
        }
    }

    /// One cost-of-the-click line: adaptive strictness + staged dispatch,
    /// bounded by the chosen scope.
    private var runDescription: String {
        "Searches free sources first and escalates on miss (FamilySearch only if needed). Estimated \(Self.estimatedDuration(mode: .adaptive, scope: scope))."
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
        case (.adaptive, .parish):    return "15–45 sec (stops when answered)"
        case (.adaptive, .district):  return "1–2 min (stops when answered)"
        case (.adaptive, .county):    return "2–4 min (stops when answered)"
        case (.adaptive, .adjacent):  return "3–8 min (stops when answered)"
        case (.adaptive, .national):  return "5–15 min (stops when answered)"
        // International adds a worldwide Find a Grave pass on top of national.
        // Adaptive still stops when the gaps are answered.
        case (.adaptive, .international): return "10–25 min worldwide (stops when answered)"
        case (_, .international):      return "10–25 min (worldwide)"
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
