import SwiftUI

/// Review candidate life clusters from a research run.
/// Each cluster is a card showing records, confidence, and accept/reject actions.
struct ClusterReviewView: View {
    @Bindable var vm: ResearchViewModel
    let result: ResearchResult
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar
                .padding()
            Divider()

            if result.clusters.isEmpty && rejectedRecords.isEmpty {
                noCandidatesView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Proposed Relatives (parent inference from confirmed birth records)
                        if !visibleProposedRelatives.isEmpty {
                            proposedRelativesSection
                        }

                        ForEach(result.clusters) { cluster in
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

                        // Discoveries
                        if !discoveries.isEmpty {
                            discoveriesSection
                        }

                        // Source frontier
                        sourceFrontierSection
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Summary Bar

    @Environment(SourceRegistry.self) private var registry

    private var gpsScore: GPSScore {
        let sourceInfoMap = registry.buildSourceInfoMap()
        let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
        return GPSScorer.score(
            result: result,
            sourceInfoMap: sourceInfoMap,
            searchedSourceCount: searchedSources.count,
            totalSourceCount: registry.allSources().count
        )
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            if let profile = vm.selectedProfile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(AppTypography.cardTitle)
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

            Button("New Research") {
                vm.reset()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

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

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.displayName)
                        .font(AppTypography.cardTitle)
                    HStack(spacing: 8) {
                        confidenceBadge(cluster.confidence)
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
                        Text("\(cluster.records.count) records")
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
            }

            Divider()

            // Records
            ForEach(cluster.records, id: \.id) { scored in
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

            // Actions — "Save as lead" / "Discard" model (Task #41). The
            // decision is persisted to `evidence_records.user_status` so it
            // survives re-runs and across app restarts; previously cluster
            // decisions were in-memory only.
            HStack {
                if decision == .accepted {
                    Label("Saved as lead", systemImage: "bookmark.fill")
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

                if decision != .accepted {
                    Button("Save as lead") { vm.acceptCluster(cluster) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                if decision != .rejected {
                    Button("Discard") { vm.rejectCluster(cluster) }
                        .buttonStyle(.glass)
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
                                    Text(row.value)
                                        .font(AppTypography.badge)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
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
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
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

    private func confidenceBadge(_ confidence: ClusterConfidence) -> some View {
        let (label, color): (String, Color) = switch confidence {
        case .strong: ("Strong", .green)
        case .moderate: ("Moderate", .blue)
        case .weak: ("Weak", .orange)
        case .ambiguous: ("Ambiguous", .red)
        }

        return Text(label)
            .font(AppTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
    }

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
        vm.visibleProposedRelatives()
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

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: proposal.gender == .female ? "person.crop.circle" : "person.crop.circle.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(roleLabel): \(surnameLabel)")
                            .font(AppTypography.cardBody)
                        confidenceBadge(proposal.confidence)
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
                }
                Spacer()

                if alreadyLinked {
                    // Parent matching this proposal already exists in the tree
                    // (accepted in a previous research run). Don't offer Accept
                    // again — would duplicate. Show status instead.
                    Label("Already linked", systemImage: "link.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.blue)
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
        .opacity(decision == .rejected ? 0.5 : 1.0)
    }

    /// Expanded reasoning panel: what record drove this proposal, exactly how
    /// each field was derived, and a link to the originating record. The "how"
    /// section is the important part for ancestors you don't recognise on sight —
    /// it makes it clear that the father's surname is *inferred* from the subject,
    /// not read from the source.
    @ViewBuilder
    private func proposedRelativeDetail(_ proposal: ProposedRelative) -> some View {
        let evidence = proposal.evidence.first
        VStack(alignment: .leading, spacing: 8) {
            if let scored = evidence {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inferred from")
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
        if let given = proposal.proposedGivenName, !given.isEmpty {
            lines.append("Given name \"\(given.capitalized)\" found by matching a BMD marriage record where the surname pair (groom × bride) appears in both directions of the index with the same reference tuple.")
        } else if !proposal.ambiguousMarriages.isEmpty {
            lines.append("\(proposal.ambiguousMarriages.count) plausible marriages found in BMD index — given name can't be picked automatically. Choose one below to fill it in.")
        } else {
            lines.append("Given name not yet known — BMD birth index does not include either parent's given name, and no matching parent-marriage record was found in the BMD marriage index.")
        }
        return lines
    }

    /// Plain-English confidence explanation matching the badge.
    private func confidenceExplanation(_ proposal: ProposedRelative) -> String {
        switch proposal.confidence {
        case .strong:
            return "Strong — derived from a primary record that fully matched the subject."
        case .moderate:
            return "Moderate — derived from a transcribed record that fully matched the subject (verdict: fact)."
        case .weak:
            return "Weak — source record matched on name and date but at least one gate (geography or family context) softFailed, so the underlying record is a lead rather than a confirmed fact."
        case .ambiguous:
            return "Ambiguous — multiple plausible candidates or contradictions in the evidence."
        }
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
