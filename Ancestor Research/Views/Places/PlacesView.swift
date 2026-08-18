import SwiftUI
import AncestorKit

/// LOCATION_MODEL_SPEC Part III, Slice A — the Places tab.
///
/// Every distinct location string the tree uses, scored, worst first. Not an
/// audit: an audit reports a rule's verdict and the app decides what counts as a
/// finding. This lists everything and lets the person decide, because the app's
/// judgement about which places are settled is exactly what was wrong — Ruth
/// Brailsford's "Middleton, Derbyshire" resolved confidently to a district
/// founded fifteen years after she was born, and nothing surfaced it.
///
/// A high-confidence row is still a row. It is a glance and a tick, not a
/// hidden decision.
struct PlacesView: View {
    @Environment(AppState.self) private var appState

    @State private var rows: [PlaceInventory.Row] = []
    @State private var filter: Filter = .needsDecision
    @State private var search: String = ""
    @State private var selectedID: String?
    @State private var lastAction: String?
    @State private var decisions: PlaceDecisionSet = .empty
    /// Local-model suggestions, keyed by location text. Session-only: a
    /// suggestion is not a decision and is not persisted until someone accepts it.
    @State private var proposals: [String: PlaceProposer.Proposal] = [:]
    @State private var asking: Set<String> = []
    /// A bind the era guard refused, kept so the pane can offer the subset that
    /// does fit rather than leaving the user to work that out.
    @State private var refused: RefusedBind?

    struct RefusedBind: Equatable {
        let rowID: String
        let code: String
        let districtName: String
        let reason: String
        let fitting: Set<String>
        let message: String
    }

    enum Filter: String, CaseIterable, Identifiable {
        case needsDecision = "Needs a decision"
        case all = "All"
        case unresolved = "Unresolved"
        case settled = "Settled"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 320, idealWidth: 400, maxHeight: .infinity)
                    detail
                        .frame(minWidth: 340, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Fill the detail pane and pin to the top. Without this the VStack sizes
        // to its content and the split view gets centred vertically, leaving a
        // band of empty window above the title — which is what shipped.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: appState.snapshot.profiles.count) { rebuild() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Places")
                .font(AppTypography.cardTitle)
            Text("Every place named in the tree, and how confidently it maps to a registration district. Confident matches are listed too — you decide what is settled, not the app.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                let settledCount = rows.filter(\.isSettled).count
                if settledCount > 0 {
                    Label("\(settledCount) settled", systemImage: "checkmark.seal.fill")
                        .font(AppTypography.badge)
                        .foregroundStyle(.green)
                }
                ForEach(PlaceInventory.Confidence.allCases.reversed(), id: \.self) { level in
                    let count = rows.filter { $0.confidence == level && !$0.isSettled }.count
                    if count > 0 {
                        Label("\(count) \(level.label.lowercased())", systemImage: level.symbol)
                            .font(AppTypography.badge)
                            .foregroundStyle(level.tint)
                    }
                }
                if let lastAction {
                    Text(lastAction)
                        .font(AppTypography.badge)
                        .foregroundStyle(.blue)
                }
            }

            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                TextField("Filter places", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No places yet",
            systemImage: "mappin.slash",
            description: Text("Birth, death, and life-event places appear here once profiles carry them.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var visibleRows: [PlaceInventory.Row] {
        rows.filter { row in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .needsDecision: matchesFilter = row.needsDecision
            case .unresolved: matchesFilter = row.confidence == .unresolved
            case .settled: matchesFilter = !row.needsDecision
            }
            guard matchesFilter else { return false }
            guard !search.isEmpty else { return true }
            return row.text.localizedCaseInsensitiveContains(search)
        }
    }

    private var list: some View {
        List(visibleRows, selection: $selectedID) { row in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: row.isSettled ? "checkmark.seal.fill" : row.confidence.symbol)
                    .foregroundStyle(row.isSettled ? Color.green : row.confidence.tint)
                    .font(AppTypography.badge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text)
                        .font(AppTypography.cardBody)
                        .lineLimit(2)
                    Text(subtitle(row))
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.isNotAPlace {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .tag(row.id)
        }
        .listStyle(.inset)
        .overlay {
            if visibleRows.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "checkmark.circle",
                    description: Text(filter == .needsDecision
                                      ? "Every place is either confident or settled."
                                      : "No place matches this filter.")
                )
            }
        }
    }

    private func subtitle(_ row: PlaceInventory.Row) -> String {
        let people = row.profileCount == 1 ? "1 person" : "\(row.profileCount) people"
        if let district = row.candidates.first, row.candidates.count == 1 {
            return "\(people) · \(district.name)"
        }
        if row.candidates.count > 1 {
            return "\(people) · \(row.candidates.count) possible districts"
        }
        return people
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let row = rows.first(where: { $0.id == selectedID }) {
            PlaceDetailView(
                row: row,
                proposal: proposals[row.id],
                isAsking: asking.contains(row.id),
                variants: rows.filter { $0.variantKey == row.variantKey && $0.id != row.id },
                refused: refused?.rowID == row.id ? refused : nil,
                onBindFitting: {
                    guard let r = refused, r.rowID == row.id else { return }
                    bind(row, occurrenceIDs: r.fitting, to: r.code,
                         reason: r.reason, alsoVariants: false)
                },
                onBind: { code, ids, reason, alsoVariants in
                    bind(row, occurrenceIDs: ids, to: code, reason: reason,
                         alsoVariants: alsoVariants)
                },
                onNotAPlace: { markNotAPlace(row) },
                onRestore: { restore(row) },
                onUnbind: { unbind(row) },
                onCorrectText: { newText in correctText(row, to: newText) },
                onAskModel: { Task { await askModel(row) } }
            )
            .id(row.id)
        } else {
            ContentUnavailableView(
                "Select a place",
                systemImage: "mappin.and.ellipse",
                description: Text("Its candidate districts, the reasoning behind its score, and who uses it.")
            )
        }
    }

    // MARK: - Actions

    private func rebuild() {
        guard let db = appState.currentDatabase else { rows = []; return }
        let lifeEvents = (try? db.loadAllLifeEvents()) ?? []
        let dismissed = Set(((try? db.loadCleanseUnresolvableFlags()) ?? [])
            .map { "\($0.profileID)|\($0.field)" })
        decisions = PlaceDecisionSet(decisions: (try? db.loadPlaceDecisions()) ?? [])
        rows = PlaceInventory.build(
            profiles: Array(appState.snapshot.profiles.values),
            relationships: appState.snapshot.relationships,
            lifeEvents: lifeEvents,
            dismissed: dismissed,
            decisions: decisions)
    }

    private func bind(
        _ row: PlaceInventory.Row, occurrenceIDs: Set<String>, to code: String,
        reason: String, alsoVariants: Bool
    ) {
        guard let db = appState.currentDatabase, !occurrenceIDs.isEmpty else { return }
        do {
            var written = try PlaceInventory.bind(
                row, occurrenceIDs: occurrenceIDs, to: code, reason: reason, in: db)
            // Other spellings of the same village, settled by the same decision
            // — each still recorded against its own string, so the trail says
            // what was decided about what.
            if alsoVariants {
                for sibling in rows where sibling.variantKey == row.variantKey && sibling.id != row.id {
                    written += (try? PlaceInventory.bindAll(
                        sibling, to: code, reason: reason, in: db)) ?? 0
                }
            }
            let name = PlaceAuthorityRegistry.shared.places.place(id: code)?.name ?? code
            lastAction = "Settled \(written) field\(written == 1 ? "" : "s") as \(name)"
            refused = nil
        } catch let error as PlaceInventory.BindError {
            lastAction = error.message
            let fitting = PlaceInventory.occurrenceIDsFitting(
                row, districtID: code, within: occurrenceIDs)
            refused = fitting.isEmpty ? nil : RefusedBind(
                rowID: row.id, code: code,
                districtName: PlaceAuthorityRegistry.shared.places.place(id: code)?.name ?? code,
                reason: reason, fitting: fitting, message: error.message)
        } catch {
            lastAction = "Could not save: \(error.localizedDescription)"
        }
        rebuild()
    }

    /// Rewrite the tree's own words. The only honest answer for a misspelling
    /// (`Ashborne`) or a stray character (`-`), where neither settling nor
    /// setting aside is true.
    private func correctText(_ row: PlaceInventory.Row, to newText: String) {
        guard let db = appState.currentDatabase else { return }
        var profileFields: [(profileID: String, field: ProfileField)] = []
        var eventIDs: [UUID] = []
        for occurrence in row.occurrences {
            switch occurrence.target {
            case .profileField(let field):
                profileFields.append((occurrence.profileID, field))
            case .lifeEvent(let id, _):
                eventIDs.append(id)
            }
        }
        do {
            let n = try db.correctLocationText(
                profileFields: profileFields, lifeEventIDs: eventIDs, to: newText)
            if let snap = try? db.buildSnapshot() { appState.snapshot = snap }
            let trimmed = newText.trimmingCharacters(in: .whitespaces)
            lastAction = trimmed.isEmpty
                ? "Cleared \(n) field\(n == 1 ? "" : "s")"
                : "Rewrote \(n) field\(n == 1 ? "" : "s") as \"\(trimmed)\""
            selectedID = nil
        } catch {
            lastAction = "Could not save: \(error.localizedDescription)"
        }
        rebuild()
    }

    private func unbind(_ row: PlaceInventory.Row) {
        guard let db = appState.currentDatabase else { return }
        do {
            try PlaceInventory.unbind(row, decisions: decisions, in: db)
            lastAction = "\"\(row.text)\" reopened"
        } catch {
            lastAction = "Could not save: \(error.localizedDescription)"
        }
        rebuild()
    }

    /// Ask the local model which parish an unresolved hamlet sits in. The answer
    /// is a suggestion in the pane, never a write — see `PlaceProposer`.
    private func askModel(_ row: PlaceInventory.Row) async {
        asking.insert(row.id)
        defer { asking.remove(row.id) }
        let year = row.occurrences.compactMap(\.year).min()
        switch await PlaceProposer.propose(for: row.text, year: year) {
        case .success(let proposal)?:
            proposals[row.id] = proposal
        case .failure(let rejection)?:
            lastAction = "No suggestion: \(rejection.rawValue)"
        case nil:
            lastAction = "No local model loaded"
        }
    }

    private func markNotAPlace(_ row: PlaceInventory.Row) {
        guard let db = appState.currentDatabase else { return }
        do {
            let n = try PlaceInventory.markNotAPlace(row, in: db)
            lastAction = "\"\(row.text)\" set aside (\(n) field\(n == 1 ? "" : "s"))"
        } catch {
            lastAction = "Could not save: \(error.localizedDescription)"
        }
        rebuild()
    }

    private func restore(_ row: PlaceInventory.Row) {
        guard let db = appState.currentDatabase else { return }
        try? PlaceInventory.clearNotAPlace(row, in: db)
        lastAction = "\"\(row.text)\" restored"
        rebuild()
    }
}

// MARK: - Detail pane

private struct PlaceDetailView: View {
    let row: PlaceInventory.Row
    let proposal: PlaceProposer.Proposal?
    let isAsking: Bool
    /// Other rows that spell the same place differently.
    let variants: [PlaceInventory.Row]
    let refused: PlacesView.RefusedBind?
    let onBindFitting: () -> Void
    let onBind: (String, Set<String>, String, Bool) -> Void
    let onNotAPlace: () -> Void
    let onRestore: () -> Void
    let onUnbind: () -> Void
    let onCorrectText: (String) -> Void
    let onAskModel: () -> Void

    /// Which uses a district choice will be written to. Per FIELD, not per
    /// string — see `PlaceInventory.bind`.
    @State private var selection: Set<String> = []
    @State private var showingNational = false
    @State private var reason: String = ""
    @State private var placeSearch: String = ""
    @State private var applyToVariants: Bool = true
    @State private var correcting = false
    @State private var correctedText = ""

    private var settled: PlaceDecision? { row.occurrences.compactMap(\.decision).first }

    private var bindable: [PlaceInventory.Occurrence] { row.occurrences.filter { !$0.isBound } }

    /// Pre-tick every use unless the NAME itself could mean different places for
    /// different people — which is exactly `placeNames.count > 1`.
    ///
    /// The first rule was "only when one person uses it", and Bolehill showed
    /// why that is the wrong test: one 1891 household, six people, seventeen
    /// life events, and not a tick among them. Nothing about Bolehill is
    /// ambiguous — the gazetteer simply lacks it — so making someone tick
    /// seventeen boxes protects against nothing. Middleton, where two real
    /// villages share a word, is where deliberate ticking earns its keep.
    private var defaultSelection: Set<String> {
        row.placeNames.count > 1 ? [] : Set(bindable.map(\.id))
    }

    /// Occurrences collapsed to one row per person. A single census generates a
    /// census, an occupation and a residence event at the same address, so six
    /// people arrive as seventeen checkboxes — noise that hides the decision.
    /// The meaningful unit within one string is the PERSON.
    /// People with at least one use still to settle — the unit the list shows.
    private var peopleWithUnbound: [(profileID: String, name: String, occurrences: [PlaceInventory.Occurrence])] {
        peopleUsingThis.filter { person in person.occurrences.contains { !$0.isBound } }
    }

    /// People all of whose unsettled uses are ticked.
    private var selectedPeopleCount: Int {
        peopleWithUnbound.filter { person in
            person.occurrences.filter { !$0.isBound }.allSatisfy { selection.contains($0.id) }
        }.count
    }

    private var peopleUsingThis: [(profileID: String, name: String, occurrences: [PlaceInventory.Occurrence])] {
        let grouped = Dictionary(grouping: row.occurrences, by: \.profileID)
        return grouped
            .map { (profileID: $0.key,
                    name: $0.value.first?.profileName ?? "",
                    // Year, then label. Sorting by fieldKey put life events in
                    // UUID order, so one person read "Census · Residence" and
                    // the next "Residence · Occupation · Census".
                    occurrences: $0.value.sorted {
                        ($0.year ?? 0, $0.fieldLabel) < ($1.year ?? 0, $1.fieldLabel)
                    }) }
            .sorted { $0.name == $1.name ? $0.profileID < $1.profileID : $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.text).font(.title3)
                    Label(row.isSettled ? "Settled" : row.confidence.label,
                          systemImage: row.isSettled ? "checkmark.seal.fill" : row.confidence.symbol)
                        .font(AppTypography.badge)
                        .foregroundStyle(row.isSettled ? Color.green : row.confidence.tint)
                }

                if row.isNotAPlace {
                    section("Set aside") {
                        Text("Marked as naming no place, so it no longer asks for a decision.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                        Button("Put it back in the queue", action: onRestore)
                            .font(AppTypography.controlLabel)
                    }
                }

                // A row whose uses straddle a district opening or closing is two
                // questions in one. Candidates are filtered by the EARLIEST year,
                // so a district that is right for the later events is ruled out
                // on account of the earlier ones — and binding them together is
                // refused. Saying so before the attempt beats explaining it after.
                if !row.isSettled, !row.boundariesCrossed.isEmpty {
                    section("These uses span a boundary") {
                        ForEach(row.boundariesCrossed, id: \.year) { boundary in
                            Text(boundary.opened
                                 ? "\(boundary.districtName) opened in \(boundary.year)."
                                 : "\(boundary.districtName) closed in \(boundary.year).")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.orange)
                        }
                        Text("Events either side may belong to different districts. Tick one group, settle it, then do the other.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The guard refused this bind. It already knows which uses do
                // fit, so offer them rather than leaving the user to deduce it.
                if !row.isSettled, let refused {
                    section("Not all of those fit") {
                        Text(refused.message)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Settle just the \(refused.fitting.count) that fit \(refused.districtName)",
                               action: onBindFitting)
                            .font(AppTypography.controlLabel)
                    }
                }

                if let settled {
                    section("Settled") {
                        Text(PlaceInventory.hierarchyDisplay(
                            text: row.text, placeAuthorityID: settled.placeAuthorityID))
                            .font(AppTypography.cardBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Decided \(settled.decidedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                        // A decision that is not one of the row's own candidates
                        // was a human placing the text somewhere the catalogue
                        // never matched. Saying so keeps the app from later
                        // presenting a hand-made judgement as a lookup.
                        if !row.candidates.contains(where: { $0.id == settled.placeAuthorityID }) {
                            Label("Placed by hand — the gazetteer did not match this text",
                                  systemImage: "hand.point.up.left")
                                .font(AppTypography.badge)
                                .foregroundStyle(.orange)
                        }
                        if !settled.reason.isEmpty {
                            Text("\u{201C}\(settled.reason)\u{201D}")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if settled.yearFrom != nil || settled.yearTo != nil {
                            let window: String = switch (settled.yearFrom, settled.yearTo) {
                            case (let from?, let to?): "Applies \(from)–\(to)"
                            case (let from?, nil): "Applies from \(from)"
                            case (nil, let to?): "Applies up to \(to)"
                            case (nil, nil): ""
                            }
                            Text(window)
                                .font(AppTypography.badge)
                                .foregroundStyle(.tertiary)
                        }
                        Button("Reopen this", action: onUnbind)
                            .font(AppTypography.controlLabel)
                    }
                }

                // A model suggestion is a suggestion. It is labelled, it carries
                // the model's own words, and accepting it is an ordinary bind
                // that records who decided — the app never writes it itself.
                if !row.isSettled, let proposal {
                    section("Local model suggests") {
                        Text("\(proposal.parish) → \(proposal.districtName) district")
                            .font(AppTypography.cardBody)
                        Text("\u{201C}\(proposal.rationale)\u{201D}")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Suggested by the local model from a list of real parishes. Check it before accepting.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Accept this") { onBind(proposal.districtID, selection, reasonOrDefault(proposal), applyToVariants) }
                            .font(AppTypography.controlLabel)
                            .disabled(selection.isEmpty)
                    }
                }

                if !row.isSettled, !row.candidates.isEmpty {
                    section(row.candidates.count == 1 ? "District" : "Which district?") {
                        ForEach(row.candidates, id: \.id) { district in
                            candidateRow(district, corroborated: row.corroboration[district.id])
                        }
                        if selection.isEmpty && !bindable.isEmpty {
                            Text("Tick which uses below this applies to.")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // WHERE IS IT? The affordance an unresolved row cannot do
                // without. The catalogue has never heard of Bolehill or
                // Pilhough — both real settlements — so there are no candidates
                // to choose from, and without this the only action left is
                // "this isn't a place", which for a hamlet is simply false.
                // Nothing in the data separates an unlisted village from a
                // street name; only a person knows, which is the whole reason
                // this tab exists.
                if !row.isSettled { placeSearchSection }

                // The escape hatch. The stated county is normally the best
                // constraint there is, but it is sometimes simply wrong —
                // emigrants described by where they ended up, a transcription
                // error, a boundary that moved. A list locked to it would trap
                // exactly those cases.
                if !row.isSettled, !row.candidates.isEmpty {
                    nationalEscapeHatch
                }

                // Eliminations are shown, not dropped. An answer reached by
                // knocking rivals out is only checkable if the knockouts are
                // visible — "Bakewell (began 1839)" is what turns a confident
                // wrong answer into an obvious one.
                if !row.eliminated.isEmpty {
                    section("Ruled out") {
                        ForEach(row.eliminated, id: \.district.id) { item in
                            Text("\(item.district.name) — \(item.reason)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .strikethrough()
                        }
                    }
                }

                section("Why this score") {
                    ForEach(Array(row.reasons.enumerated()), id: \.offset) { _, reason in
                        Text("• " + reason)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !row.isSettled, !bindable.isEmpty {
                    section("Why (recorded with your choice)") {
                        TextField("e.g. Middleton by Wirksworth — her father's 1841 census entry",
                                  text: $reason, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                        Text("Optional, but it is what stops a later session re-litigating this.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }

                // The same village spelled four ways is four rows and one
                // decision. Each variant still records its own decision against
                // its own string, so the trail stays honest about what was
                // settled and when — this only saves repeating yourself.
                if !row.isSettled, !variants.isEmpty {
                    section("Same place, other spellings") {
                        Toggle(isOn: $applyToVariants) {
                            Text("Also settle \(variants.count) other spelling\(variants.count == 1 ? "" : "s")")
                                .font(AppTypography.cardMeta)
                        }
                        .toggleStyle(.checkbox)
                        ForEach(variants) { variant in
                            Text("\(variant.text) · \(variant.profileCount) \(variant.profileCount == 1 ? "person" : "people")")
                                .font(AppTypography.badge)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                section(row.isSettled || bindable.isEmpty ? "Used by" : "Apply to which uses?") {
                    // Controls first — they were below seventeen rows, which is
                    // past the fold on a real household.
                    // Count PEOPLE, because people are what the list shows. The
                    // labels used to count occurrences — "Select all 16" above
                    // six rows — which was accurate about the fields and wrong
                    // about the thing on screen. The field count is still stated,
                    // because fields are what actually get written.
                    if peopleWithUnbound.count > 1 {
                        HStack(spacing: 12) {
                            Button("Select all \(peopleWithUnbound.count)") {
                                selection = Set(bindable.map(\.id))
                            }
                            Button("Select none") { selection.removeAll() }
                            Spacer()
                        }
                        .font(AppTypography.controlLabel)
                        // Its own line: beside two buttons in a ~340pt pane the
                        // summary gets squeezed and loses its leading half, so
                        // "6 of 6 people · 16 fields" arrived as "16 fields".
                        Text("\(selectedPeopleCount) of \(peopleWithUnbound.count) people · \(selection.count) field\(selection.count == 1 ? "" : "s") will be settled")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(peopleUsingThis, id: \.profileID) { person in
                        personRow(person)
                    }
                }

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Pinned, not scrolled. These were below the uses list, so a six-person
        // household pushed them off-screen — and for a typo like "Ashborne" or a
        // stray "-", correcting the text is the PRIMARY action, not an
        // afterthought to be scrolled to.
        Divider()
        VStack(alignment: .leading, spacing: 8) {
                // THE THIRD ANSWER. "Ashborne" is a misspelling of a district the
                // app knows; "-" is a stray character. Neither settling them nor
                // setting them aside is true — the text itself is wrong. This is
                // the one action in the tab that edits your tree, so it is
                // explicit, it shows exactly what it will change, and it goes
                // through the same undo machinery as any other profile edit.
                section("Is the text itself wrong?") {
                    if correcting {
                        TextField("Corrected place name — leave empty to clear it",
                                  text: $correctedText)
                            .textFieldStyle(.roundedBorder)
                        Text(correctedText.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Will CLEAR this place from \(row.occurrences.count) field\(row.occurrences.count == 1 ? "" : "s")."
                             : "Will rewrite \(row.occurrences.count) field\(row.occurrences.count == 1 ? "" : "s") to \u{201C}\(correctedText.trimmingCharacters(in: .whitespaces))\u{201D}.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("Rewrite the tree") { onCorrectText(correctedText) }
                            Button("Cancel") { correcting = false }
                        }
                        .font(AppTypography.controlLabel)
                    } else {
                        Button("Correct the text…") {
                            correctedText = row.text
                            correcting = true
                        }
                        .font(AppTypography.controlLabel)
                        Text("Changes what your tree says, not just how it resolves. Undoable.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !row.isNotAPlace {
                    Button("This isn't a place", action: onNotAPlace)
                        .font(AppTypography.controlLabel)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        }
        .onAppear { selection = defaultSelection }
    }

    // MARK: - Rows

    @ViewBuilder private func candidateRow(_ district: PlaceAuthority, corroborated: Int?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(district.name).font(AppTypography.cardBody)
                HStack(spacing: 6) {
                    Text(validity(district))
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    // Family corroboration ranks the list and says so. It is
                    // never folded into the confidence score — a family that
                    // stayed put would otherwise vouch for every ambiguous
                    // place in the same district, compounding each time.
                    if let corroborated {
                        Label("\(corroborated) family record\(corroborated == 1 ? "" : "s")",
                              systemImage: "person.2")
                            .font(AppTypography.badge)
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            Button("Use this") { onBind(district.id, selection, reason, applyToVariants) }
                .font(AppTypography.controlLabel)
                .disabled(selection.isEmpty)
        }
    }

    /// "Bakewell and Belper both cover 1839–1994, so 1891 does not decide this —
    /// the family records below do."
    ///
    /// Returns nil when the districts genuinely differ for this row's years, in
    /// which case the per-hit windows are doing the work on their own.
    private func overlapNote(_ hits: [PlaceAuthorityRegistry.SearchHit]) -> String? {
        let places = PlaceAuthorityRegistry.shared.places
        // ONLY districts of the same parish. Listing every district across every
        // hit read "Ashbourne and Bakewell and Belper overlap" — but Ashbourne
        // is Middleton by Wirksworth's district, a different village entirely,
        // and naming it as a rival for Wirksworth is simply wrong.
        let byParish = Dictionary(grouping: hits) { PlaceAuthority.foldedName($0.place.name) }
        guard let contested = byParish.values.filter({ $0.count > 1 })
            .max(by: { $0.count < $1.count }) else { return nil }
        let districts = Set(contested.compactMap(\.districtID)).compactMap { places.place(id: $0) }
        guard districts.count > 1 else { return nil }

        let years = row.occurrences.compactMap(\.year)
        let allCover = districts.allSatisfy {
            PlaceDecision.yearsOutsideWindow(years, from: $0.validFrom, to: $0.validTo).isEmpty
        }
        guard allCover else { return nil }

        let low = districts.compactMap(\.validFrom).max() ?? 1837
        let high = districts.compactMap(\.validTo).min()
        let span = high.map { "\(low)–\($0)" } ?? "\(low) onwards"
        let sorted = districts.map(\.name).sorted()
        let names = sorted.count == 2
            ? sorted.joined(separator: " and ")
            : sorted.dropLast().joined(separator: ", ") + " and " + (sorted.last ?? "")
        let event = years.min().map { years.max() == $0 ? " \($0)" : "" } ?? ""

        return "\(names) overlap for \(span), so\(event.isEmpty ? " these years" : event) "
            + "does not decide between them. The family records below are the signal that does."
    }

    /// "Belper 1837–1994 · covers 1891" — the district's lifetime and whether it
    /// spans the years this row actually holds.
    ///
    /// A nil `validFrom` means "since civil registration began", which is July
    /// 1837 — a more useful thing to print than a blank.
    private func windowLine(_ hit: PlaceAuthorityRegistry.SearchHit) -> String? {
        guard let districtID = hit.districtID,
              let district = PlaceAuthorityRegistry.shared.places.place(id: districtID)
        else { return nil }
        let from = district.validFrom.map(String.init) ?? "1837"
        let to = district.validTo.map(String.init) ?? "present"
        var line = "\(district.name) \(from)–\(to)"

        let years = row.occurrences.compactMap(\.year)
        if let low = years.min(), let high = years.max() {
            let span = low == high ? "\(low)" : "\(low)–\(high)"
            let outside = PlaceDecision.yearsOutsideWindow(
                years, from: district.validFrom, to: district.validTo)
            line += outside.isEmpty
                ? " · covers \(span)"
                : " · does NOT cover \(outside.map(String.init).joined(separator: ", "))"
        }
        return line
    }

    /// A model-suggested binding always records HOW it was reached, even when the
    /// user typed nothing — otherwise the trail says a person decided it.
    private func reasonOrDefault(_ proposal: PlaceProposer.Proposal) -> String {
        let suffix = "Accepted from local-model suggestion: \(proposal.rationale)"
        return reason.isEmpty ? suffix : "\(reason) — \(suffix)"
    }

    /// One person, however many of their fields use this string. The checkbox
    /// toggles all their unbound uses at once; the fields are named beneath so
    /// nothing is hidden, only compressed.
    @ViewBuilder private func personRow(
        _ person: (profileID: String, name: String, occurrences: [PlaceInventory.Occurrence])
    ) -> some View {
        let unbound = person.occurrences.filter { !$0.isBound }
        let allTicked = !unbound.isEmpty && unbound.allSatisfy { selection.contains($0.id) }
        let fields = person.occurrences
            .map { o in o.year.map { "\(o.fieldLabel) \($0)" } ?? o.fieldLabel }
            .joined(separator: " · ")

        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if unbound.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppTypography.badge)
                    .foregroundStyle(.green)
                    .help("Already settled — a choice here will not overwrite it")
            } else {
                Toggle(isOn: Binding(
                    get: { allTicked },
                    set: { on in
                        for o in unbound {
                            if on { selection.insert(o.id) } else { selection.remove(o.id) }
                        }
                    }
                )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).font(AppTypography.cardMeta)
                Text(fields)
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Search the gazetteer for the parish or district this place sits in, and
    /// bind to it. Parishes rank first because that is the precise answer and
    /// the one a genealogist thinks in — "Bolehill is in Wirksworth", not
    /// "Bolehill is in Belper registration district".
    @ViewBuilder private var placeSearchSection: some View {
        let year = row.occurrences.compactMap(\.year).min()
        let hits = PlaceAuthorityRegistry.shared.search(placeSearch, year: year)

        section(row.candidates.isEmpty ? "Where is it?" : "Somewhere else?") {
            if row.candidates.isEmpty {
                Text("The gazetteer has no entry for this. If it is a real place, say which parish it sits in.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Search parishes and districts…", text: $placeSearch)
                .textFieldStyle(.roundedBorder)

            if !placeSearch.isEmpty && hits.isEmpty {
                Text("Nothing matches \u{201C}\(placeSearch)\u{201D}.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            // A parish listed under two districts is not a choice about DATES.
            // UKBMD files a parish under every district that ever covered any
            // part of it, so Wirksworth appears under Bakewell (from 1839) and
            // Belper (to 1994) and BOTH cover any Victorian event. Printing
            // those windows beside two otherwise identical rows implied "pick by
            // year", which is exactly the wrong inference — the honest signal is
            // where this family's records already are.
            let duplicated = Set(hits.map { PlaceAuthority.foldedName($0.place.name) })
                .filter { name in hits.filter { PlaceAuthority.foldedName($0.place.name) == name }.count > 1 }
            if !duplicated.isEmpty {
                // Name the overlap rather than describing it in the abstract.
                // The general note was already here and still drew the question
                // "don't these overlap?" — because the answer is yes, and the
                // useful thing is to say so with the actual years and say what
                // DOES decide it.
                Text(overlapNote(hits) ?? "Some parishes are listed under more than one district — the catalogue files a parish under every district that ever covered part of it, so more than one can be right for the same year.")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(hits) { hit in
                let corroborated = hit.districtID.flatMap { row.allCorroboration[$0] }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.place.name).font(AppTypography.cardBody)
                        Text(hit.hierarchy)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                        // The district's lifetime, and whether it covers THIS
                        // row's years. A first cut printed the bare window and
                        // it read as "choose by year"; removing it lost real
                        // information, because outside 1839–1994 only one of the
                        // two Wirksworth records is possible at all. Stating the
                        // window AND the coverage gives the data back without
                        // implying it is the discriminator when it is not.
                        if let window = windowLine(hit) {
                            Text(window)
                                .font(AppTypography.badge)
                                .foregroundStyle(.tertiary)
                        }
                        if let corroborated {
                            Label("\(corroborated) record\(corroborated == 1 ? "" : "s") in this family already",
                                  systemImage: "person.2")
                                .font(AppTypography.badge)
                                .foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                    Button("It's here") { onBind(hit.place.id, selection, reason, applyToVariants) }
                        .font(AppTypography.controlLabel)
                        .disabled(selection.isEmpty)
                }
            }
            if !hits.isEmpty && selection.isEmpty && !bindable.isEmpty {
                Text("Tick which uses below this applies to.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var nationalEscapeHatch: some View {
        if showingNational {
            let national = RegistrationDistrictResolver.nationalCandidates(forPlaceOrDistrict: row.text)
            section("All \(national.count) nationally") {
                Text("Ignoring the county in the text and any date. Use this when the stated county is itself wrong.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(national, id: \.id) { district in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(district.name) · \(countyName(district))")
                                .font(AppTypography.cardBody)
                            Text(validity(district))
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use this") { onBind(district.id, selection, reason, applyToVariants) }
                            .font(AppTypography.controlLabel)
                            .disabled(selection.isEmpty)
                    }
                }
                Button("Hide") { showingNational = false }
                    .font(AppTypography.controlLabel)
            }
        } else {
            Button("Show all matches nationally") { showingNational = true }
                .font(AppTypography.controlLabel)
        }
    }

    private func countyName(_ district: PlaceAuthority) -> String {
        let chapman = String(district.id.split(separator: ":").first ?? "")
        return PlaceAuthorityRegistry.shared.places.place(id: chapman)?.name ?? chapman
    }

    private func validity(_ district: PlaceAuthority) -> String {
        switch (district.validFrom, district.validTo) {
        case (nil, nil): "all years"
        case (let from?, nil): "from \(from)"
        case (nil, let to?): "to \(to)"
        case (let from?, let to?): "\(from)–\(to)"
        }
    }

    @ViewBuilder private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

// MARK: - Presentation

extension PlaceInventory.Confidence {
    var symbol: String {
        switch self {
        case .unresolved: "questionmark.circle"
        case .low: "exclamationmark.triangle"
        case .medium: "circle.lefthalf.filled"
        case .high: "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .unresolved: .secondary
        case .low: .orange
        case .medium: .yellow
        case .high: .green
        }
    }
}
