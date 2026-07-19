import SwiftUI

/// Focus context — determines which keyboard handlers are active.
private enum TreeFocus: Hashable {
    case canvas
    case search
}

/// Interactive family tree visualisation using Canvas.
/// Shows a window of generations around a focal person.
/// Click to select, click again or Space to inspect, Return to recenter.
struct TreeGraphView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    /// M24 — Honoured by the recenter slide and popover/banner transitions
    /// to avoid triggering vestibular issues for users with the system
    /// "Reduce motion" preference enabled.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var treeVM = TreeViewModel()
    @FocusState private var focus: TreeFocus?
    /// Whether the toolbar profile-search field is expanded (vs its compact
    /// magnifying-glass icon). Toggled by the search button and the ⌘F shortcut.
    @State private var searchExpanded = false
    @AppStorage("coachMarkShownCount") private var coachMarkShownCount: Int = 0
    @AppStorage("selectionCount") private var selectionCount: Int = 0
    /// M16.11 — Settings toggle hides note dots, question markers, focus
    /// rings, and tentative-fact glyphs from the canvas. Defaults on.
    @AppStorage("showResearchIndicators") private var showResearchIndicators: Bool = true
    @State private var showCoachMark: Bool = false

    // Manual entry sheets
    @State private var showAddPerson: Bool = false
    @State private var showAddFamily: Bool = false
    @State private var addPersonContext: AddPersonContext = .freestanding
    /// Edit-person and add-relationship sheets are driven by Identifiable
    /// wrappers via `.sheet(item:)` rather than (Bool, String?) pairs. The
    /// old pattern — `.sheet(isPresented: $showEditPerson) { if let id = editProfileID { … } }`
    /// could render EmptyView when SwiftUI evaluated the closure before the
    /// String? binding settled, producing a collapsed empty-rectangle sheet.
    @State private var editProfileID: SheetID?
    @State private var relationshipAnchorID: SheetID?

    /// Identifiable wrapper so a profile-ID string can drive `.sheet(item:)`.
    /// SwiftUI keys the sheet by `id`, so the inner view only ever renders
    /// with a non-nil ID and avoids the EmptyView race.
    /// Fonts + platform accent for the shared Canvas renderer.
    /// AppTypography stays app-side; viewer targets build their own theme.
    static let canvasTheme = TreeCanvasTheme(
        name: AppTypography.canvasName,
        nameSmall: AppTypography.canvasNameSmall,
        dates: AppTypography.canvasDates,
        location: AppTypography.canvasLocation,
        badge: AppTypography.canvasBadge,
        infoIcon: AppTypography.canvasInfoIcon,
        arrow: AppTypography.canvasArrow,
        controlAccent: Color(.controlAccentColor)
    )

    struct SheetID: Identifiable, Hashable {
        let id: String
    }

    @State private var dismissedDisconnectedBanner: Bool = false

    // M19 — comparison sheet state. `comparePickerSource` carries the profile
    // the user right-clicked on; `compareSheetIDs` carries both once the
    // counterpart is picked.
    @State private var comparePickerSource: ComparePickerSource?
    @State private var compareSheetIDs: ComparePair?

    /// Identifiable wrapper so the picker uses `.sheet(item:)` rather than
    /// `.sheet(isPresented:) + if let`, which renders an empty EmptyView
    /// rectangle when the inner binding hasn't settled at presentation time
    /// (memory `feedback_sheet_isPresented_race`).
    private struct ComparePickerSource: Identifiable {
        /// The left (right-clicked) profile's ID; doubles as the identity.
        let id: String
    }

    /// Identifiable wrapper so the sheet uses `item:` and reliably presents
    /// once both IDs are known (avoids the timing pitfalls of two `Bool`s).
    private struct ComparePair: Identifiable {
        let id = UUID()
        let leftID: String
        let rightID: String
    }

    private enum AddPersonContext {
        case freestanding
        case relative(id: String, relation: AutoSuggestService.RelationContext)
    }

    var body: some View {
        GeometryReader { geo in
            let canvasSize = geo.size

            ZStack(alignment: .topTrailing) {
                ZStack {
                    // Layer 1: Canvas
                    treeCanvas(canvasSize: canvasSize)
                        // M24 — VoiceOver mirror. Canvas is opaque to assistive
                        // tech, so we expose each visible profile as an
                        // off-screen accessibility element. The visual layout
                        // is unaffected.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Family tree canvas")
                        .accessibilityHint("Contains \(treeVM.layout.nodes.count) profiles. Use VoiceOver to step through them.")
                        .background(treeAccessibilityMirror)
                        .gesture(panGesture)
                        .gesture(magnifyGesture)
                        .focusable()
                        .focused($focus, equals: .canvas)
                        .onKeyPress(.space) {
                            guard focus == .canvas else { return .ignored }
                            return handleSpace()
                        }
                        .onKeyPress(.return) {
                            guard focus == .canvas else { return .ignored }
                            return handleReturn(canvasSize: canvasSize)
                        }
                        .onKeyPress(.escape) {
                            return handleEscape()
                        }
                        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                            guard focus == .canvas else { return .ignored }
                            return handleArrowKey(press, canvasSize: canvasSize)
                        }
                        // Double-click before single-click so SwiftUI's
                        // gesture disambiguator routes two-tap sequences here
                        // and leaves count:1 for genuine single clicks.
                        // Double-click skips the popover entirely and opens
                        // the full Profile Detail sheet — the popover is for
                        // peek-style inspection, the sheet is for working in.
                        .onTapGesture(count: 2) { location in
                            handleDoubleClick(at: location, canvasSize: canvasSize)
                        }
                        .onTapGesture(count: 1) { location in
                            handleSingleClick(at: location, canvasSize: canvasSize)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let result = treeVM.hitTest(at: location, canvasSize: canvasSize)
                                switch result {
                                case .nodeBody(let id), .infoIcon(let id), .arrowIndicator(let id),
                                     .ancestorIndicator(let id), .descendantIndicator(let id):
                                    treeVM.hoveredNodeID = id
                                case .empty:
                                    treeVM.hoveredNodeID = nil
                                }
                            case .ended:
                                treeVM.hoveredNodeID = nil
                            }
                        }
                        // M19 — right-click on a node to compare it with another
                        // profile. Falls back to the selected profile when the
                        // hover ID is missing (e.g., trackpad two-finger click
                        // away from the most recent hover position).
                        .contextMenu {
                            let anchorID = treeVM.hoveredNodeID ?? treeVM.selectedProfileID
                            if let anchorID,
                               let anchorProfile = appState.snapshot.profiles[anchorID] {
                                // PROFILE_LIFECYCLE_SPEC Change 1 — the right-click
                                // menu offers the SAME canonical action set as the
                                // profile card, so actions never vanish depending
                                // on how you reached the person. Card-owned actions
                                // (Edit/Timeline/Relationship/Cleanse) open the card
                                // and hand it a `pendingCardAction`; the rest route
                                // through their existing intents.
                                Button("Focus Here") {
                                    treeVM.recenter(
                                        on: anchorID,
                                        snapshot: appState.snapshot,
                                        canvasSize: treeVM.lastCanvasSize,
                                        reduceMotion: reduceMotion
                                    )
                                }
                                .disabled(anchorID == treeVM.rootProfileID)

                                Button("Research") { appState.researchConfigProfile = anchorProfile }
                                Button("Compare with…") {
                                    comparePickerSource = ComparePickerSource(id: anchorID)
                                }

                                Divider()
                                Button("Edit") { openCardAction(anchorID, .edit) }
                                Button("Timeline") { openCardAction(anchorID, .timeline) }
                                Button("Relationship to…") { openCardAction(anchorID, .relationship) }
                                Button("Cleanse") { openCardAction(anchorID, .cleanse) }

                                Divider()
                                // The home person anchors the relationship
                                // calculator and becomes the published
                                // manifest's rootPerson — without it viewers
                                // fall back to the best-connected person.
                                Button("Set as Home Person") {
                                    appState.setHomePerson(id: anchorID)
                                }
                                .disabled(anchorID == appState.currentProject?.homePersonID)
                            }
                        }

                    // Layer 2: Popover overlay
                    popoverOverlay(canvasSize: canvasSize)

                    // Layer 3: Controls overlay
                    controlsOverlay(canvasSize: canvasSize)
                }
                .onAppear {
                    focus = .canvas
                    treeVM.lastCanvasSize = canvasSize
                    // Honour any cross-view "open this profile's detail"
                    // request that fired while another tab was visible.
                    // The Tasks list raises this when the user clicks
                    // a row's label area; the tab switches to .tree and
                    // we land here with the request pending.
                    handlePendingProfileDetailRequest()
                }
                .onChange(of: canvasSize) { _, newSize in
                    treeVM.lastCanvasSize = newSize
                }
                .onChange(of: appState.requestOpenProfileDetail) { _, _ in
                    // Also fires when the tab is already .tree and the
                    // user clicks a Tasks row from a sidebar that's
                    // still visible (rare on macOS where the sidebar
                    // and detail render side-by-side, but cheap).
                    handlePendingProfileDetailRequest()
                }
                // Change 1 — the profile card raising "Compare with…" (only the
                // tree can present the picker). Opens it for the requested id.
                .onChange(of: appState.requestCompareProfileID) { _, newValue in
                    guard let id = newValue else { return }
                    comparePickerSource = ComparePickerSource(id: id)
                    appState.requestCompareProfileID = nil
                }

                // Floating profile card. Overlays the tree canvas in the
                // top-right corner; the card itself carries the Liquid
                // Glass chrome. Read and edit modes share the surface — the
                // Edit button on the card flips its `isEditing` toggle
                // rather than presenting a separate sheet.
                if treeVM.showInspector,
                   let selectedID = treeVM.selectedProfileID,
                   let profile = appState.snapshot.profiles[selectedID] {
                    ProfileDetailView(
                        profile: profile,
                        snapshot: appState.snapshot,
                        onSetRoot: {
                            treeVM.recenter(on: selectedID, snapshot: appState.snapshot,
                                           canvasSize: treeVM.lastCanvasSize,
                                           reduceMotion: reduceMotion)
                        },
                        onClose: {
                            treeVM.showInspector = false
                        }
                    )
                    // Opening a profile is a "read the detail" mode, so give the
                    // card room — responsive up to ~60% of the canvas (capped so
                    // it never dominates a very wide window), with the close (X)
                    // returning to the full tree.
                    .frame(minWidth: 420, idealWidth: 560,
                           maxWidth: max(480, min(canvasSize.width * 0.6, 760)),
                           maxHeight: canvasSize.height - 32)
                    .padding(16)
                }
            }
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .topLeading) {
            // Profile search lives in the content layer (not the toolbar) so its
            // results dropdown renders ABOVE the canvas — a toolbar item clips it.
            // Compact magnifying-glass icon that expands to a field; also ⌘F.
            TreeSearchField(
                searchText: $treeVM.searchText,
                allProfiles: Array(appState.snapshot.profiles.values),
                snapshot: appState.snapshot,
                currentViewMode: treeVM.viewMode,
                onSelect: { profileID in
                    treeVM.recenter(on: profileID, snapshot: appState.snapshot,
                                   canvasSize: treeVM.lastCanvasSize,
                                   reduceMotion: reduceMotion)
                    searchExpanded = false
                    focus = .canvas
                },
                isExpanded: $searchExpanded
            )
            .padding(.top, 10)
            .padding(.leading, 12)
        }
        .background {
            // ⌘F opens/focuses the profile search from anywhere in the Tree view.
            // Hidden button — present only to register the shortcut.
            Button("Search people") { searchExpanded = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onAppear {
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
            // Mirror the initial selection into AppState so Cmd+E works
            // immediately after the tree appears (without waiting for an
            // explicit selection change).
            appState.selectedProfileID = treeVM.selectedProfileID
        }
        .onChange(of: appState.snapshot.profiles.count) {
            treeVM.validateState(snapshot: appState.snapshot)
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
        .sheet(isPresented: $showAddPerson) {
            switch addPersonContext {
            case .freestanding:
                AddPersonView()
            case .relative(let id, let relation):
                AddPersonView(
                    relatedToID: id,
                    relation: relation,
                    context: contextFor(relatedToID: id, relation: relation)
                )
            }
        }
        .sheet(isPresented: $showAddFamily) {
            AddFamilyView()
        }
        .sheet(item: $editProfileID) { sheetID in
            EditPersonView(profileID: sheetID.id)
        }
        .sheet(item: $relationshipAnchorID) { sheetID in
            AddRelationshipView(anchorID: sheetID.id)
        }
        // M19 — pick the right-hand profile, then present the comparison.
        // `.sheet(item:)` (not `isPresented: + if let`) so the picker only
        // exists when the source ID does — avoids the empty-rectangle race.
        .sheet(item: $comparePickerSource) { source in
            if let leftProfile = appState.snapshot.profiles[source.id] {
                CompareTargetPicker(
                    sourceProfile: leftProfile,
                    snapshot: appState.snapshot,
                    onSelect: { rightID in
                        let leftID = source.id
                        comparePickerSource = nil
                        // Defer the second sheet by one runloop tick so the
                        // picker dismiss animation completes cleanly.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            compareSheetIDs = ComparePair(leftID: leftID, rightID: rightID)
                        }
                    },
                    onCancel: {
                        comparePickerSource = nil
                    }
                )
            }
        }
        .sheet(item: $compareSheetIDs) { pair in
            CompareProfilesView(
                leftProfileID: pair.leftID,
                rightProfileID: pair.rightID
            )
        }
        // M11 — tree-scoped keyboard shortcuts. Hidden buttons register
        // shortcuts without taking up layout space. Cmd+N / Cmd+Shift+N /
        // Cmd+E moved to the global layer in ContentView (M16.9); the
        // tree-scoped layer below only handles Delete now.
        .background { treeKeyboardShortcuts }
        // Mirror the local selection into AppState so global shortcuts
        // (Cmd+E in particular) can reason about it from any sidebar tab.
        .onChange(of: treeVM.selectedProfileID) { _, newValue in
            appState.selectedProfileID = newValue
        }
        // M16.9 — observe the global Add Person / Add Family / Edit Selected
        // requests and present the matching sheet, then clear the action so
        // the same shortcut works again.
        .onChange(of: appState.pendingPersonAction) { _, newValue in
            guard let action = newValue else { return }
            switch action {
            case .add:
                addPersonContext = .freestanding
                showAddPerson = true
            case .addFamily:
                showAddFamily = true
            case .editSelected(let profileID):
                editProfileID = SheetID(id: profileID)
            }
            appState.clearPendingPersonAction()
        }
        .alert(
            "Remove this person?",
            isPresented: $showDeleteConfirmation,
            presenting: pendingDeleteProfileID
        ) { id in
            Button("Remove", role: .destructive) {
                appState.softDeleteProfile(id: id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They'll move to Settings → Deleted People where you can restore them later.")
        }
        // M17.6 — branch soft-delete confirmation. Uses BranchSelector to
        // count exactly how many profiles will move to Deleted People.
        .alert(
            branchAlertTitle,
            isPresented: Binding(
                get: { pendingBranchDelete != nil },
                set: { if !$0 { pendingBranchDelete = nil } }
            ),
            presenting: pendingBranchDelete
        ) { pending in
            Button("Remove \(pending.ids.count)", role: .destructive) {
                appState.softDeleteBranch(
                    rootID: pending.rootID,
                    ancestors: pending.direction == .ancestors
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.ids.count) profiles will move to Settings → Deleted People where you can restore them later.")
        }
    }

    private var branchAlertTitle: String {
        switch pendingBranchDelete?.direction {
        case .ancestors: return "Remove person and ancestors?"
        case .descendants: return "Remove person and descendants?"
        case .none: return "Remove?"
        }
    }

    /// Pending profile that the user invoked Delete on. Captured so the
    /// confirmation alert always references a stable id even after the
    /// selection moves.
    @State private var showDeleteConfirmation: Bool = false
    @State private var pendingDeleteProfileID: String?

    /// Pending branch delete — set when the user picks "Remove person and
    /// ancestors/descendants" from the popover Remove menu (M17.6). The
    /// confirmation alert uses `ids.count` so the user knows exactly how
    /// many profiles will move to Settings → Deleted People.
    @State private var pendingBranchDelete: PendingBranchDelete?

    private struct PendingBranchDelete: Identifiable {
        let id = UUID()
        let rootID: String
        let ids: Set<String>
        let direction: BranchDirection
    }

    /// Map a tree-relative add-person action onto the right `EntryContext`.
    /// Sibling shortcut inherits the anchor's primary source so a sibling
    /// of someone with a Document source defaults to Document; everything
    /// else flows through `.relativeOf` and lets `SourceDefaults` decide.
    private func contextFor(
        relatedToID: String,
        relation: AutoSuggestService.RelationContext
    ) -> EntryContext {
        let related = appState.snapshot.profiles[relatedToID]
        switch relation {
        case .sibling:
            return .sibling(of: relatedToID, inherited: related?.primarySource)
        case .parent, .child, .spouse, .none:
            return .relativeOf(profileID: relatedToID, primarySource: related?.primarySource)
        }
    }

    /// DESIGN.md §7.10.1 / §7.10.2 — tree-scoped shortcuts. Cmd+N /
    /// Cmd+Shift+N / Cmd+E live on the global keyboard layer in
    /// ContentView (M16.9); the only remaining tree-scoped shortcut is
    /// Delete (no modifier), which soft-deletes the selected profile.
    private var treeKeyboardShortcuts: some View {
        ZStack {
            Button {
                if let id = treeVM.selectedProfileID {
                    pendingDeleteProfileID = id
                    showDeleteConfirmation = true
                }
            } label: { EmptyView() }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Initial Root

    private var naturalRootID: String? {
        let withParents = appState.snapshot.profiles.values.filter {
            !appState.snapshot.parentsOf($0.id).isEmpty
        }
        let youngest = withParents.max { a, b in
            (a.birthDate?.bestYear ?? 0) < (b.birthDate?.bestYear ?? 0)
        }
        return youngest?.id ?? appState.snapshot.profiles.keys.first
    }

    private func selectInitialRoot() {
        guard treeVM.rootProfileID == nil, !appState.snapshot.profiles.isEmpty else { return }
        if let rootID = naturalRootID {
            treeVM.rootProfileID = rootID
            treeVM.selectedProfileID = rootID
        }
    }

    // MARK: - Click Handling

    /// Drain a cross-view `requestOpenProfileDetail` signal — sets the
    /// tree's selection and opens the inspector on the requested
    /// profile, then clears the request. Used by surfaces outside the
    /// tree canvas (today: Tasks list row click) that need to land the
    /// user on the Full Detail sheet.
    private func handlePendingProfileDetailRequest() {
        guard let pid = appState.requestOpenProfileDetail,
              appState.snapshot.profiles[pid] != nil else { return }
        treeVM.selectedProfileID = pid
        treeVM.popoverProfileID = nil
        treeVM.showInspector = true
        appState.requestOpenProfileDetail = nil
    }

    /// PROFILE_LIFECYCLE_SPEC Change 1 — open the profile card for `id` and hand
    /// it a card-owned action (Edit/Timeline/Relationship/Cleanse) raised from
    /// the right-click menu. `ProfileDetailView` consumes `pendingCardAction` on
    /// appear / profile-switch / intent-change, so this works whether the card
    /// was closed, showing this person, or showing someone else.
    private func openCardAction(_ id: String, _ action: ProfileCardAction) {
        appState.pendingCardAction = PendingCardAction(profileID: id, action: action)
        treeVM.selectedProfileID = id
        treeVM.popoverProfileID = nil
        treeVM.showInspector = true
    }

    /// Skip the popover layer and open the full Profile Detail sheet
    /// directly. Fires on a node body or the info icon — anywhere else
    /// (empty canvas, arrow/ancestor/descendant indicators) is ignored
    /// because there's no single profile to open. The popover is
    /// dismissed if currently visible so the two surfaces don't stack.
    private func handleDoubleClick(at location: CGPoint, canvasSize: CGSize) {
        switch treeVM.hitTest(at: location, canvasSize: canvasSize) {
        case .nodeBody(let id), .infoIcon(let id):
            treeVM.selectedProfileID = id
            treeVM.popoverProfileID = nil
            treeVM.showInspector = true
            focus = .canvas
        case .arrowIndicator, .ancestorIndicator, .descendantIndicator, .empty:
            // Defer to the single-click handler — these targets navigate
            // rather than open detail.
            handleSingleClick(at: location, canvasSize: canvasSize)
        }
    }

    private func handleSingleClick(at location: CGPoint, canvasSize: CGSize) {
        if treeVM.isAnimatingRecenter {
            withAnimation(nil) { treeVM.offset = .zero }
            treeVM.isAnimatingRecenter = false
        }

        switch treeVM.hitTest(at: location, canvasSize: canvasSize) {
        case .infoIcon(let id):
            treeVM.popoverProfileID = id

        case .arrowIndicator(let id):
            treeVM.popoverProfileID = nil
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize, reduceMotion: reduceMotion)

        case .ancestorIndicator(let id):
            // Tapped "▲ ancestors" — stay in pedigree mode, recenter on this node
            treeVM.popoverProfileID = nil
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize, reduceMotion: reduceMotion)

        case .descendantIndicator(let id):
            // Tapped "▼ N children" — switch to descendants mode to show them
            treeVM.popoverProfileID = nil
            treeVM.viewMode = .descendants
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize, reduceMotion: reduceMotion)

        case .nodeBody(let id):
            if id == treeVM.selectedProfileID {
                // Re-click on selected node → open popover
                treeVM.popoverProfileID = id
            } else {
                treeVM.selectedProfileID = id
                treeVM.popoverProfileID = nil
                treeVM.pendingExpandTarget = nil
                // Track selection count for coach mark
                selectionCount += 1
                if selectionCount == 3 && coachMarkShownCount < 3 {
                    showCoachMark = true
                    coachMarkShownCount += 1
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        showCoachMark = false
                    }
                }
            }

        case .empty:
            treeVM.selectedProfileID = nil
            treeVM.popoverProfileID = nil
            treeVM.pendingExpandTarget = nil
        }

        focus = .canvas
    }

    // MARK: - Keyboard Handling

    private func handleSpace() -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        if treeVM.popoverProfileID == nil {
            treeVM.popoverProfileID = selectedID
        }
        return .handled
    }

    private func handleReturn(canvasSize: CGSize) -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        treeVM.popoverProfileID = nil
        treeVM.recenter(on: selectedID, snapshot: appState.snapshot, canvasSize: canvasSize, reduceMotion: reduceMotion)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        if treeVM.popoverProfileID != nil {
            treeVM.popoverProfileID = nil
            return .handled
        }
        if treeVM.showInspector {
            treeVM.showInspector = false
            return .handled
        }
        if treeVM.selectedProfileID != nil {
            treeVM.selectedProfileID = nil
            return .handled
        }
        return .ignored
    }

    private func handleArrowKey(_ press: KeyPress, canvasSize: CGSize) -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        treeVM.popoverProfileID = nil

        let snapshot = appState.snapshot
        var targetID: String?

        switch press.key {
        case .upArrow:
            let parents = snapshot.parentsOf(selectedID)
            if press.modifiers.contains(.shift) {
                targetID = parents.count >= 2 ? parents[1].id : parents.first?.id
            } else {
                targetID = parents.first?.id
            }

        case .downArrow:
            targetID = snapshot.childrenOf(selectedID).first?.id

        case .leftArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }),
               currentIndex > 0 {
                targetID = siblings[currentIndex - 1].id
            }

        case .rightArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }),
               currentIndex < siblings.count - 1 {
                targetID = siblings[currentIndex + 1].id
            }
            if targetID == nil {
                targetID = snapshot.spousesOf(selectedID).first?.id
            }

        default:
            return .ignored
        }

        if let target = targetID {
            if treeVM.layout.nodes.contains(where: { $0.id == target }) {
                treeVM.selectedProfileID = target
                treeVM.pendingExpandTarget = nil
                return .handled
            } else {
                // Boundary case — confirm before expanding
                let handled = treeVM.handleBoundaryExpand(
                    targetID: target, snapshot: snapshot, canvasSize: canvasSize
                )
                return handled ? .handled : .ignored
            }
        }

        NSSound.beep()
        return .handled
    }

    // MARK: - Canvas

    private func treeCanvas(canvasSize: CGSize) -> some View {
        Canvas { context, size in
            let rootNode = treeVM.layout.nodes.first { $0.id == treeVM.rootProfileID }
            let transform = CanvasTransform(
                canvasSize: size,
                rootX: rootNode?.x ?? 0,
                rootY: rootNode?.y ?? 0,
                offset: treeVM.offset,
                scale: treeVM.scale
            )

            context.translateBy(
                x: size.width / 2 + treeVM.offset.width,
                y: size.height / 2 + treeVM.offset.height
            )
            context.scaleBy(x: treeVM.scale, y: treeVM.scale)

            let offsetX = transform.drawOffsetX
            let offsetY = transform.drawOffsetY

            // Focus filter: when active, every non-focus node and its
            // incident edges are skipped at draw time. Per DESIGN.md §7.7.2.
            let focusVisible: Set<String>? = {
                guard appState.focusFilterEnabled,
                      let active = appState.activeFocusSet else { return nil }
                return appState.snapshot.focusFilteredIDs(focus: active.profileIDs)
            }()

            // Draw edges — group parent edges by parent to avoid overlapping line segments
            var parentChildGroups: [String: (from: CGPoint, children: [CGPoint])] = [:]
            var spouseEdges: [(from: CGPoint, to: CGPoint)] = []

            for edge in treeVM.layout.edges {
                if let focusVisible,
                   !focusVisible.contains(edge.fromID) || !focusVisible.contains(edge.toID) {
                    continue
                }
                let from = CGPoint(x: edge.fromX + offsetX, y: edge.fromY + offsetY)
                let to = CGPoint(x: edge.toX + offsetX, y: edge.toY + offsetY)

                if edge.type == .spouse {
                    spouseEdges.append((from, to))
                } else {
                    let key = edge.fromID
                    if parentChildGroups[key] == nil {
                        parentChildGroups[key] = (from: from, children: [])
                    }
                    parentChildGroups[key]!.children.append(to)
                }
            }

            // Draw grouped parent-child connectors (one path per parent, no overlap)
            for (_, group) in parentChildGroups {
                TreeCanvasRenderer.drawParentChildGroup(context: &context, from: group.from, children: group.children)
            }

            // Draw spouse connectors
            for edge in spouseEdges {
                TreeCanvasRenderer.drawEdge(context: &context, from: edge.from, to: edge.to, type: .spouse)
            }

            // M8 W5 — render active relationship hypotheses as dashed,
            // muted edges between profiles that happen to be on-canvas.
            // Per DESIGN.md §7.7.7. Hypotheses involving off-canvas profiles
            // are silent: the popover/inspector surfaces them in those cases.
            let nodeByID: [String: TreeLayout.LayoutNode] = Dictionary(
                uniqueKeysWithValues: treeVM.layout.nodes.map { ($0.id, $0) }
            )
            for h in appState.activeRelationshipHypotheses {
                if case .relationship(let fromID, let toID, _, _) = h.claim,
                   let f = nodeByID[fromID], let t = nodeByID[toID] {
                    if let focusVisible,
                       !focusVisible.contains(fromID) || !focusVisible.contains(toID) {
                        continue
                    }
                    let p1 = CGPoint(x: f.x + offsetX, y: f.y + offsetY)
                    let p2 = CGPoint(x: t.x + offsetX, y: t.y + offsetY)
                    TreeCanvasRenderer.drawHypotheticalEdge(context: &context, from: p1, to: p2)
                }
            }

            // Draw nodes (real + ghost)
            let highlighted = Set(treeVM.filteredNodes().map(\.id))
            let hasSearch = !treeVM.searchText.isEmpty

            for node in treeVM.layout.allNodes {
                if let focusVisible, !focusVisible.contains(node.id) {
                    continue
                }
                if node.isGhost {
                    let rect = CGRect(
                        x: node.x + offsetX - TreeLayout.ghostNodeWidth / 2,
                        y: node.y + offsetY - TreeLayout.ghostNodeHeight / 2,
                        width: TreeLayout.ghostNodeWidth,
                        height: TreeLayout.ghostNodeHeight
                    )
                    TreeCanvasRenderer.drawGhostNode(context: &context, node: node, rect: rect, theme: Self.canvasTheme)
                } else {
                    let rect = CGRect(
                        x: node.x + offsetX - TreeLayout.nodeWidth / 2,
                        y: node.y + offsetY - TreeLayout.nodeHeight / 2,
                        width: TreeLayout.nodeWidth,
                        height: TreeLayout.nodeHeight
                    )
                    let isSelected = node.id == treeVM.selectedProfileID
                    let isRoot = node.id == treeVM.rootProfileID
                    let isHovered = node.id == treeVM.hoveredNodeID
                    let dimmed = hasSearch && !highlighted.contains(node.id)
                    // M8 indicators (DESIGN.md §7.7.7). Gated on the
                    // M16.11 "Show research indicators" toggle so users can
                    // print or demo a clean tree without these overlays.
                    let inFocus = TreeIndicatorVisibility.focusRingVisible(
                        nodeID: node.id,
                        activeFocusSet: appState.activeFocusSet,
                        showResearchIndicators: showResearchIndicators
                    )
                    let hasNote = TreeIndicatorVisibility.noteVisible(
                        hasNote: !appState.notesForProfile(node.id).isEmpty,
                        showResearchIndicators: showResearchIndicators
                    )
                    let hasOpenQuestion = TreeIndicatorVisibility.questionVisible(
                        hasOpenQuestion: appState.questions.contains { q in
                            q.status != .resolved && q.profileIDs.contains(node.id)
                        },
                        showResearchIndicators: showResearchIndicators
                    )
                    // M12 — surface tentative confidence on any of the four
                    // headline fields used for completeness scoring. DESIGN.md §5.14.
                    let hasTentativeFact = TreeIndicatorVisibility.tentativeVisible(
                        hasTentativeFact: profileHasTentativeFact(node.profile),
                        showResearchIndicators: showResearchIndicators
                    )
                    TreeCanvasRenderer.drawNode(
                        context: &context, node: node, rect: rect,
                        scale: treeVM.scale, snapshot: appState.snapshot,
                        theme: Self.canvasTheme,
                        isSelected: isSelected, isRoot: isRoot, isHovered: isHovered, dimmed: dimmed,
                        inFocus: inFocus, hasNote: hasNote, hasOpenQuestion: hasOpenQuestion,
                        hasTentativeFact: hasTentativeFact)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drawing

    /// Returns true when any of the four headline fields (firstName, lastName,
    /// birthDate, deathDate) on the given profile has its sources reduced to
    /// tentative-only. Used to surface a tilde marker on the canvas node.
    /// Returns false for nil profiles or when no tentative-only field exists.
    private func profileHasTentativeFact(_ profile: Profile?) -> Bool {
        guard let profile else { return false }
        let coreFields: [ProfileField] = [.firstName, .lastName, .birthDate, .deathDate]
        for field in coreFields {
            let sources = profile.sources[field] ?? []
            if effectiveConfidence(sources) == .tentative { return true }
        }
        return false
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                treeVM.popoverProfileID = nil
                treeVM.pendingExpandTarget = nil
                treeVM.offset = CGSize(
                    width: treeVM.dragStartOffset.width + value.translation.width,
                    height: treeVM.dragStartOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                treeVM.dragStartOffset = treeVM.offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                treeVM.scale = max(0.5, min(2.0, value.magnification))
            }
    }

    // MARK: - Popover Overlay

    @ViewBuilder
    private func popoverOverlay(canvasSize: CGSize) -> some View {
        if let popoverID = treeVM.popoverProfileID,
           let profile = appState.snapshot.profiles[popoverID] {
            let transform = treeVM.currentTransform(canvasSize: canvasSize)
            let node = treeVM.layout.nodes.first { $0.id == popoverID }
            let screenPos = node.map { transform.toScreen(x: $0.x, y: $0.y) }
                ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

            // Popover sizing matches `.frame(width: 320).frame(maxHeight: 480)`
            // below. Use the cap so placement decisions don't underestimate.
            let popoverHeight: CGFloat = 480
            let gap: CGFloat = 10
            let halfHeight = popoverHeight / 2
            let topOfNode = screenPos.y - TreeLayout.nodeHeight / 2 * treeVM.scale
            let bottomOfNode = screenPos.y + TreeLayout.nodeHeight / 2 * treeVM.scale
            let roomAbove = topOfNode - gap
            let roomBelow = canvasSize.height - bottomOfNode - gap
            // Prefer above when it fits; otherwise below when it fits; otherwise
            // pick the larger side so we can clamp into whatever room we have.
            let placeBelow: Bool = {
                if roomAbove >= popoverHeight { return false }
                if roomBelow >= popoverHeight { return true }
                return roomBelow > roomAbove
            }()
            let rawAnchorY = placeBelow
                ? bottomOfNode + gap + halfHeight
                : topOfNode - gap - halfHeight
            // Clamp to the canvas so the card never renders off-window. When
            // the available side is shorter than the popover, the maxHeight
            // frame lets the card compress and the clamp keeps it visible.
            let minY = halfHeight + gap
            let maxY = canvasSize.height - halfHeight - gap
            let anchorY = max(minY, min(maxY, rawAnchorY))
            let anchor: UnitPoint = placeBelow ? .top : .bottom

            ProfilePopoverView(
                profile: profile,
                snapshot: appState.snapshot,
                completeness: appState.snapshot.completeness(for: popoverID),
                visibleNodeIDs: Set(treeVM.layout.nodes.map(\.id)),
                isRoot: popoverID == treeVM.rootProfileID,
                currentViewMode: treeVM.viewMode,
                onRecenter: { relativeID in
                    treeVM.popoverProfileID = nil
                    treeVM.recenterOnRelative(
                        relativeID, from: popoverID,
                        snapshot: appState.snapshot, canvasSize: canvasSize,
                        reduceMotion: reduceMotion
                    )
                },
                onFocusHere: {
                    treeVM.popoverProfileID = nil
                    treeVM.recenter(on: popoverID, snapshot: appState.snapshot,
                                   canvasSize: canvasSize, reduceMotion: reduceMotion)
                },
                onShowDetail: {
                    treeVM.popoverProfileID = nil
                    treeVM.showInspector = true
                },
                onResearch: {
                    treeVM.popoverProfileID = nil
                    appState.researchProfileID = popoverID
                },
                onAddRelative: { relation in
                    treeVM.popoverProfileID = nil
                    addPersonContext = .relative(id: popoverID, relation: relation)
                    showAddPerson = true
                },
                onAddRelationship: {
                    treeVM.popoverProfileID = nil
                    relationshipAnchorID = SheetID(id: popoverID)
                },
                onRemove: {
                    treeVM.popoverProfileID = nil
                    appState.softDeleteProfile(id: popoverID)
                },
                onRemoveBranch: { ancestors in
                    treeVM.popoverProfileID = nil
                    let direction: BranchDirection = ancestors ? .ancestors : .descendants
                    let ids = BranchSelector.branch(
                        rootedAt: popoverID,
                        direction: direction,
                        in: appState.snapshot
                    )
                    pendingBranchDelete = PendingBranchDelete(
                        rootID: popoverID,
                        ids: ids,
                        direction: direction
                    )
                },
                isInFocus: appState.isInActiveFocus(popoverID),
                hasActiveFocus: appState.activeFocusSet != nil,
                onToggleFocus: {
                    if appState.isInActiveFocus(popoverID) {
                        appState.removeProfileFromActiveFocus(popoverID)
                    } else {
                        appState.addProfileToActiveFocus(popoverID)
                    }
                }
            )
            .frame(width: 320)
            .frame(maxHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .position(x: screenPos.x, y: anchorY)
            // M24 — drop the scale component when reduce-motion is on; a pure
            // opacity fade is the recommended fallback for popover transitions.
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.95, anchor: anchor)))
            .motionAware(.easeOut(duration: 0.15), value: popoverID)
        }
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private func controlsOverlay(canvasSize: CGSize) -> some View {
        VStack {
            // Breadcrumb trail
            HStack {
                breadcrumbTrail
                Spacer()
            }
            .padding()

            // Disconnected banner — only when the graph has multiple components
            // and the user hasn't dismissed it. M16.12 / 2026-07-15 owner
            // design: "Connect them?" opens AddRelationship anchored on the
            // ORPHAN (smallest component) — the person just added and lost —
            // and the user picks who they connect to; the anchor itself is
            // changeable in-sheet.
            let componentCount = GraphConnectivity.connectedComponents(appState.snapshot).count
            if componentCount > 1, !dismissedDisconnectedBanner {
                let suggestion = GraphConnectivity.suggestConnectionAnchors(snapshot: appState.snapshot)
                DisconnectedBannerView(
                    componentCount: componentCount,
                    canConnect: suggestion != nil,
                    onConnect: {
                        if let (primary, _) = suggestion {
                            relationshipAnchorID = SheetID(id: primary)
                        }
                    },
                    onDismiss: { dismissedDisconnectedBanner = true }
                )
                .padding(.horizontal)
            }

            // Coach mark
            if showCoachMark {
                Text("Tip: ↑↓ navigate relatives · Space to inspect · Return to focus")
                    .font(AppTypography.toast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    // M24 — opacity fade is already vestibular-safe; gate to
                    // `.identity` (instant) under reduce-motion for strict
                    // conformance with the no-animations setting.
                    .transition(reduceMotion ? .identity : .opacity)
            }

            Spacer()

            HStack {
                Spacer()
                // Zoom controls
                VStack(spacing: 4) {
                    Button {
                        if let rootID = naturalRootID {
                            treeVM.viewMode = .pedigree
                            treeVM.recenter(on: rootID, snapshot: appState.snapshot,
                                           canvasSize: canvasSize, reduceMotion: reduceMotion)
                        }
                    } label: {
                        Image(systemName: "house")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Recenter on tree root")
                    .accessibilityHint("Return the tree view to its natural starting profile")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding()
            }

            // Toast
            if let toast = treeVM.showToast {
                Text(toast)
                    .font(AppTypography.toast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    // M24 — see coach-mark above; gate to `.identity` under
                    // reduce-motion.
                    .transition(reduceMotion ? .identity : .opacity)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumbTrail: some View {
        HStack(spacing: 4) {
            ForEach(treeVM.breadcrumbEntries(snapshot: appState.snapshot)) { entry in
                if entry.isEllipsis {
                    Button("…") {
                        treeVM.expandBreadcrumb = true
                    }
                    .font(AppTypography.breadcrumb)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                } else {
                    Button(entry.name) {
                        treeVM.jumpToHistory(
                            index: entry.historyIndex,
                            snapshot: appState.snapshot,
                            reduceMotion: reduceMotion
                        )
                    }
                    .font(AppTypography.breadcrumb)
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.isCurrent ? .primary : .secondary)
                }

                if !entry.isLast {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.badge)
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Accessibility (M24)

    /// Hidden mirror of every layout node, so VoiceOver can enumerate
    /// profiles without seeing the Canvas drawing. Each element exposes the
    /// profile name, key dates, completeness, and a hint describing the
    /// available actions. Visually invisible — `.frame(width: 0, height: 0)`
    /// + `.opacity(0)` keep it out of the layout while preserving the
    /// accessibility tree.
    @ViewBuilder
    private var treeAccessibilityMirror: some View {
        VStack(spacing: 0) {
            ForEach(treeVM.layout.nodes, id: \.id) { node in
                if let profile = node.profile {
                    let comp = node.completeness
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            TreeAccessibilityLabel.nodeAccessibilityLabel(
                                profile: profile,
                                completeness: comp
                            )
                        )
                        .accessibilityHint(TreeAccessibilityLabel.nodeAccessibilityHint)
                        .accessibilityAddTraits(
                            node.id == treeVM.selectedProfileID ? [.isSelected, .isButton] : .isButton
                        )
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                addPersonContext = .freestanding
                showAddPerson = true
            } label: {
                Label("Add Person", systemImage: "person.badge.plus")
            }
            .help("Add a new person manually")
            .accessibilityHint("Add a new person manually")

            // Focus filter — visible only when there's an active focus set.
            // Toggling on hides every node not in (active focus + immediate
            // connections). Per DESIGN.md §7.7.2.
            if appState.activeFocusSet != nil {
                Toggle(isOn: Binding(
                    get: { appState.focusFilterEnabled },
                    set: { appState.focusFilterEnabled = $0 }
                )) {
                    Label("Focus only", systemImage: "scope")
                }
                .toggleStyle(.button)
                .help("Show only profiles in the active focus set and their immediate relatives")
                .accessibilityHint("Show only profiles in the active focus set and their immediate relatives")
            }

            Picker("View", selection: Binding(
                get: { treeVM.viewMode },
                set: { newMode in
                    treeVM.viewMode = newMode
                    treeVM.rebuildLayout(snapshot: appState.snapshot)
                }
            )) {
                ForEach(TreeViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Generation zoom: − N gen +
            HStack(spacing: 4) {
                Button {
                    treeVM.decreaseGenerations(snapshot: appState.snapshot)
                } label: {
                    Text("−").font(AppTypography.controlLabel.monospaced()).frame(width: 20)
                }
                .help("Show fewer generations (⌘-)")
                .accessibilityLabel("Show fewer generations")
                .accessibilityHint("Show fewer generations. Keyboard shortcut Command minus.")

                Text("\(treeVM.visibleGenerations) gen")
                    .font(AppTypography.controlLabel)
                    .monospacedDigit()
                    .frame(width: 40)

                Button {
                    treeVM.increaseGenerations(snapshot: appState.snapshot)
                } label: {
                    Text("+").font(AppTypography.controlLabel.monospaced()).frame(width: 20)
                }
                .help("Show more generations (⌘+)")
                .accessibilityLabel("Show more generations")
                .accessibilityHint("Show more generations. Keyboard shortcut Command plus.")
            }

            // Inspector sidebar toggle
            Button {
                treeVM.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .accessibilityHidden(true)
            }
            .help("Toggle inspector (⌘⌥I)")
            .accessibilityLabel("Toggle inspector")
            .accessibilityHint("Toggle inspector. Keyboard shortcut Command Option I.")
        }
    }
}
