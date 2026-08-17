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
                        .frame(minWidth: 320, idealWidth: 400)
                    detail
                        .frame(minWidth: 340)
                }
            }
        }
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
                ForEach(PlaceInventory.Confidence.allCases.reversed(), id: \.self) { level in
                    let count = rows.filter { $0.confidence == level }.count
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
                Image(systemName: row.confidence.symbol)
                    .foregroundStyle(row.confidence.tint)
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
                onBind: { code, ids in bind(row, occurrenceIDs: ids, to: code) },
                onNotAPlace: { markNotAPlace(row) },
                onRestore: { restore(row) }
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
        rows = PlaceInventory.build(
            profiles: Array(appState.snapshot.profiles.values),
            relationships: appState.snapshot.relationships,
            lifeEvents: lifeEvents,
            dismissed: dismissed)
    }

    private func bind(_ row: PlaceInventory.Row, occurrenceIDs: Set<String>, to code: String) {
        guard let db = appState.currentDatabase, !occurrenceIDs.isEmpty else { return }
        do {
            let written = try PlaceInventory.bind(row, occurrenceIDs: occurrenceIDs, to: code, in: db)
            if let snap = try? db.buildSnapshot() { appState.snapshot = snap }
            let name = PlaceAuthorityRegistry.shared.places.place(id: code)?.name ?? code
            lastAction = "Bound \(written) field\(written == 1 ? "" : "s") to \(name)"
        } catch {
            lastAction = "Could not save: \(error.localizedDescription)"
        }
        rebuild()
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
    let onBind: (String, Set<String>) -> Void
    let onNotAPlace: () -> Void
    let onRestore: () -> Void

    /// Which uses a district choice will be written to. Per FIELD, not per
    /// string — see `PlaceInventory.bind`.
    @State private var selection: Set<String> = []
    @State private var showingNational = false

    private var bindable: [PlaceInventory.Occurrence] { row.occurrences.filter { !$0.isBound } }

    /// Pre-tick every use only when they all belong to ONE person. Across two
    /// people the same word can name two places, which is the whole hazard, so
    /// there the user ticks deliberately.
    private var defaultSelection: Set<String> {
        row.profileCount == 1 ? Set(bindable.map(\.id)) : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.text).font(.title3)
                    Label(row.confidence.label, systemImage: row.confidence.symbol)
                        .font(AppTypography.badge)
                        .foregroundStyle(row.confidence.tint)
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

                if !row.candidates.isEmpty {
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

                // The escape hatch. The stated county is normally the best
                // constraint there is, but it is sometimes simply wrong —
                // emigrants described by where they ended up, a transcription
                // error, a boundary that moved. A list locked to it would trap
                // exactly those cases.
                if !row.candidates.isEmpty || row.confidence == .unresolved {
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

                section(bindable.isEmpty ? "Used by" : "Apply to which uses?") {
                    ForEach(row.occurrences) { occurrence in
                        occurrenceRow(occurrence)
                    }
                    if bindable.count > 1 {
                        HStack(spacing: 12) {
                            Button("Select all \(bindable.count)") {
                                selection = Set(bindable.map(\.id))
                            }
                            Button("Select none") { selection.removeAll() }
                        }
                        .font(AppTypography.controlLabel)
                    }
                }

                if !row.isNotAPlace {
                    Button("This isn't a place", action: onNotAPlace)
                        .font(AppTypography.controlLabel)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Button("Use this") { onBind(district.id, selection) }
                .font(AppTypography.controlLabel)
                .disabled(selection.isEmpty)
        }
    }

    @ViewBuilder private func occurrenceRow(_ occurrence: PlaceInventory.Occurrence) -> some View {
        HStack(spacing: 6) {
            if occurrence.isBound {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppTypography.badge)
                    .foregroundStyle(.green)
                    .help("Already coded — a district choice here will not overwrite it")
            } else {
                Toggle(isOn: Binding(
                    get: { selection.contains(occurrence.id) },
                    set: { on in
                        if on { selection.insert(occurrence.id) } else { selection.remove(occurrence.id) }
                    }
                )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            Text(occurrence.profileName).font(AppTypography.cardMeta)
            Text(occurrence.fieldLabel)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
            if let year = occurrence.year {
                Text(String(year))
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
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
                        Button("Use this") { onBind(district.id, selection) }
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
