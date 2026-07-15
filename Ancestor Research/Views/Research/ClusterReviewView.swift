import SwiftUI

/// Review candidate life clusters from a research run.
/// Each cluster is a card showing records, confidence, and accept/reject actions.
struct ClusterReviewView: View {
    @Bindable var vm: ResearchViewModel
    let result: ResearchResult

    /// CL3 — run discrepancies ≥ .conflict raised by records in this
    /// cluster ("conflicts with tree"): the badge and the will-open-N
    /// disputes hint both read this count.
    private func conflictDiscrepancyCount(for cluster: LifeCluster) -> Int {
        let clusterSourceIDs = Set(cluster.records.map(\.record.common.sourceID))
        return result.discrepancies
            .filter { $0.severity >= .conflict && clusterSourceIDs.contains($0.sourceID) }
            .count
    }
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar
                .padding()
            Divider()

            if visibleClusters.isEmpty && rejectedRecords.isEmpty && discardedRecords.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let banner = subjectSpouseMarriageBannerState {
                            subjectSpouseMarriageBanner(banner)
                        }
                        noCandidatesView
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // SubjectSpouseMarriage status banner (§5.14.6).
                        // Surfaces when subject was thin entering the run —
                        // either reports recovered name, no-match, ambiguous
                        // candidates, conflict, or the "can't fire" copy.
                        if let banner = subjectSpouseMarriageBannerState {
                            subjectSpouseMarriageBanner(banner)
                        }

                        // Proposed Relatives (parent inference from confirmed birth records)
                        if !visibleProposedRelatives.isEmpty {
                            proposedRelativesSection
                        }

                        // Proposed Siblings (peer inference from BMD MMN match)
                        if !visibleSiblings.isEmpty {
                            proposedSiblingsSection
                        }

                        ForEach(visibleClusters) { cluster in
                            clusterCard(cluster)
                        }

                        // Records the scorer marked `.impossible` aren't
                        // clustered (they'd pollute moderate matches with
                        // wrong-person hits) but the user still gets
                        // visibility and an override — the human is the
                        // final arbiter, not the algorithm.
                        if !rejectedRecords.isEmpty {
                            rejectedRecordsSection
                        }

                        // Records the user ruled out — moved OUT of their
                        // clusters into this collapsed bin so the haystack
                        // reads clean, and recoverable from here: Restore
                        // returns one discarded in error (mirrors the
                        // scorer-rejected section's pattern).
                        if !discardedRecords.isEmpty {
                            discardedRecordsSection
                        }

                        // Discoveries
                        if !discoveries.isEmpty {
                            discoveriesSection
                        }

                        // Prose-corpus candidates (P5 retrieval, P6 MLX
                        // extraction). Shown when the research run found
                        // at least one same-host prose page mentioning
                        // the subject. Extracted facts/narratives flow
                        // separately into the Pending Facts review.
                        if !vm.proseCandidates.isEmpty {
                            proseCandidatesSection
                        }

                        // Source frontier
                        sourceFrontierSection
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $compareResult) { result in
            compareCandidatesSheet(result)
        }
        .task(id: vm.selectedProfile?.id) { loadPersistedDiscards() }
    }

    @ViewBuilder
    private func compareCandidatesSheet(_ result: CompareCandidatesResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare candidates")
                        .font(AppTypography.cardTitle)
                    if let profile = vm.selectedProfile {
                        Text(profile.displayName)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { compareResult = nil }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.cancelAction)
            }

            if result.isFallback {
                Label("Model not loaded", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                Text(result.text)
                    .font(AppTypography.cardBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Text("Generated by the local reasoning model. Does not assert facts — review against the records above. Existing tree data and the deterministic scoring engine remain the source of truth.")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 540)
    }

    // MARK: - Summary Bar

    @Environment(SourceRegistry.self) private var registry

    /// Cached source-info lookup. Built once per view-render so the new
    /// ConfidenceBadgeView (and the GPS scorer) can read sourcing strength
    /// without each call site re-walking the registry.
    private var sourceInfoMap: [String: SourceInfo] {
        registry.buildSourceInfoMap()
    }

    private var gpsScore: GPSScore {
        let sourceInfoMap = registry.buildSourceInfoMap()
        // T1-01 / FT-23 — outcome-aware: error-only / truncated-only
        // sources don't count as searched.
        let searchedSources = GPSScorer.searchedSourceIDs(for: result)
        return GPSScorer.score(
            result: result,
            sourceInfoMap: sourceInfoMap,
            searchedSourceCount: searchedSources.count,
            totalSourceCount: registry.allSources().count
        )
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            // Header reads the unified `subjectDisplayName` so lead-
            // investigation runs (no profile in the tree yet) still show
            // the subject's name. The "investigating a lead" badge below
            // hints that the actions won't write evidence under a profile
            // until promotion.
            if let name = vm.subjectDisplayName {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(AppTypography.cardTitle)
                        if vm.selectedLead != nil {
                            Text("lead")
                                .font(AppTypography.badge)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18))
                                .clipShape(.capsule)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(result.clusters.count) candidate\(result.clusters.count == 1 ? "" : "s"), \(result.confirmedFacts.count) facts, \(result.leads.count) leads")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // GPS score
            gpsScoreBadge

            if vm.pendingDecisions > 0 {
                Text("\(vm.pendingDecisions) to review")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
            }

            // Promote-to-Profile — only meaningful when the subject is
            // currently a Lead (no profile attached yet). Converts the lead
            // into a ghost Profile and persists the in-memory evidence
            // under it, so the cluster Apply buttons gain a target without
            // requiring a fresh research run. Hidden once the subject is a
            // profile (the normal case).
            if vm.selectedLead != nil {
                Button("Promote to profile") {
                    _ = vm.promoteLeadToProfile(into: appState)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Create a ghost Profile from this lead, attach a relationship edge to the generating profile (when the lead has one), and save the records you see here as evidence under it. Existing tree data is not overwritten.")
            }

            // Compare candidates — disambiguation prose from the local
            // reasoning model. Hidden when there's only one cluster (nothing
            // to compare); always visible otherwise so the user can discover
            // the feature. Falls back to a "model not loaded" message in the
            // sheet rather than disabling the button preemptively — keeps
            // the discovery path obvious.
            if result.clusters.count >= 2 {
                Button(isComparingCandidates ? "Comparing…" : "Compare candidates") {
                    runCompareCandidates()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isComparingCandidates)
                .help("Use the local reasoning model to disambiguate these candidates in plain English. Requires a reasoning model to be loaded in Settings.")
            }

            Button("New Research") {
                vm.reset()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    // MARK: - Compare Candidates (MLX disambiguation)

    /// Result of the most recent compare-candidates inference. nil while
    /// pending, populated when the model returns or when we surface a
    /// fallback message. Drives the sheet via `.sheet(item:)`.
    @State private var compareResult: CompareCandidatesResult?
    @State private var isComparingCandidates = false

    private func runCompareCandidates() {
        guard let profile = vm.selectedProfile else { return }
        isComparingCandidates = true
        Task {
            let subject = ResearchSubject.fromProfile(
                profile,
                snapshot: appState.snapshot,
                mode: vm.selectedMode,
                homeChapmanCode: (try? appState.currentDatabase?.loadProjectMeta())?
                    .resolvedHomeChapmanCode ?? ""
            )
            let prose = await ResearchInterpreter.compareCandidates(
                clusters: result.clusters,
                subject: subject
            )
            await MainActor.run {
                compareResult = CompareCandidatesResult(
                    text: prose ?? Self.modelUnavailableFallback,
                    isFallback: prose == nil
                )
                isComparingCandidates = false
            }
        }
    }

    /// Sheet payload — Identifiable so `.sheet(item:)` can present it. The
    /// `isFallback` flag flips the sheet's header into a "model not loaded"
    /// notice instead of treating the fallback message as model output.
    private struct CompareCandidatesResult: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isFallback: Bool
    }

    private static let modelUnavailableFallback = """
    The local reasoning model isn't loaded yet, so I can't generate disambiguation prose right now.

    Load a model from Settings → Local Reasoning Model → Load Model (the recommended Qwen3.5 4B downloads ~3 GB on first use). Once it's ready, click Compare candidates again and you'll get a side-by-side comparison of each candidate cluster with a final summary.
    """

    private var gpsScoreBadge: some View {
        let gps = gpsScore
        let color: Color = switch gps.score {
        case 5: .green
        case 4: .blue
        case 3: .teal
        case 2: .orange
        default: .red
        }

        return VStack(spacing: 2) {
            Text("GPS \(gps.score)/\(gps.maximum)")
                .font(AppTypography.cardMeta)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(gps.label)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    // MARK: - Cluster Card

    private func clusterCard(_ cluster: LifeCluster) -> some View {
        let decision = vm.clusterDecisions[cluster.id]
        let liveRecords = cluster.records.filter { !isDiscarded($0) }

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.displayName)
                        .font(AppTypography.cardTitle)
                    HStack(spacing: 8) {
                        // RESEARCH_CONFIDENCE_SPEC §4.2 Change 3 — cluster
                        // cards adopt the three-axis badge. Proposed-relative
                        // cards (line below) keep the legacy tier badge until
                        // Change 4 migrates them.
                        ConfidenceBadgeView(
                            confidence: cluster.evidenceConfidence(sourceInfoMap: sourceInfoMap)
                        )
                        if let birth = cluster.impliedBirthYear {
                            Text("b. ~\(String(birth))")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        if let death = cluster.impliedDeathYear {
                            Text("d. ~\(String(death))")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(liveRecords.count) record\(liveRecords.count == 1 ? "" : "s")")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if cluster.mergeCandidate != nil {
                    Text("Possible duplicate")
                        .font(AppTypography.badge)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                }

                // CL3 — records in this cluster contradict the tree at
                // conflict grade (run-time discrepancy signal).
                if conflictDiscrepancyCount(for: cluster) > 0 {
                    Text("Conflicts with tree")
                        .font(AppTypography.badge)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                        .help("Applying will open a dispute for each conflict-grade disagreement with the tree")
                }

                // CONFLICT_LAYER_SPEC CL2 AC3 — T-D same-year-census split badge.
                if let reason = cluster.splitReason {
                    Text("Split: contradiction")
                        .font(AppTypography.badge)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                        .help(reason)
                }
            }

            Divider()

            // Records
            ForEach(liveRecords, id: \.id) { scored in
                recordRow(scored)
            }

            // Household members
            if !cluster.householdMembers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Household members")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    ForEach(cluster.householdMembers, id: \.name) { member in
                        HStack(spacing: 8) {
                            Text(member.name)
                                .font(AppTypography.cardBody)
                            if let rel = member.relationship.nilIfEmpty {
                                Text(rel)
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                            }
                            if let age = member.age {
                                Text("age \(age)")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Divider()

            // Actions — match-quality-aware so a Confirmed cluster offers
            // "Apply" (writes record data + citation to the profile) instead
            // of the leads-flow "Save as lead". `.wrong` clusters hide the
            // prominent affirmative — only Discard remains, since the records
            // already failed name/date and shouldn't be promoted.
            //
            // Special case: a `.possible` cluster that contains a marriage
            // record whose `familyContext` gate confirmed the spouse matches
            // a known spouse edge in the tree still gets the "Apply" button.
            // FreeBMD often demotes such records to `.lead` because of blank
            // surname/district columns (transcription gaps), but the spouse-
            // match is a strong independent signal that this IS the subject's
            // marriage — applying is safe (overwrite-safe writes only).
            let quality = cluster.matchQuality
            let canApplyKnownMarriage = quality == .possible && cluster.hasKnownSpouseMarriage
            let showApply = quality == .confirmed || canApplyKnownMarriage
            HStack {
                if decision == .accepted {
                    let appliedLabel = showApply ? "Applied" : "Saved as lead"
                    let appliedIcon = showApply ? "checkmark.seal.fill" : "bookmark.fill"
                    Label(appliedLabel, systemImage: appliedIcon)
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.green)
                } else if decision == .rejected {
                    Label("Discarded", systemImage: "trash.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.red)
                } else if decision == .deferred {
                    Label("Deferred", systemImage: "clock")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.orange)
                }

                Spacer()

                if decision != .accepted && quality != .wrong {
                    if showApply {
                        // Show how many records actually get written. The
                        // predicate is "per-record decision wins over gate":
                        // user-accepted records force apply, user-rejected
                        // ones force skip, otherwise the (verdict == .fact ||
                        // known-spouse marriage) gate decides. Without this
                        // count the button looks like it'll write everything,
                        // which the user can't trust on a mixed-quality
                        // cluster.
                        let applyCount = liveRecords.filter { rec in
                            switch vm.recordDecisions[rec.id] {
                            case .accepted: return true
                            case .rejected: return false
                            default:        return RecordScorer.wouldApply(rec)
                            }
                        }.count
                        let total = liveRecords.count
                        // CL3 — applying a cluster whose records conflict
                        // with the tree opens disputes; say so up front.
                        let disputeCount = conflictDiscrepancyCount(for: cluster)
                        let disputeSuffix = disputeCount > 0
                            ? " — will open \(disputeCount) dispute\(disputeCount == 1 ? "" : "s")"
                            : ""
                        let buttonLabel = (applyCount == total
                            ? "Apply \(applyCount)"
                            : "Apply \(applyCount) of \(total)") + disputeSuffix
                        Button(buttonLabel) { vm.applyCluster(cluster, into: appState) }
                            .buttonStyle(.glassProminent)
                            .tint(.green)
                            .controlSize(.small)
                            .help(canApplyKnownMarriage
                                ? "Fill the marriage date / location on the existing spouse relationship (only where currently blank). The other \(total - applyCount) records in this cluster stay as evidence history."
                                : "Write \(applyCount) qualifying record\(applyCount == 1 ? "" : "s") to the profile (filling only nil fields) and attach as citation sources. Records that haven't fully cleared the scoring gates are skipped.")
                    } else {
                        // Save-as-lead is a deferral, not a commit, so it
                        // stays blue rather than green — green is reserved
                        // for actions that write to the profile.
                        Button("Save as lead") { vm.acceptCluster(cluster) }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                    }
                }
                if decision != .rejected {
                    Button("Discard") { vm.rejectCluster(cluster) }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .controlSize(.small)
                }
                if decision != nil {
                    Button("Reset") { vm.resetCluster(cluster) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Undo this decision — return to unreviewed.")
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .opacity(decision == .rejected ? 0.5 : 1.0)
    }

    // MARK: - Record Row

    /// IDs of records explicitly collapsed by the user. Default state is expanded
    /// — full detail visible without a click. The chevron now means "collapse to
    /// summary" (pointing up) rather than "expand to show detail".
    @State private var collapsedCitations: Set<String> = []

    private func recordRow(_ scored: ScoredRecord) -> some View {
        let citation = CitationRenderer.cite(scored.record)
        let isExpanded = !collapsedCitations.contains(scored.id)
        // Cross-run "already applied" check — when the user applied
        // this record in a previous session, `user_status` on the
        // evidence_records row is .savedAsLead. The card stays in
        // the cluster (the engine consistently re-found it; that's
        // useful confirmation) but dims and the Apply button drops
        // out so the user isn't asked to apply the same evidence
        // twice.
        let alreadyApplied = vm.userStatusForRecord(scored.record.id) == .savedAsLead

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                verdictIcon(scored.verdict)

                VStack(alignment: .leading, spacing: 2) {
                    // Record-type pill makes it obvious at a glance whether
                    // this row is a Death, Marriage, Census, Burial, etc.
                    // Without it users had to read the summary line to infer
                    // the kind, which was hard for mixed-source clusters.
                    HStack(spacing: 6) {
                        Text(recordTypeLabel(for: scored.record))
                            .font(AppTypography.badge.weight(.semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(recordTypeTint(for: scored.record).opacity(0.18))
                            .clipShape(.capsule)
                            .foregroundStyle(recordTypeTint(for: scored.record))
                        Text(scored.summary)
                            .font(AppTypography.cardBody)
                            .lineLimit(2)
                    }

                    // Gate results
                    HStack(spacing: 6) {
                        ForEach(scored.gates, id: \.gate) { gate in
                            gateChip(gate)
                        }
                    }
                }

                Spacer()

                // Per-record will-apply indicator — mirrors `applyCluster`'s
                // effective decision: per-record overrides win over the
                // default gate predicate, so a user-discarded record reads
                // as skipped even if it would otherwise apply, and a
                // force-applied record reads as will-apply even if it didn't
                // clear the gates.
                let recordDecision = vm.recordDecisions[scored.id]
                let effectiveWillApply = recordDecision == .accepted
                    || (recordDecision != .rejected && RecordScorer.wouldApply(scored))
                if alreadyApplied {
                    // Already-applied wins over the will-apply / skipped
                    // dichotomy — it's the most specific state and the
                    // user wants to know "you already did this" before
                    // anything else.
                    Label("Already applied", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("This record was applied to the profile in a previous run. Re-finding it confirms the engine is consistent — no new action needed.")
                        .accessibilityLabel("Already applied in a previous run")
                } else if effectiveWillApply {
                    Label("Will apply", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("This record will be applied to the profile when you click Apply.")
                        .accessibilityLabel("Will apply when you click Apply")
                } else {
                    Label("Skipped on apply", systemImage: "circle.dashed")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .help("This record stays in the cluster as evidence but isn't written to the profile on Apply (didn't clear the scoring gates or was discarded).")
                        .accessibilityLabel("Skipped on apply; remains as evidence")
                }

                Text(scored.record.sourceID.uppercased())
                    .font(AppTypography.sourceBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    collapsedCitations.insert(scored.id)
                } else {
                    collapsedCitations.remove(scored.id)
                }
            }

            // Expanded detail visible by default. Tap row to collapse to summary.
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !scored.gates.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scoring gates")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                            ForEach(scored.gates, id: \.gate) { gate in
                                HStack(alignment: .top, spacing: 6) {
                                    gateChip(gate)
                                    Text(gate.reason)
                                        .font(AppTypography.badge)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    let fields = recordDetailFields(scored.record)
                    if !fields.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Record fields")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                            ForEach(fields, id: \.label) { row in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(row.label)
                                        .font(AppTypography.badge)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 90, alignment: .leading)
                                    Text(row.value)
                                        .font(AppTypography.badge)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    // Raw fields — exact key/value pairs the source returned, after
                    // removing those whose value already appears in the curated list above.
                    // Guarantees the user sees every field from the record, not just the
                    // ones we've added an explicit label for.
                    let rawExtras = additionalRawFields(scored.record, alreadyShown: fields)
                    if !rawExtras.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Raw fields (\(rawExtras.count))")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                            ForEach(rawExtras, id: \.key) { row in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(row.key)
                                        .font(AppTypography.badge)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 130, alignment: .leading)
                                    HyperlinkedText(row.value, font: AppTypography.badge)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Citation")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                        Text(citation.full)
                            .font(AppTypography.badge)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if let urlString = citation.url, let url = URL(string: urlString) {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("Open in source")
                                }
                                .font(AppTypography.badge)
                                .foregroundStyle(.blue)
                            }
                        }
                    }

                    // Per-record overrides — let the user opt-in to applying
                    // a single lead they've manually verified, or opt-out of
                    // a record the gate predicate would otherwise apply.
                    // Cluster-level Apply respects these overrides.
                    perRecordActions(scored, alreadyApplied: alreadyApplied)
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
        // Dim the whole row when already applied so the user sees the
        // re-found-but-handled rows fade into the background while
        // genuinely new candidates pop.
        .opacity(alreadyApplied ? 0.55 : 1.0)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func perRecordActions(_ scored: ScoredRecord, alreadyApplied: Bool) -> some View {
        let decision = vm.recordDecisions[scored.id]
        HStack(spacing: 8) {
            if alreadyApplied {
                // Cross-run state badge — supersedes the in-session
                // decision badge because the persisted state is the
                // ground truth. The user already acted on this record;
                // we just confirm and offer Discard as the only escape
                // hatch (in case they want to mark a re-find as not
                // worth re-surfacing in future runs).
                Label("Already applied", systemImage: "checkmark.seal.fill")
                    .font(AppTypography.badge)
                    .foregroundStyle(.green)
            } else if decision == .accepted {
                Label("Applied", systemImage: "checkmark.seal.fill")
                    .font(AppTypography.badge)
                    .foregroundStyle(.green)
            } else if decision == .rejected {
                Label("Discarded", systemImage: "trash.fill")
                    .font(AppTypography.badge)
                    .foregroundStyle(.red)
            }
            Spacer()
            // Hide Apply when already applied — there's nothing to do.
            // Re-applying would just write the same FieldSource twice.
            if !alreadyApplied && decision != .accepted {
                Button("Apply this record") {
                    vm.applyRecord(scored, into: appState)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .controlSize(.mini)
                .help("Write just this record's data to the profile and mark it saved-as-lead, overriding the cluster's gate check.")
            }
            if decision != .rejected {
                Button("Discard this record") {
                    vm.discardRecord(scored)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.mini)
                .help("Hide this record from future runs. Won't write anything to the profile; cluster Apply will skip it.")
            }
            if decision != nil {
                Button("Reset") {
                    vm.resetRecordDecision(scored)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .help("Undo this per-record decision and return to the cluster's default gate behaviour.")
            }
        }
        .padding(.top, 6)
    }

    /// Flatten a SourceRecord into label/value pairs for the expanded record-detail panel.
    /// Only surfaces fields that are non-nil / non-empty for the specific record kind.
    private func recordDetailFields(_ record: SourceRecord) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) {
            if let v = value, !v.isEmpty { rows.append((label, v)) }
        }
        func addInt(_ label: String, _ value: Int?) {
            if let v = value { rows.append((label, String(v))) }
        }
        if let surname = record.surname { add("Surname", surname) }
        if let given = record.givenName { add("Given", given) }
        switch record {
        case .birth(let r):
            addInt("Year", r.birthYear)
            add("Date", r.birthDate)
            add("Quarter", r.quarter)
            add("District", r.district)
            add("Place", r.birthPlace)
            add("Mother (maiden)", r.mothersMaidenName)
            add("Volume", r.volume)
            add("Page", r.page)
        case .death(let r):
            addInt("Year", r.deathYear)
            add("Date", r.deathDate)
            add("Quarter", r.quarter)
            add("District", r.district)
            addInt("Age", r.age)
            add("Spouse surname", r.spouseSurname)
            add("Volume", r.volume)
            add("Page", r.page)
        case .marriage(let r):
            addInt("Year", r.marriageYear)
            add("Quarter", r.quarter)
            add("District", r.district)
            add("Spouse", r.spouseName)
            add("Volume", r.volume)
            add("Page", r.page)
            if let inferred = r.partnerSurnameFromSamePage,
               !inferred.trimmingCharacters(in: .whitespaces).isEmpty {
                let ref = [r.volume, r.page].compactMap { $0 }.joined(separator: "/")
                let suffix = ref.isEmpty ? "" : " at \(ref)"
                add("Partner (inferred)", "\(inferred) — same-page entry\(suffix)")
            }
        case .census(let r):
            addInt("Census", r.censusYear)
            addInt("Age", r.age)
            addInt("Birth year", r.birthYear)
            add("Birth place", r.birthPlace)
            add("Relationship", r.relationship)
            add("Occupation", r.occupation)
            add("Address", r.address)
            add("Parish", r.parish)
            add("District", r.district)
        case .burial(let r):
            addInt("Death year", r.deathYear)
            addInt("Birth year", r.birthYear)
            add("Cemetery", r.cemetery)
            add("Location", r.burialLocation)
        case .military(let r):
            add("Regiment", r.regiment)
            add("Rank", r.rank)
            add("Service no.", r.serviceNumber)
            addInt("Death year", r.deathYear)
            add("Cemetery", r.cemetery)
        case .probate(let r):
            addInt("Death year", r.deathYear)
            add("Address", r.address)
            add("Grant", r.grantType)
            add("Registry", r.registry)
        case .parish(let r):
            add("Event", r.eventType)
            addInt("Year", r.eventYear)
            add("Parish", r.parish)
            add("County", r.county)
            add("Father", r.fatherName)
            add("Mother", r.motherName)
        case .pedigree(let r):
            addInt("Birth year", r.birthYear)
            addInt("Death year", r.deathYear)
            add("Spouse", r.spouse)
            add("Location", r.location)
        }
        return rows
    }

    /// Pull every key/value from the source's rawFields dict, skipping ones whose value
    /// already appears in the curated list above (so we don't double up "district" etc).
    /// Sorted by key for stable display.
    private func additionalRawFields(
        _ record: SourceRecord,
        alreadyShown: [(label: String, value: String)]
    ) -> [(key: String, value: String)] {
        let shownValues = Set(alreadyShown.map { $0.value })
        return record.rawFields
            .filter { !$0.value.isEmpty && !shownValues.contains($0.value) }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    @ViewBuilder
    private func verdictIcon(_ verdict: RecordVerdict) -> some View {
        switch verdict {
        case .fact:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .lead:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        case .impossible:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Short human label for the record's underlying type — used as the pill
    /// next to each record row in the cluster card so the user can tell a
    /// Death from a Marriage at a glance.
    private func recordTypeLabel(for record: SourceRecord) -> String {
        switch record {
        case .birth:    "Birth"
        case .death:    "Death"
        case .marriage: "Marriage"
        case .census:   "Census"
        case .burial:   "Burial"
        case .military: "Military"
        case .probate:  "Probate"
        case .parish:   "Parish"
        case .pedigree: "Pedigree"
        }
    }

    /// Per-type tint colour so the type pills are quick to scan visually.
    private func recordTypeTint(for record: SourceRecord) -> Color {
        switch record {
        case .birth:    .green
        case .death:    .red
        case .marriage: .pink
        case .census:   .blue
        case .burial:   .brown
        case .military: .indigo
        case .probate:  .purple
        case .parish:   .teal
        case .pedigree: .orange
        }
    }

    private func gateChip(_ gate: GateResult) -> some View {
        let color: Color = switch gate.outcome {
        case .pass: .green
        case .fail: .red
        case .softFail: .orange
        case .impossible: .red
        case .skip: .gray
        }

        return Text(gate.gate.rawValue)
            .font(AppTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.5), lineWidth: 0.5)
            )
    }

    // Legacy ClusterConfidence badge helper removed in Change 4 — all view
    // surfaces now render the three-axis ConfidenceBadgeView. The enum
    // itself stays until Change 5 because BulkReviewView still uses it for
    // routing decisions (friction-tier classification, not display).

    // MARK: - Discoveries

    private var discoveries: [Discovery] {
        guard let profile = vm.selectedProfile else { return [] }
        return DiscoveryExtractor.extract(from: result, profile: profile, snapshot: appState.snapshot)
    }

    /// Records the scorer marked `.impossible` — wrong-person hits, dates
    /// outside the subject's lifespan, etc. They're surfaced in their own
    /// collapsible Triage section so the user can override the scorer when
    /// the subject's identity is so sparse that the scorer is being too
    /// strict (e.g. no death date → every burial looks like a wrong match).
    private var rejectedRecords: [ScoredRecord] {
        result.allScoredRecords.filter { $0.verdict == .impossible }
    }

    @State private var rejectedExpanded: Bool = false

    @ViewBuilder
    private var rejectedRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: rejectedExpanded ? "chevron.down" : "chevron.right")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text("Scorer rejected")
                    .font(AppTypography.cardTitle)
                Text("\(rejectedRecords.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { rejectedExpanded.toggle() }
            if !rejectedExpanded {
                Text("Records the scorer judged not to match \(vm.selectedProfile?.displayName ?? "this profile") — usually because the subject's profile is too sparse for the scorer to reconcile dates. Expand to override.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            if rejectedExpanded {
                ForEach(rejectedRecords) { scored in
                    rejectedRow(scored)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: - Discarded bin

    /// Persisted `user_status = 'discarded'` ids (plus legacy rejections),
    /// loaded once per profile. Session discards live in
    /// `vm.recordDecisions`; this set carries the PRIOR sessions' rulings
    /// so reopening a profile still shows them binned, not live.
    @State private var persistedDiscardedIDs: Set<String> = []
    @State private var discardedExpanded: Bool = false

    private func loadPersistedDiscards() {
        guard let db = vm.appDatabase, let profileID = vm.selectedProfile?.id else { return }
        persistedDiscardedIDs = (try? db.loadRejections(profileID: profileID)) ?? []
    }

    /// Session decision wins (an explicit accept this session overrides an
    /// old discard); otherwise the persisted status decides.
    private func isDiscarded(_ scored: ScoredRecord) -> Bool {
        switch vm.recordDecisions[scored.id] {
        case .accepted: return false
        case .rejected: return true
        default: return persistedDiscardedIDs.contains(scored.record.id)
        }
    }

    private var discardedRecords: [ScoredRecord] {
        result.allScoredRecords.filter(isDiscarded)
    }

    /// Clusters with at least one live (non-discarded) record — a cluster
    /// the user fully ruled out disappears; its records sit in the bin.
    private var visibleClusters: [LifeCluster] {
        result.clusters.filter { cluster in
            cluster.records.contains { !isDiscarded($0) }
        }
    }

    @ViewBuilder
    private var discardedRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: discardedExpanded ? "chevron.down" : "chevron.right")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Image(systemName: "trash")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text("Discarded")
                    .font(AppTypography.cardTitle)
                Text("\(discardedRecords.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { discardedExpanded.toggle() }
            if !discardedExpanded {
                Text("Records you ruled out — hidden from the clusters above and never re-proposed by future runs. Expand to restore one discarded in error.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            if discardedExpanded {
                ForEach(discardedRecords, id: \.id) { scored in
                    discardedRow(scored)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func discardedRow(_ scored: ScoredRecord) -> some View {
        HStack(spacing: 8) {
            Text(recordTypeLabel(for: scored.record))
                .font(AppTypography.badge.weight(.semibold))
                .textCase(.uppercase)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(recordTypeTint(for: scored.record).opacity(0.18))
                .clipShape(.capsule)
                .foregroundStyle(recordTypeTint(for: scored.record))
            Text(scored.summary)
                .font(AppTypography.cardBody)
                .lineLimit(2)
            Spacer()
            Text(scored.record.sourceID.uppercased())
                .font(AppTypography.sourceBadge)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)
            Button("Restore") {
                vm.resetRecordDecision(scored)
                persistedDiscardedIDs.remove(scored.record.id)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Return this record to its cluster and let future runs re-propose it.")
        }
        .padding(.vertical, 2)
    }

    /// Compact row for a single scorer-rejected record. Reuses
    /// `recordTypeLabel` / `recordTypeTint` for the type pill and surfaces
    /// the failing gate reasons inline so the user can decide whether the
    /// scorer's call was right.
    private func rejectedRow(_ scored: ScoredRecord) -> some View {
        let isLead = vm.userStatusForRecord(scored.record.id) == .savedAsLead
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(recordTypeLabel(for: scored.record))
                    .font(AppTypography.badge.weight(.semibold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(recordTypeTint(for: scored.record).opacity(0.18))
                    .clipShape(.capsule)
                    .foregroundStyle(recordTypeTint(for: scored.record))
                Text(scored.summary)
                    .font(AppTypography.cardBody)
                    .lineLimit(2)
                Spacer()
                Text(scored.record.sourceID.uppercased())
                    .font(AppTypography.sourceBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
            // Failing gates — give the user the why so they can decide.
            let fails = scored.gates.filter { $0.outcome == .impossible || $0.outcome == .fail }
            if !fails.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fails, id: \.gate) { gate in
                        HStack(alignment: .top, spacing: 6) {
                            gateChip(gate)
                            Text(gate.reason)
                                .font(AppTypography.badge)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if isLead {
                    Label("Saved as lead", systemImage: "bookmark.fill")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.green)
                } else {
                    Button("Save as lead anyway") { vm.overrideRejection(scored) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Override the scorer — keep this record as a lead.")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    /// Prose-corpus matches surfaced from the user's added corpora.
    /// Read-only — clicking a row opens the original page in the
    /// default browser. Extracted facts/narratives (P6) flow through
    /// the existing Pending Facts review surface; this section is
    /// the "here are the pages we found about this person" log so
    /// the user can spot-check what the corpus surfaced.
    private var proseCandidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prose Corpus Matches")
                    .font(AppTypography.cardTitle)
                Text("\(vm.proseCandidates.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }

            ForEach(vm.proseCandidates) { candidate in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        // Title is the primary label when present; falls
                        // back to the URL itself otherwise. The dedicated
                        // URL line below is always present too — keep this
                        // line as plain text to avoid a double-underline.
                        Text(candidate.title ?? candidate.sourceURL)
                            .font(AppTypography.cardBody)
                            .lineLimit(1)
                        HyperlinkedText(
                            candidate.sourceURL,
                            font: AppTypography.badge,
                            plainColor: .secondary
                        )
                        .lineLimit(1)
                        HStack(spacing: 10) {
                            Label("\(candidate.surnameHits)", systemImage: "person.text.rectangle")
                                .help("Surname mentions")
                            Label("\(candidate.yearHits)", systemImage: "calendar")
                                .help("Year mentions in range")
                            Label("\(candidate.placeHits)", systemImage: "mappin")
                                .help("Place mentions in region")
                            Spacer()
                            Text("score \(candidate.score)")
                                .foregroundStyle(.tertiary)
                        }
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var discoveriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Discoveries")
                    .font(AppTypography.cardTitle)
                Text("\(discoveries.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }

            ForEach(discoveries) { discovery in
                HStack(spacing: 10) {
                    discoveryIcon(discovery.type)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(discovery.description)
                            .font(AppTypography.cardBody)
                        Text(discovery.evidence)
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                        Text(discovery.suggestedAction)
                            .font(AppTypography.badge)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func discoveryIcon(_ type: DiscoveryType) -> some View {
        switch type {
        case .newAncestor:
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.green)
        case .maidenName:
            Image(systemName: "person.2")
                .foregroundStyle(.purple)
        case .unknownSibling:
            Image(systemName: "person.3")
                .foregroundStyle(.blue)
        case .spouseIdentified:
            Image(systemName: "heart")
                .foregroundStyle(.pink)
        case .householdMember:
            Image(systemName: "house")
                .foregroundStyle(.orange)
        case .militaryService:
            Image(systemName: "shield")
                .foregroundStyle(.red)
        case .unknownChild:
            Image(systemName: "figure.and.child.holdinghands")
                .foregroundStyle(.blue)
        case .occupationRevealed:
            Image(systemName: "briefcase")
                .foregroundStyle(.teal)
        case .addressFound:
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.cyan)
        case .alternateSpelling:
            Image(systemName: "textformat.abc")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - No Candidates Empty State

    @ViewBuilder
    private var noCandidatesView: some View {
        ContentUnavailableView {
            Label("No Candidates", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            VStack(spacing: 12) {
                Text("No matching records were found across the searched sources.")
                if vm.selectedScope < .national {
                    Text("Local search covered your home region only.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await vm.restart(
                                withScope: .national,
                                snapshot: appState.snapshot,
                                registry: registry
                            )
                        }
                    } label: {
                        Label("Search nationally (~10 min)", systemImage: "globe")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                } else {
                    Text("National search covered every UK registration district.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Proposed Relatives

    private var visibleProposedRelatives: [ProposedRelative] {
        vm.visibleProposedRelatives(snapshot: appState.snapshot)
    }

    private var proposedRelativesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed Relatives")
                    .font(AppTypography.cardTitle)
                Text("\(visibleProposedRelatives.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }
            Text("Inferred from confirmed birth records. Accept to add a ghost profile with this surname and gender; reject to suppress this proposal in future runs.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            ForEach(visibleProposedRelatives) { proposal in
                proposedRelativeRow(proposal)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// IDs of proposals explicitly collapsed by the user — default state is
    /// expanded with full reasoning visible. Chevron collapses to one-line summary.
    @State private var collapsedProposals: Set<String> = []

    /// True if this proposal corresponds to a parent already linked to the subject
    /// in the live snapshot — i.e. an earlier research run already accepted it.
    /// Surfaced as "Already linked" in the row, instead of suppressing the proposal
    /// (which used to make the section vanish entirely on re-research).
    private func proposalAlreadyLinked(_ proposal: ProposedRelative) -> Bool {
        guard case .parentOf(let subjectID) = proposal.relationship else { return false }
        let parents = appState.snapshot.parentsOf(subjectID)
        let proposalSurname = (proposal.proposedSurname ?? "").trimmingCharacters(in: .whitespaces)
        guard !proposalSurname.isEmpty else { return false }
        return parents.contains { p in
            p.gender == proposal.gender &&
            (p.lastName ?? "").caseInsensitiveCompare(proposalSurname) == .orderedSame
        }
    }

    private func proposedRelativeRow(_ proposal: ProposedRelative) -> some View {
        let decision = vm.proposedRelativeDecisions[proposal.id]
        let isExpanded = !collapsedProposals.contains(proposal.id)
        let alreadyLinked = proposalAlreadyLinked(proposal)
        let roleLabel: String = switch proposal.gender {
        case .female: "Mother"
        case .male: "Father"
        default: "Parent"
        }
        // Show "Given SURNAME" when marriage enrichment populated the given name,
        // else just the surname. Capitalises sensibly.
        let nameLabel: String = {
            let surname = proposal.proposedSurname ?? "?"
            if let given = proposal.proposedGivenName, !given.isEmpty {
                return "\(given.capitalized) \(surname)"
            }
            return surname
        }()
        let surnameLabel = nameLabel
        let rangeLabel: String = switch (proposal.birthYearLow, proposal.birthYearHigh) {
        case let (lo?, hi?): "b. \(lo)–\(hi)"
        case let (lo?, nil): "b. after \(lo)"
        case let (nil, hi?): "b. before \(hi)"
        default: ""
        }
        let subjectName = vm.selectedProfile?.displayName ?? "subject"
        // CONFLICT_LAYER_SPEC §6 Change 1 AC3 — pre-computed occupied-role
        // warning ("Subject already has a mother: BOWN"), shared predicate
        // with the accept-time F4a dispute hook so UI and producer can
        // never disagree. Shown only while the accept is still offered.
        let roleWarning: String? = (alreadyLinked || decision != nil)
            ? nil
            : ApplyEngine.parentRoleConflictWarning(
                for: proposal,
                subjectID: proposal.relationship.subjectID,
                snapshot: appState.snapshot
            )

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: proposal.gender == .female ? "person.crop.circle" : "person.crop.circle.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(roleLabel): \(surnameLabel)")
                            .font(AppTypography.cardBody)
                        // RESEARCH_CONFIDENCE_SPEC §4.2 Change 4 — proposed-
                        // relative cards adopt the three-axis badge. A parent
                        // inferred from a single FreeBMD fact record renders
                        // as: ✓ Confirmed · 1 source · Inferred — 1 step.
                        ConfidenceBadgeView(
                            confidence: proposal.evidenceConfidence(sourceInfoMap: sourceInfoMap)
                        )
                    }
                    HStack(spacing: 8) {
                        if !rangeLabel.isEmpty {
                            Text(rangeLabel)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Text("· parent of \(subjectName)")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    if let roleWarning {
                        Label(roleWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()

                if alreadyLinked {
                    // Parent matching this proposal already exists in the
                    // tree (typically wizard-created or accepted earlier).
                    // Treat as terminal — same UX as cluster-review's
                    // "Already applied" pattern: badge + dimmed row,
                    // no Apply button. The previous implementation
                    // offered Apply for enrichment (given name /
                    // marriage record onto a linked parent) but that
                    // duplicated the affordance with no clear signal
                    // about whether anything would change.
                    //
                    // Rare edge case: linked parent missing the given
                    // name that this proposal carries. If/when that
                    // surfaces, add a precise "would-apply" check
                    // (count of fields the proposal would write) and
                    // re-introduce the button gated on count > 0.
                    Label("Already applied", systemImage: "checkmark.seal.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.green)
                } else if decision == .accepted {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.green)
                } else if decision == .rejected {
                    Label("Rejected", systemImage: "xmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.red)
                } else {
                    Button("Accept") {
                        vm.acceptProposedRelative(proposal, into: appState)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                Button("Reject") {
                    vm.rejectProposedRelative(proposal)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { collapsedProposals.insert(proposal.id) }
                else { collapsedProposals.remove(proposal.id) }
            }

            if isExpanded {
                proposedRelativeDetail(proposal)
                    .padding(.leading, 30)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        // Dim already-linked or rejected proposals to the same 55%
        // opacity used for already-applied cluster records — common
        // visual language for terminal-state rows that should fade
        // into the background.
        .opacity(alreadyLinked || decision == .rejected ? 0.55 : 1.0)
    }

    /// Expanded reasoning panel: what record drove this proposal, exactly how
    /// each field was derived, and a link to the originating record. The "how"
    /// section is the important part for ancestors you don't recognise on sight —
    /// it makes it clear that the father's surname is *inferred* from the subject,
    /// not read from the source.
    @ViewBuilder
    private func proposedRelativeDetail(_ proposal: ProposedRelative) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The first evidence is the record that originated the proposal
            // (the subject's birth record carrying mother's maiden name).
            // Subsequent entries are cross-validating records appended by
            // marriage enrichment — render each so the user can see the
            // marriage that supplied the parent's given name without
            // hunting for it in cluster review.
            ForEach(Array(proposal.evidence.enumerated()), id: \.element.id) { index, scored in
                evidenceRecordView(scored, isOriginating: index == 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("How this was inferred")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                ForEach(inferenceReasoning(proposal), id: \.self) { line in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(line)
                            .font(AppTypography.badge)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Confidence")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(confidenceExplanation(proposal))
                    .font(AppTypography.badge)
                    .foregroundStyle(.primary)
            }
        }
    }

    /// One row in the proposed-relative evidence list. The originating record
    /// (the subject's birth record) uses "Inferred from"; cross-validating
    /// records (marriage enrichment hits) use "Cross-validated by" so the
    /// user can see at a glance which record supplied the given name.
    @ViewBuilder
    private func evidenceRecordView(_ scored: ScoredRecord, isOriginating: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isOriginating ? "Inferred from" : "Cross-validated by")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Text(scored.summary)
                .font(AppTypography.badge)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            let citation = CitationRenderer.cite(scored.record)
            Text(citation.full)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let urlString = citation.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open record in source")
                    }
                    .font(AppTypography.badge)
                    .foregroundStyle(.blue)
                }
            }
        }
    }

    /// Bullet points explaining each derived field on a proposed relative.
    private func inferenceReasoning(_ proposal: ProposedRelative) -> [String] {
        var lines: [String] = []
        let surname = proposal.proposedSurname ?? "?"
        if proposal.gender == .female {
            lines.append("Surname \"\(surname)\" is the mother's maiden name read directly from the BMD index entry.")
        } else if proposal.gender == .male {
            lines.append("Surname \"\(surname)\" is inferred from the subject's surname — the BMD index does not carry the father's name directly. This holds for most births pre-1980 but not for stepchildren, adoptions, or illegitimate births.")
        } else {
            lines.append("Surname \"\(surname)\" derived from the source record.")
        }
        if let lo = proposal.birthYearLow, let hi = proposal.birthYearHigh {
            lines.append("Birth window \(lo)–\(hi) derived from subject's birth year minus a plausible parent age window (18–45 years).")
        }
        // proposal.evidence[0] is always the originating birth record;
        // anything beyond that is a cross-validating marriage attached by
        // the enrichment engine — one entry when only one BMD side returned
        // the marriage, two when both sides agreed.
        let hasCrossValidation = proposal.evidence.count > 1
        if let given = proposal.proposedGivenName, !given.isEmpty {
            lines.append("Given name \"\(given.capitalized)\" found by matching a BMD marriage record where the surname pair appears at the same reference tuple.")
        } else if !proposal.ambiguousMarriages.isEmpty {
            lines.append("\(proposal.ambiguousMarriages.count) plausible marriages found in BMD index — given name can't be picked automatically. Choose one below to fill it in.")
        } else if hasCrossValidation {
            // The marriage record exists but came from the spouse's side of
            // the BMD index, so it doesn't carry this parent's given name —
            // only their surname (via the other side's `Spouse` field).
            let role = proposal.gender == .female ? "mother" : "father"
            lines.append("Marriage record found and confirms surname, but doesn't carry the \(role)'s given name on this side of the BMD index.")
        } else {
            lines.append("Given name not yet known — BMD birth index does not include either parent's given name, and no matching parent-marriage record was found in the BMD marriage index.")
        }
        return lines
    }

    /// Plain-English confidence explanation matching the badge. Built from
    /// the three-axis EvidenceConfidence; the prose mirrors the tooltip
    /// content on each axis of `ConfidenceBadgeView` so screen-reader users
    /// (or anyone reading without hover) get the same information.
    private func confidenceExplanation(_ proposal: ProposedRelative) -> String {
        let confidence = proposal.evidenceConfidence(sourceInfoMap: sourceInfoMap)
        var parts: [String] = []

        switch confidence.matchQuality {
        case .confirmed:
            parts.append("Confirmed — record fully matched the subject across all scoring gates.")
        case .possible:
            parts.append("Possible — record matched on name and date but at least one gate soft-failed.")
        case .wrong:
            parts.append("Wrong person — record fails name or date matching.")
        }

        let s = confidence.sourcing
        let lineageWord = s.independentLineageCount >= 2 ? "cross-referenced" : "single-lineage"
        let primaryNote = s.topTrustTier == .primary ? " (primary record)" : ""
        parts.append("Sourced from \(s.sourceCount) record\(s.sourceCount == 1 ? "" : "s"), \(lineageWord)\(primaryNote).")

        if confidence.inference.isInferred {
            parts.append("Inferred \(confidence.inference.steps) step\(confidence.inference.steps == 1 ? "" : "s") from a directly-observed record.")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Proposed Siblings

    private var visibleSiblings: [SiblingProposal] {
        vm.visibleSiblings(snapshot: appState.snapshot)
    }

    private var proposedSiblingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed Siblings")
                    .font(AppTypography.cardTitle)
                Text("\(visibleSiblings.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }
            Text("Birth records sharing the subject's surname, mother's maiden name, and registration district. Accept to add a ghost profile wired to both parents.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            ForEach(visibleSiblings) { proposal in
                proposedSiblingRow(proposal)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func proposedSiblingRow(_ proposal: SiblingProposal) -> some View {
        let decision = vm.siblingDecisions[proposal.id]
        let nameLabel: String = {
            let given = proposal.proposedGivenName?.capitalized ?? "?"
            let surname = proposal.proposedSurname ?? "?"
            return "\(given) \(surname)"
        }()
        let yearLabel = proposal.birthYear.map { "b. \($0)" } ?? ""
        let districtLabel = proposal.district ?? ""
        let subjectName = vm.selectedProfile?.displayName ?? "subject"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nameLabel)
                        .font(AppTypography.cardBody)
                    HStack(spacing: 8) {
                        if !yearLabel.isEmpty {
                            Text(yearLabel)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        if !districtLabel.isEmpty {
                            Text(districtLabel)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Text("· sibling of \(subjectName)")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    // Show the evidence record summary so the user can see
                    // what's behind the proposal without expanding anything.
                    if let evidence = proposal.evidence.first {
                        Text(evidence.summary)
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()

                if decision == .accepted {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.green)
                } else if decision == .rejected {
                    Label("Rejected", systemImage: "xmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.red)
                } else {
                    Button("Accept") {
                        vm.acceptSibling(proposal, into: appState)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help("Create a ghost profile for this sibling and wire it to both of \(subjectName)'s parents.")

                    Button("Reject") {
                        vm.rejectSibling(proposal)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(decision == .rejected ? 0.5 : 1.0)
    }

    // MARK: - SubjectSpouseMarriage banner (§5.14.6)

    /// Categorical state of the `.subjectSpouseMarriage` strategy for
    /// the current run. Drives one of five banner copy strings.
    private enum SubjectSpouseMarriageBannerState {
        /// Strategy fired and write-back is observable. The recovered
        /// name comes from the matched-and-agreeing supported rows;
        /// label text references the surname pair plus the concrete
        /// marriage year/quarter/district when the matched record
        /// carried them.
        case recovered(name: String, pair: String, year: Int?, quarter: String?, district: String?)
        /// Strategy fired but multiple supported rows recovered
        /// different given names — write-back blocked by §5.14.4
        /// reconciliation. User must choose.
        case conflict(names: [String], pair: String)
        /// Strategy fired with no supported rows; at least one is
        /// `.inconclusive` (ambiguous candidates in the window).
        case ambiguous(candidateCount: Int, pair: String, window: ClosedRange<Int>)
        /// Strategy fired with all rows `.contradicted` — searched but
        /// nothing matched.
        case noMatch(pair: String, window: ClosedRange<Int>)
        /// Subject is thin (no given name) but no hypothesis row was
        /// emitted — strategy couldn't fire (no usable child anchor).
        case cantFire
    }

    /// Compute the banner state from `result.hypotheses` + the selected
    /// profile. Returns nil when the subject is rich (strategy is
    /// out-of-scope) so the banner doesn't render for normal cases.
    private var subjectSpouseMarriageBannerState: SubjectSpouseMarriageBannerState? {
        let trimmedGiven = (vm.selectedProfile?.firstName ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmedGiven.isEmpty else { return nil }   // rich subject — no banner

        let rows = result.hypotheses.filter { h in
            if case .subjectSpouseMarriage = h.kind { return true }
            return false
        }
        guard !rows.isEmpty else { return .cantFire }

        // Partition by verdict and apply §5.14.4 reconciliation across
        // the supported set.
        let supportedRows = rows.filter { $0.isDeterministicallySupported }
        if !supportedRows.isEmpty {
            // Resolve gender from the snapshot. Falls through to
            // .ambiguous-shaped messaging if unresolved.
            let surnameForSubject = vm.selectedProfile?.lastName ?? ""
            let resolvedGender: Gender? = {
                // Pipeline-side reconciliation already used this ladder,
                // so the view can call it the same way for display.
                // FamilyGraphSnapshot has the children; childMMNs map is
                // empty here (the persisted Profile.mothersMaidenName
                // anchors the ladder's rule 2).
                guard let subjectID = vm.selectedProfile?.id else { return nil }
                let pseudoState = ResearchState(subject: ResearchSubject(
                    profileID: subjectID,
                    surname: surnameForSubject,
                    givenName: nil,
                    middleName: nil,
                    birthYearFrom: nil, birthYearTo: nil,
                    deathYearFrom: nil, deathYearTo: nil,
                    gender: vm.selectedProfile?.gender,
                    region: nil, mode: .extend, familyContext: nil,
                    // Pseudo-state for the gender resolver — doesn't
                    // consult chapman, so leave unset.
                    homeChapmanCode: ""
                ))
                let res = HypothesisEngine.resolveSubjectSpouseGender(
                    state: pseudoState, snapshot: appState.snapshot, childMMNs: [:]
                )
                return res.resolvedGender
            }()

            // Per-row recovery → picked-name reconciliation, mirroring
            // ResearchPipeline.reconcileAndApplyWriteback.
            struct Pick {
                let name: String
                let pair: String
                let year: Int?
                let quarter: String?
                let district: String?
            }
            var picks: [Pick] = []
            for h in supportedRows {
                guard case .subjectSpouseMarriage(let groom, let bride, _) = h.kind,
                      let recovery = HypothesisEngine.extractSubjectSpouseRecovery(
                        from: h, scoredRecords: result.allScoredRecords
                      )
                else { continue }
                guard let g = resolvedGender,
                      let picked = HypothesisEngine.pickSubjectGivenName(
                        from: recovery, resolvedGender: g
                      ), !picked.isEmpty
                else { continue }
                picks.append(Pick(
                    name: picked,
                    pair: "\(groom) × \(bride)",
                    year: recovery.matchedYear,
                    quarter: recovery.matchedQuarter,
                    district: recovery.matchedDistrict
                ))
            }
            if picks.isEmpty {
                // Supported rows exist but no gender-routed name —
                // treat as ambiguous-shaped messaging.
                guard case .subjectSpouseMarriage(let groom, let bride, let window) = supportedRows.first!.kind else {
                    return .cantFire
                }
                return .ambiguous(candidateCount: supportedRows.count, pair: "\(groom) × \(bride)", window: window)
            }
            let distinct = Set(picks.map { $0.name.lowercased() })
            if distinct.count == 1 {
                let first = picks.first!
                return .recovered(
                    name: first.name, pair: first.pair,
                    year: first.year, quarter: first.quarter, district: first.district
                )
            } else {
                let names = picks.map(\.name)
                return .conflict(names: names, pair: picks.first!.pair)
            }
        }

        // No supported. Prefer .inconclusive (ambiguous) over .contradicted
        // because ambiguous is actionable (user can disambiguate).
        let inconclusive = rows.filter { $0.verdict == .inconclusive }
        if let row = inconclusive.first,
           case .subjectSpouseMarriage(let groom, let bride, let window) = row.kind {
            return .ambiguous(
                candidateCount: row.supportingEvidence.count,
                pair: "\(groom) × \(bride)",
                window: window
            )
        }
        let contradicted = rows.filter { $0.verdict == .contradicted }
        if let row = contradicted.first,
           case .subjectSpouseMarriage(let groom, let bride, let window) = row.kind {
            return .noMatch(pair: "\(groom) × \(bride)", window: window)
        }
        return .cantFire
    }

    @ViewBuilder
    private func subjectSpouseMarriageBanner(_ state: SubjectSpouseMarriageBannerState) -> some View {
        let (icon, tint, title, body): (String, Color, String, String) = {
            switch state {
            case .recovered(let name, let pair, let year, let quarter, let district):
                // Build a "1882 Q3 Belper" suffix from whichever fields
                // the matched marriage record carried.
                var pieces: [String] = []
                if let year { pieces.append(String(year)) }
                if let quarter, !quarter.isEmpty { pieces.append("Q\(quarter)") }
                if let district, !district.isEmpty { pieces.append(district) }
                let locator = pieces.isEmpty ? "" : ", " + pieces.joined(separator: " ")
                return ("sparkles",
                        .green,
                        "Recovered given name '\(name)'",
                        "From BMD marriage \(pair)\(locator). The iteration loop used this name; review the new pending fact to persist it on the profile.")
            case .conflict(let names, let pair):
                let list = names.joined(separator: ", ")
                return ("exclamationmark.triangle.fill",
                        .orange,
                        "Multiple marriages recovered conflicting names",
                        "Found supported marriages for \(pair), but they recover different given names (\(list)). Write-back was blocked — open the hypotheses to disambiguate manually.")
            case .ambiguous(let count, let pair, let window):
                return ("questionmark.circle.fill",
                        .yellow,
                        "\(count) candidate marriage\(count == 1 ? "" : "s") for \(pair)",
                        "Near \(window.lowerBound)–\(window.upperBound). Given name not auto-set — open the hypothesis to disambiguate.")
            case .noMatch(let pair, let window):
                return ("magnifyingglass",
                        .secondary,
                        "No BMD marriage found for \(pair)",
                        "Searched \(window.lowerBound)–\(window.upperBound). Subject remains thin — manual research needed (older parish records, FamilySearch, etc.).")
            case .cantFire:
                return ("info.circle.fill",
                        .blue,
                        "This profile is too thin to research effectively",
                        "Add a given name in the profile editor, or link a child whose mother's-maiden-name is known. Without either anchor, the engine has no way to recover identifying detail from a surname alone.")
            }
        }()

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTypography.cardTitle)
                Text(body)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: - Source Frontier

    private var sourceFrontierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Frontier")
                .font(AppTypography.cardTitle)
                .foregroundStyle(.secondary)

            ForEach(vm.sourceStatuses) { status in
                HStack(spacing: 8) {
                    Image(systemName: status.state == .complete ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(status.state == .complete ? Color.green : Color.gray)
                    Text(status.displayName)
                        .font(AppTypography.cardBody)
                    Spacer()
                    if status.resultCount > 0 {
                        Text("\(status.resultCount) results")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = status.reason {
                        Text(reason)
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
