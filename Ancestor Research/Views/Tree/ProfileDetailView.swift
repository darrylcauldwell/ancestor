import SwiftUI

/// Unified profile card — read inspector and edit form on the same surface,
/// rendered as a floating Liquid Glass card. The Edit button flips
/// `isEditing` in place: the shared layout switches `Text` → `TextField`,
/// the action row swaps to Cancel + Save Changes, and the heavy edit
/// machinery (per-field source picker, Correct/Alternative, citation)
/// slides in below.
///
/// Step 4 of `AncestorApp/PROFILE_VIEW_UNIFY_SPEC.md`: removes the modal
/// `EditPersonView` sheet from the inspector flow. External callsites
/// (audit / tree-graph context menu) still open `EditPersonView`, which is
/// now a thin sheet wrapper that hosts this view with
/// `startInEditMode: true`.
struct ProfileDetailView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var onSetRoot: (() -> Void)?
    /// Caller-provided dismissal. When non-nil, an X button renders in the
    /// card's top-right corner. The tree-graph host wires this up to
    /// `treeVM.showInspector = false`; the modal wrapper leaves it nil and
    /// relies on the sheet's own close affordance.
    var onClose: (() -> Void)?
    /// Skip the read inspector and open straight into edit mode. Used by
    /// `EditPersonView` (the sheet wrapper) so the audit / context-menu
    /// edit flows still land directly on the form.
    var startInEditMode: Bool = false
    /// RETIRE_POPOVER_SPEC Change 2 — tree-hosted navigation: tap a relative
    /// row to jump the tree to that person. Nil in sheet contexts (no tree).
    var onNavigateToProfile: ((String) -> Void)? = nil
    /// Pass-through for SharedProfileLayout's mode-switch hint.
    var navigateSwitchesMode: ((String) -> Bool)? = nil
    /// Marriage switcher (moved from the popover): the spouse whose marriage
    /// the tree currently shows, and the callback to switch it. Nil in sheet
    /// contexts. The on-canvas ordinal chips remain the primary switcher.
    var activeSpouseID: String? = nil
    var onSwitchMarriage: ((String) -> Void)? = nil

    @Environment(AppState.self) private var appState

    // MARK: - Edit-mode form state (moved from `EditPersonView`)

    @State private var isEditing: Bool = false
    @State private var firstName: String = ""
    @State private var middleName: String = ""
    @State private var lastName: String = ""
    @State private var marriedSurname: String = ""
    @State private var nickName: String = ""
    @State private var mothersMaidenName: String = ""
    @State private var gender: Gender = .unknown
    @State private var birthDateText: String = ""
    @State private var birthLocation: String = ""
    @State private var birthLocationCode: String? = nil
    @State private var deathDateText: String = ""
    @State private var deathLocation: String = ""
    @State private var deathLocationCode: String? = nil
    @State private var bio: String = ""

    @State private var defaultSource: SourceOrigin = .manualMemory
    @State private var sourcePerField: [ProfileField: SourceOrigin] = [:]
    @State private var fieldChoice: [ProfileField: ChangeMode] = [:]
    @State private var citation: Citation?
    @State private var quality: EvidenceQuality?
    @State private var original: OriginalSnapshot = .empty

    enum ChangeMode: String, Hashable {
        case correct
        case alternative
    }

    // MARK: - Read-mode sheets

    @State private var showingTimeline: Bool = false
    @State private var showingRelationshipCalculator: Bool = false
    @State private var cleansePresentation: CleansePresentation?
    /// Count of active leads this profile's research surfaced — the cheap
    /// signal behind the "Possible People (N)" section (the expensive
    /// clustering happens in the panel the section deep-links to).
    @State private var surfacedLeadCount: Int = 0
    // PROFILE_SOURCES_LEDGER_SPEC Change 2 — the records backing this person,
    // read from evidence_records with no research run.
    @State private var ledgerEntries: [ProfileSourcesLedger.Entry] = []
    @State private var ledgerExpanded: Bool = false
    // PROFILE_SOURCES_LEDGER_SPEC Change 3 — the entry pending removal
    // confirmation (nil = no dialog).
    @State private var ledgerRemovalCandidate: ProfileSourcesLedger.Entry?
    // PROFILE_SOURCES_LEDGER_SPEC Change 5 — the scroll anchor a muddle
    // finding's "Review records" deep-link targets.
    private static let ledgerAnchorID = "sourcesLedgerSection"
    // PROFILE_LIFECYCLE_SPEC Change 3 — the derived import→verified stage.
    @State private var lifecycle: ProfileLifecycle?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if onClose != nil {
                    closeButtonRow
                }

                SharedProfileLayout(
                    profile: profile,
                    snapshot: snapshot,
                    editable: isEditing,
                    bindings: isEditing ? makeBindings() : nil,
                    onNavigateToProfile: isEditing ? nil : onNavigateToProfile,
                    navigateSwitchesMode: isEditing ? nil : navigateSwitchesMode
                )

                if !isEditing {
                    marriageSwitcherSection
                    lifecycleChip
                }

                if isEditing {
                    sourceDetailsSection(profile: profile)
                    Divider()
                    sourceSection
                }

                if !isEditing && surfacedLeadCount > 0 {
                    Divider()
                    possiblePeopleSection
                }

                if !isEditing {
                    Divider()
                    sourcesLedgerSection
                        .id(Self.ledgerAnchorID)
                }

                Divider()
                actionRow
            }
            .padding(20)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        .onAppear {
            if startInEditMode {
                populate()
                isEditing = true
            }
            reloadSurfacedLeadCount()
            reloadLedger()
            consumePendingCardActionIfMine()
            consumeLedgerReviewIfMine(proxy: proxy)
        }
        .onChange(of: profile.id) { _, _ in
            // Selection changed — exit edit without saving and let the
            // next Edit click repopulate from the new profile. Preserves
            // the in-progress edit accidentally would invite a save against
            // the wrong subject.
            isEditing = false
            reloadSurfacedLeadCount()
            reloadLedger()
            consumePendingCardActionIfMine()
            consumeLedgerReviewIfMine(proxy: proxy)
        }
        .onChange(of: isEditing) { _, nowEditing in
            // Repopulate on every entry to edit mode so the form always
            // reflects the persisted profile, not a stale buffer from a
            // previous cancelled session.
            if nowEditing { populate() }
        }
        // Change 1 — perform a card-owned action raised from the tree context
        // menu (Edit / Timeline / Relationship / Cleanse), for THIS profile only.
        // Checked here AND in onAppear / profile-switch so it fires whatever the
        // mount ordering (card already open, freshly opened, or switched to).
        .onChange(of: appState.pendingCardAction) { _, _ in
            consumePendingCardActionIfMine()
        }
        .sheet(isPresented: $showingTimeline) {
            ProfileTimelineView(profileID: profile.id)
                .frame(minWidth: 540, minHeight: 600)
        }
        .sheet(isPresented: $showingRelationshipCalculator) {
            RelationshipCalculatorView(
                initialFromID: appState.currentProject?.homePersonID,
                initialTargetID: profile.id
            )
        }
        .sheet(item: $cleansePresentation) { presentation in
            ProfileCleanseWizard(mode: presentation.mode)
        }
        // PROFILE_SOURCES_LEDGER_SPEC Change 3 — per-record removal confirm.
        // presenting: pattern (not isPresented + force-unwrap) per the
        // sheet(isPresented:)+if-let race memory.
        .confirmationDialog(
            "Remove this record?",
            isPresented: Binding(
                get: { ledgerRemovalCandidate != nil },
                set: { if !$0 { ledgerRemovalCandidate = nil } }
            ),
            presenting: ledgerRemovalCandidate
        ) { entry in
            Button("Remove record", role: .destructive) {
                removeLedgerRecord(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Reverts what it established (\(entry.establishes.isEmpty ? "citations" : entry.establishes.joined(separator: ", "))), removes its life events, and remembers the rejection so research won't re-add it. The record stays in research history and can be re-applied later.")
        }
        // PROFILE_SOURCES_LEDGER_SPEC Change 5 — a "Review records" deep-link
        // may land after this card is already mounted for the profile, so
        // consume the intent on change too (not only on appear / switch).
        .onChange(of: appState.requestLedgerReviewProfileID) { _, _ in
            consumeLedgerReviewIfMine(proxy: proxy)
        }
        }
    }

    // MARK: - Layout pieces

    /// Marriage switcher (RETIRE_POPOVER_SPEC Change 2, moved from the
    /// popover): when the person has 2+ marriages, choose which one the tree
    /// shows (spouse + that marriage's children). Ordered earliest-first.
    /// Rendered only when the host wires the callback (tree contexts).
    @ViewBuilder
    private var marriageSwitcherSection: some View {
        if let onSwitchMarriage {
            let spouses = snapshot.spousesOrderedByMarriage(profile.id)
            if spouses.count >= 2 {
                let active = activeSpouseID ?? spouses.first?.id
                VStack(alignment: .leading, spacing: 6) {
                    Text("Showing marriage")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(Array(spouses.enumerated()), id: \.element.id) { pair in
                        let isActive = pair.element.id == active
                        Button {
                            onSwitchMarriage(pair.element.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                                Text("\(Self.ordinal(pair.offset + 1)) · \(pair.element.displayName)")
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    /// Raise a tree-owned intent: set it, then request the tree tab so the
    /// observing `TreeGraphView` is mounted (its onAppear drains pending
    /// intents). Without the tab switch, a raise from a sheet hosted on
    /// another tab (e.g. the audit flow's EditPersonView) does nothing.
    private func raiseTreeIntent(_ set: () -> Void) {
        set()
        appState.requestSidebarTab = .tree
    }

    private var closeButtonRow: some View {
        HStack {
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Close")
            .accessibilityLabel("Close profile")
        }
    }

    /// Lightweight discovery pointer (POSSIBLE_PEOPLE_CONTEXT_SPEC step 4):
    /// signals that this person's research surfaced candidate people, and
    /// deep-links into the Possible People panel scoped to them — where the
    /// actual clustering + assessment happens. A summary, not a second copy
    /// of the interactive cards.
    private var possiblePeopleSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Possible People")
                    .font(AppTypography.cardTitle)
                Text("\(surfacedLeadCount) lead\(surfacedLeadCount == 1 ? "" : "s") from this person's research — candidate people to review")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.requestPossiblePeopleProfileID = profile.id
                appState.requestSidebarTab = .triage
            } label: {
                Label("Explore", systemImage: "arrow.right")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
    }

    private func reloadSurfacedLeadCount() {
        guard let db = appState.currentDatabase else { surfacedLeadCount = 0; return }
        let leads = (try? db.loadLeads(profileID: profile.id)) ?? []
        surfacedLeadCount = leads.filter {
            $0.status == .new || $0.status == .investigating || $0.status == .investigated
        }.count
    }

    // MARK: - Sources & Records ledger (PROFILE_SOURCES_LEDGER_SPEC Change 2)

    private func reloadLedger() {
        guard let db = appState.currentDatabase else { ledgerEntries = []; lifecycle = nil; return }
        ledgerEntries = (try? ProfileSourcesLedger.entries(for: profile.id, db: db, profile: profile)) ?? []
        // Derive the lifecycle stage from what we already hold (Change 3). GPS
        // isn't computed here yet, so `gpsStrong: false` keeps a person at
        // "evidenced" rather than falsely claiming "verified" — honest by
        // construction; wiring GPS is a follow-up.
        let evidenceCount = (try? db.evidenceCountForProfile(profile.id)) ?? 0
        lifecycle = ProfileLifecycle.evaluate(
            hasResearchEvidence: evidenceCount > 0,
            pendingReview: surfacedLeadCount,
            appliedRecords: ledgerEntries.count,
            gpsStrong: false)
    }

    @ViewBuilder private var lifecycleChip: some View {
        if let lifecycle {
            HStack(spacing: 8) {
                Circle().fill(stageColor(lifecycle.stage)).frame(width: 9, height: 9)
                Text(lifecycle.headline)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.primary)
                Spacer()
                Text(lifecycle.stage.rawValue.capitalized)
                    .font(AppTypography.badge)
                    .foregroundStyle(stageColor(lifecycle.stage))
            }
            .padding(8)
            .background(stageColor(lifecycle.stage).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func stageColor(_ stage: ProfileLifecycleStage) -> Color {
        switch stage {
        case .imported:    return .gray
        case .researching: return .orange
        case .evidenced:   return .blue
        case .verified:    return .green
        }
    }

    /// Perform a card-owned action (Change 1) — the same effect as the
    /// action-row buttons, so the tree context menu and the card share one set.
    private func performCardAction(_ action: ProfileCardAction) {
        switch action {
        case .edit:         isEditing = true
        case .timeline:     showingTimeline = true
        case .relationship: showingRelationshipCalculator = true
        case .cleanse:      cleansePresentation = .singleProfile(profile.id)
        }
    }

    /// Consume a context-menu-raised card action if it targets THIS profile.
    /// Called from every mount/switch path so ordering never drops it.
    private func consumePendingCardActionIfMine() {
        guard let pending = appState.pendingCardAction, pending.profileID == profile.id else { return }
        performCardAction(pending.action)
        appState.pendingCardAction = nil
    }

    /// Read-only list of the records that back this person — full citation +
    /// what each one established — with no research run. When empty, says so
    /// honestly rather than hiding (the profile's data came from the import).
    private var sourcesLedgerSection: some View {
        DisclosureGroup(isExpanded: $ledgerExpanded) {
            if ledgerEntries.isEmpty {
                Text("No research records applied yet — this profile's data comes from the original import. Run research to find records.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ledgerEntries) { entry in
                        ledgerRow(entry)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                Text("Sources & Records").font(AppTypography.cardTitle)
                if !ledgerEntries.isEmpty {
                    Text("\(ledgerEntries.count)")
                        .font(AppTypography.badge)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    private func ledgerRow(_ entry: ProfileSourcesLedger.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.recordType.rawValue.uppercased())
                    .font(AppTypography.badge)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Text(entry.sourceID.uppercased())
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                Spacer()
                // Click-through to the original record at the source (e.g. the
                // FindAGrave memorial or the CWGC casualty page). The URL is the
                // record's detailURL, carried on the evidence row's citation —
                // link-only by design (we never copy the source's content).
                // Hidden when the record carried no URL.
                if let urlStr = entry.citationURL, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Text("View record")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(AppTypography.badge)
                    }
                    .help("Open the original record at \(url.host ?? "the source")")
                }
                Button {
                    ledgerRemovalCandidate = entry
                } label: {
                    Image(systemName: "trash")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this record — reverts what it established and remembers the rejection")
            }
            if !entry.establishes.isEmpty {
                Text("Establishes: \(entry.establishes.joined(separator: " · "))")
                    .font(AppTypography.cardBody)
            }
            Text(entry.citation)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// PROFILE_SOURCES_LEDGER_SPEC Change 3 — confirm-then-remove for one
    /// applied record: reverts its absorption, feeds rejection memory, and
    /// refreshes the ledger. The record itself stays in research history, so
    /// removal is reversible by re-applying from research.
    private func removeLedgerRecord(_ entry: ProfileSourcesLedger.Entry) {
        guard let db = appState.currentDatabase,
              let evidence = (try? db.loadEvidenceForProfile(profile.id))?
                  .first(where: { $0.sourceRecordID == entry.id && $0.userStatus == .savedAsLead })
        else { return }
        appState.removeAppliedRecord(evidence)
        reloadLedger()
    }

    /// PROFILE_SOURCES_LEDGER_SPEC Change 5 — honour a muddle finding's
    /// "Review records" deep-link when it targets THIS profile: expand the
    /// Sources & Records section and scroll it into view (it sits near the
    /// bottom of a long card), then clear the intent. The scroll waits a
    /// runloop hop so the DisclosureGroup's expanded content lays out first.
    private func consumeLedgerReviewIfMine(proxy: ScrollViewProxy) {
        guard appState.requestLedgerReviewProfileID == profile.id else { return }
        appState.requestLedgerReviewProfileID = nil
        ledgerExpanded = true
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(Self.ledgerAnchorID, anchor: .top) }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if isEditing {
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    save()
                    isEditing = false
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(!hasChanges || !namesWithinLimit)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            // Two rows so the labels stay readable (six buttons on one row
            // truncated to "Time…", "Relat…", "Rese…", "Clea…" — owner report
            // 2026-07-17). Row 1 = inspect, row 2 = act, with the prominent
            // Focus Here anchored right.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Edit") {
                        isEditing = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        showingTimeline = true
                    } label: {
                        Label("Timeline", systemImage: "calendar")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        showingRelationshipCalculator = true
                    } label: {
                        Label("Relationship to…", systemImage: "person.2")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        appState.researchConfigProfile = profile
                    } label: {
                        Label("Research", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        cleansePresentation = .singleProfile(profile.id)
                    } label: {
                        Label("Cleanse", systemImage: "sparkles")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    // Change 1 — the two tree-centric actions, so the card offers
                    // the SAME set as the right-click menu (kept in a compact
                    // "More" menu rather than a 7th/8th full-width button).
                    Menu {
                        // RETIRE_POPOVER_SPEC Change 1 — add-relative + remove
                        // move here (and to the right-click menu) off the popover.
                        // The tree owns the add sheets, so these set intents it
                        // observes, mirroring "Compare with…".
                        // Each of these is a TREE-owned intent: raise it AND
                        // request the tree tab (M16.9 pattern), so the
                        // observer is mounted even when this card is hosted
                        // in another tab's sheet — otherwise the raise is a
                        // silent no-op and the stale Equatable value would
                        // suppress the next identical request.
                        // On-demand FamilySearch hint enrichment (S6b) — drained
                        // in ContentView (always mounted), so no tree-intent hop.
                        Button("Fetch FamilySearch hints") { appState.requestFetchFSHints = profile.id }
                        if let freeREG = URL(string: "https://www.freereg.org.uk/search_queries/new") {
                            Link("Search FreeREG", destination: freeREG)
                        }
                        Divider()
                        Button("Add Spouse") { raiseTreeIntent { appState.requestAddRelative = .init(profileID: profile.id, relation: .spouse) } }
                        Button("Add Child") { raiseTreeIntent { appState.requestAddRelative = .init(profileID: profile.id, relation: .child) } }
                        Button("Add Parent") { raiseTreeIntent { appState.requestAddRelative = .init(profileID: profile.id, relation: .parent) } }
                        Button("Add Sibling") { raiseTreeIntent { appState.requestAddRelative = .init(profileID: profile.id, relation: .sibling) } }
                        Button("Connect to existing person…") { raiseTreeIntent { appState.requestConnectExisting = profile.id } }
                        Divider()
                        Button("Compare with…") { raiseTreeIntent { appState.requestCompareProfileID = profile.id } }
                        Button("Set as Home Person") { appState.setHomePerson(id: profile.id) }
                            .disabled(profile.id == appState.currentProject?.homePersonID)
                        // RETIRE_POPOVER_SPEC Change 2 — W3 focus toggle,
                        // moved from the popover. Only shown while a focus
                        // set is active (same gating the popover used).
                        if appState.activeFocusSet != nil {
                            if appState.isInActiveFocus(profile.id) {
                                Button("Remove from Focus") {
                                    appState.removeProfileFromActiveFocus(profile.id)
                                }
                            } else {
                                Button("Add to Focus") {
                                    appState.addProfileToActiveFocus(profile.id)
                                }
                            }
                        }
                        Divider()
                        Button("Remove Person", role: .destructive) {
                            appState.softDeleteProfile(id: profile.id)
                            onClose?()
                        }
                        // Branch removal parity with the context menu — the
                        // tree owns the staged confirmation, so these raise
                        // an intent it observes (mirroring Compare/Add).
                        Menu("Remove Branch") {
                            Button("Remove person and ancestors", role: .destructive) {
                                raiseTreeIntent { appState.requestRemoveBranch = .init(profileID: profile.id, ancestors: true) }
                            }
                            Button("Remove person and descendants", role: .destructive) {
                                raiseTreeIntent { appState.requestRemoveBranch = .init(profileID: profile.id, ancestors: false) }
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()

                    if let setRoot = onSetRoot {
                        // Same action as the popover's Focus Here and the
                        // canvas right-click → Focus Here. Vocabulary
                        // harmonised so the user finds it in any surface
                        // they reach for.
                        Button("Focus Here") {
                            setRoot()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Edit machinery

    private func makeBindings() -> ProfileEditBindings {
        ProfileEditBindings(
            firstName: $firstName,
            middleName: $middleName,
            lastName: $lastName,
            marriedSurname: $marriedSurname,
            nickName: $nickName,
            mothersMaidenName: $mothersMaidenName,
            gender: $gender,
            birthDateText: $birthDateText,
            birthLocation: $birthLocation,
            birthLocationCode: $birthLocationCode,
            deathDateText: $deathDateText,
            deathLocation: $deathLocation,
            deathLocationCode: $deathLocationCode,
            bio: $bio
        )
    }

    /// Per-changed-field source picker + Correct/Alternative toggle. Mirrors
    /// the prior `EditPersonView` implementation — empty when nothing has
    /// changed, so the card stays quiet until the user touches a field.
    @ViewBuilder
    private func sourceDetailsSection(profile: Profile) -> some View {
        let changedFields = ProfileField.allCases.filter { fieldChanged($0, profile: profile) }
        if !changedFields.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Source details for changed fields")
                ForEach(changedFields, id: \.self) { field in
                    changedFieldRow(field: field, profile: profile)
                }
            }
        }
    }

    @ViewBuilder
    private func changedFieldRow(field: ProfileField, profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayLabel(for: field))
                .font(AppTypography.cardMeta.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SourcePicker(
                    selection: Binding(
                        get: { sourcePerField[field] ?? defaultSource },
                        set: { sourcePerField[field] = $0 }
                    ),
                    label: "Source"
                )
                .pickerStyle(.menu)
                .controlSize(.small)

                if hasImportedSource(field, profile: profile) {
                    Picker("", selection: Binding(
                        get: { fieldChoice[field] ?? .correct },
                        set: { fieldChoice[field] = $0 }
                    )) {
                        Text("Correct").tag(ChangeMode.correct)
                        Text("Alternative").tag(ChangeMode.alternative)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                }
            }
        }
    }

    private func displayLabel(for field: ProfileField) -> String {
        switch field {
        case .firstName: return "First name"
        case .middleName: return "Middle name"
        case .lastName: return "Last name"
        case .marriedSurname: return "Married surname"
        case .nickName: return "Known as"
        case .mothersMaidenName: return "Mother's maiden name"
        case .gender: return "Gender"
        case .birthDate: return "Birth date"
        case .birthLocation: return "Birth location"
        case .deathDate: return "Death date"
        case .deathLocation: return "Death location"
        case .bio: return "Biography"
        case .nameForms: return "Name variants"
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Default source for this edit")
            SourcePicker(selection: $defaultSource)
                .pickerStyle(.menu)
                .onChange(of: defaultSource) { _, newValue in
                    for field in ProfileField.allCases where sourcePerField[field] == nil {
                        sourcePerField[field] = newValue
                    }
                }
            Text("Set per field above — this default applies to fields you don't override.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
            CitationEntryView(
                citation: $citation,
                quality: $quality,
                repositorySuggestions: CitationSuggestService.repositories(snapshot: appState.snapshot),
                collectionSuggestions: CitationSuggestService.collections(snapshot: appState.snapshot)
            )
        }
    }

    private func hasImportedSource(_ field: ProfileField, profile: Profile) -> Bool {
        (profile.sources[field] ?? []).contains { !$0.origin.isManual }
    }

    private func fieldChanged(_ field: ProfileField, profile: Profile) -> Bool {
        switch field {
        case .firstName: return AutoSuggestService.normaliseName(firstName) != original.firstName
        case .middleName: return AutoSuggestService.normaliseName(middleName) != original.middleName
        case .lastName: return AutoSuggestService.normaliseName(lastName) != original.lastName
        case .marriedSurname: return AutoSuggestService.normaliseName(marriedSurname) != original.marriedSurname
        case .nickName: return AutoSuggestService.normaliseName(nickName) != original.nickName
        case .mothersMaidenName: return AutoSuggestService.normaliseName(mothersMaidenName) != original.mothersMaidenName
        case .gender:
            let g: Gender? = gender == .unknown ? nil : gender
            return g != original.gender
        case .birthDate:
            return GenealogicalDate.parsePreview(birthDateText).parsed != original.birthDate
        case .birthLocation:
            return AutoSuggestService.normaliseName(birthLocation) != original.birthLocation
        case .deathDate:
            return GenealogicalDate.parsePreview(deathDateText).parsed != original.deathDate
        case .deathLocation:
            return AutoSuggestService.normaliseName(deathLocation) != original.deathLocation
        case .bio:
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            let new: String? = trimmed.isEmpty ? nil : trimmed
            return new != original.bio
        // This flat-field editor never edits name forms, so it never reports a
        // change for them; name-form edits will land through their own section.
        case .nameForms:
            return false
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Populate the form state from the current profile. Called on entry
    /// to edit mode (and on initial appearance when `startInEditMode` is
    /// true). Idempotent — safe to call repeatedly.
    private func populate() {
        firstName = profile.firstName ?? ""
        middleName = profile.middleName ?? ""
        lastName = profile.lastName ?? ""
        marriedSurname = profile.marriedSurname ?? ""
        nickName = profile.nickName ?? ""
        mothersMaidenName = profile.mothersMaidenName ?? ""
        gender = profile.gender ?? .unknown
        birthDateText = profile.birthDate?.original ?? ""
        birthLocation = profile.birthLocation ?? ""
        birthLocationCode = profile.birthLocationCode
        deathDateText = profile.deathDate?.original ?? ""
        deathLocation = profile.deathLocation ?? ""
        deathLocationCode = profile.deathLocationCode
        bio = profile.bio ?? ""
        original = OriginalSnapshot(
            firstName: profile.firstName,
            middleName: profile.middleName,
            lastName: profile.lastName,
            marriedSurname: profile.marriedSurname,
            nickName: profile.nickName,
            mothersMaidenName: profile.mothersMaidenName,
            gender: profile.gender,
            birthDate: profile.birthDate,
            birthLocation: profile.birthLocation,
            deathDate: profile.deathDate,
            deathLocation: profile.deathLocation,
            bio: profile.bio
        )
        // Reset per-field overrides and choice buffers for this edit session.
        citation = nil
        quality = nil
        fieldChoice = [:]
        defaultSource = SourceDefaults.defaultSource(
            context: .relativeOf(
                profileID: profile.id,
                primarySource: profile.primarySource
            )
        )
        sourcePerField = [:]
        for field in ProfileField.allCases {
            sourcePerField[field] = defaultSource
        }
    }

    private var hasChanges: Bool {
        !buildChanges().isEmpty || !buildDateChanges().isEmpty
    }

    private var namesWithinLimit: Bool {
        firstName.count <= AutoSuggestService.nameHardLimitLength
            && lastName.count <= AutoSuggestService.nameHardLimitLength
    }

    private func buildChanges() -> [(field: ProfileField, oldValue: String?, newValue: String?)] {
        var changes: [(ProfileField, String?, String?)] = []
        let newFirst = AutoSuggestService.normaliseName(firstName)
        if newFirst != original.firstName {
            changes.append((.firstName, original.firstName, newFirst))
        }
        let newMiddle = AutoSuggestService.normaliseName(middleName)
        if newMiddle != original.middleName {
            changes.append((.middleName, original.middleName, newMiddle))
        }
        let newLast = AutoSuggestService.normaliseName(lastName)
        if newLast != original.lastName {
            changes.append((.lastName, original.lastName, newLast))
        }
        let newMarried = AutoSuggestService.normaliseName(marriedSurname)
        if newMarried != original.marriedSurname {
            changes.append((.marriedSurname, original.marriedSurname, newMarried))
        }
        let newNick = AutoSuggestService.normaliseName(nickName)
        if newNick != original.nickName {
            changes.append((.nickName, original.nickName, newNick))
        }
        let newMMN = AutoSuggestService.normaliseName(mothersMaidenName)
        if newMMN != original.mothersMaidenName {
            changes.append((.mothersMaidenName, original.mothersMaidenName, newMMN))
        }
        let newGender: Gender? = gender == .unknown ? nil : gender
        if newGender != original.gender {
            changes.append((.gender, original.gender?.rawValue, newGender?.rawValue))
        }
        let newBirthLoc = AutoSuggestService.normaliseName(birthLocation)
        if newBirthLoc != original.birthLocation {
            changes.append((.birthLocation, original.birthLocation, newBirthLoc))
        }
        let newDeathLoc = AutoSuggestService.normaliseName(deathLocation)
        if newDeathLoc != original.deathLocation {
            changes.append((.deathLocation, original.deathLocation, newDeathLoc))
        }
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBio: String? = trimmedBio.isEmpty ? nil : trimmedBio
        if newBio != original.bio {
            changes.append((.bio, original.bio, newBio))
        }
        return changes.map { ($0.0, $0.1, $0.2) }
    }

    private func buildDateChanges() -> [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)] {
        var dateChanges: [(ProfileField, GenealogicalDate?, GenealogicalDate?)] = []
        let newBirth = GenealogicalDate.parsePreview(birthDateText).parsed
        if newBirth != original.birthDate {
            dateChanges.append((.birthDate, original.birthDate, newBirth))
        }
        let newDeath = GenealogicalDate.parsePreview(deathDateText).parsed
        if newDeath != original.deathDate {
            dateChanges.append((.deathDate, original.deathDate, newDeath))
        }
        return dateChanges.map { ($0.0, $0.1, $0.2) }
    }

    private func save() {
        let allChanges = buildChanges()
        let allDateChanges = buildDateChanges()

        let correctChanges = allChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }
        let correctDateChanges = allDateChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }

        if !correctChanges.isEmpty || !correctDateChanges.isEmpty {
            appState.editProfile(
                id: profile.id,
                changes: correctChanges,
                dateChanges: correctDateChanges,
                source: defaultSource,
                sourceByField: sourcePerField
            )
        }

        if let db = appState.currentDatabase {
            try? db.updateProfileLocationCodes(
                profileID: profile.id,
                birthCode: birthLocationCode,
                deathCode: deathLocationCode
            )
        }

        for change in allChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            if let raw = change.newValue, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profile.id, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }
        for change in allDateChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            if let raw = change.newDate?.original, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profile.id, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }

        let hasCitation = (citation != nil && !(citation?.isEmpty ?? true)) || quality != nil
        if hasCitation {
            let changedFields: [ProfileField] = allChanges.map(\.field) + allDateChanges.map(\.field)
            for field in changedFields {
                appState.attachCitation(
                    profileID: profile.id, field: field,
                    origin: sourcePerField[field] ?? defaultSource,
                    citation: citation, quality: quality
                )
            }
        }
    }

    private struct OriginalSnapshot {
        var firstName: String?
        var middleName: String?
        var lastName: String?
        var marriedSurname: String?
        var nickName: String?
        var mothersMaidenName: String?
        var gender: Gender?
        var birthDate: GenealogicalDate?
        var birthLocation: String?
        var deathDate: GenealogicalDate?
        var deathLocation: String?
        var bio: String?

        static let empty = OriginalSnapshot()
    }
}
