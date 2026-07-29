import SwiftUI

/// Sheet for adding or editing a `LifeEvent` on a profile (M12). Mirrors
/// `NoteComposerView`'s pattern — same view drives both add and edit.
///
/// Init in one of two modes:
/// - `.add(profileID:)` — creates a new event for the given profile.
/// - `.edit(_:)` — edits an existing event in place; surfaces a Delete button.
struct LifeEventEditorView: View {
    enum Mode {
        case add(profileID: String)
        case edit(LifeEvent)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var selectedType: LifeEventType = .occupation
    @State private var dateText: String = ""
    @State private var endDateText: String = ""
    @State private var location: String = ""
    @State private var locationCode: String? = nil
    @State private var eventDescription: String = ""
    @State private var confidence: FactConfidence = .standard
    @State private var sensitive: Bool = false
    // Provenance — a source name + link for a record you're recording by hand
    // (e.g. a Find a Grave memorial the pipeline can't find). Kept as a citation
    // on the event; for a burial it also lands as a cited record in the
    // evidence expander with a link back.
    @State private var sourceName: String = ""
    @State private var sourceURL: String = ""

    // Task #54 — typed-detail subforms. Each type has its own collection of
    // @State fields so SwiftUI can keep entries while the user clicks back
    // and forth between types without losing what they've typed; only the
    // currently-selected type's details get persisted on save.
    @State private var militaryRank: String = ""
    @State private var militaryRegiment: String = ""
    @State private var militaryUnit: String = ""
    @State private var militaryServiceNumber: String = ""
    @State private var militaryCountry: String = ""
    @State private var militaryCemetery: String = ""
    @State private var militaryGraveRef: String = ""
    @State private var militaryHonours: String = ""

    @State private var probateGrantType: String = ""
    @State private var probateRegistry: String = ""
    @State private var probateNumber: String = ""
    @State private var probateAddress: String = ""
    @State private var probateAgeAtDeathText: String = ""

    @State private var burialCemetery: String = ""
    @State private var burialPlot: String = ""
    @State private var burialGraveRef: String = ""
    @State private var burialInscription: String = ""
    @State private var burialIsVeteran: Bool = false

    @State private var censusOccupation: String = ""
    @State private var censusAddress: String = ""
    @State private var censusDistrict: String = ""
    @State private var censusParish: String = ""
    @State private var censusHousehold: [HouseholdMember] = []

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var profileID: String {
        switch mode {
        case .add(let id): return id
        case .edit(let event): return event.profileID
        }
    }

    /// At least one of date/location/description must carry signal.
    private var hasSignal: Bool {
        !dateText.trimmingCharacters(in: .whitespaces).isEmpty
            || !location.trimmingCharacters(in: .whitespaces).isEmpty
            || !eventDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditMode ? "Edit Life Event" : "Add Life Event")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $selectedType) {
                        ForEach(LifeEventType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    GuidedDateField(label: "Date", text: $dateText)

                    if selectedType.hasDuration {
                        GuidedDateField(label: "End date", text: $endDateText)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        LocationPicker(
                            label: "Town, county, country",
                            text: $location,
                            locationCode: $locationCode
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField(descriptionPlaceholder(for: selectedType), text: $eventDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                    }

                    // Task #54 — typed-detail subforms appear only for the
                    // four types that have structured payloads. Other types
                    // (residence, occupation, etc.) stay description-only.
                    switch selectedType {
                    case .militaryService: militarySubform
                    case .probate:         probateSubform
                    case .burial:          burialSubform
                    case .census:          censusSubform
                    default:               EmptyView()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField("Source (e.g. Find a Grave)", text: $sourceName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Source URL (https://…)", text: $sourceURL)
                            .textFieldStyle(.roundedBorder)
                        Text("A link to the record — kept as a citation. For a burial it also appears in the evidence, with a link back to the source.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confidence")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Picker("Confidence", selection: $confidence) {
                            ForEach(FactConfidence.allCases, id: \.self) { c in
                                Text(c.displayName).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(confidence.explanation)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Sensitive — exclude from shared exports", isOn: $sensitive)
                        Text("Excluded from shared exports when the global filter is on.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                if isEditMode {
                    Button(role: .destructive) {
                        deleteEvent()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(isEditMode ? "Save" : "Add") { save() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSignal)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear(perform: hydrate)
    }

    private func hydrate() {
        if case .edit(let event) = mode {
            selectedType = event.type
            dateText = event.date?.original ?? ""
            endDateText = event.endDate?.original ?? ""
            location = event.location ?? ""
            locationCode = event.locationCode
            eventDescription = event.description ?? ""
            confidence = event.confidence
            sensitive = event.sensitive
            hydrateDetails(event.details)
        }
    }

    /// Pull a `LifeEventDetails` payload into the typed-subform @State fields.
    /// Each case populates only the relevant subset; everything else stays at
    /// its default empty value, which is fine because save() only reads the
    /// fields belonging to the current `selectedType`.
    private func hydrateDetails(_ details: LifeEventDetails?) {
        guard let details else { return }
        switch details {
        case .military(let m):
            militaryRank = m.rank ?? ""
            militaryRegiment = m.regiment ?? ""
            militaryUnit = m.unit ?? ""
            militaryServiceNumber = m.serviceNumber ?? ""
            militaryCountry = m.countryOfService ?? ""
            militaryCemetery = m.cemetery ?? ""
            militaryGraveRef = m.graveRef ?? ""
            militaryHonours = m.honours ?? ""
        case .probate(let p):
            probateGrantType = p.grantType ?? ""
            probateRegistry = p.registry ?? ""
            probateNumber = p.probateNumber ?? ""
            probateAddress = p.address ?? ""
            probateAgeAtDeathText = p.ageAtDeath.map(String.init) ?? ""
        case .burial(let b):
            burialCemetery = b.cemetery ?? ""
            burialPlot = b.plot ?? ""
            burialGraveRef = b.graveRef ?? ""
            burialInscription = b.inscription ?? ""
            burialIsVeteran = b.isVeteran
        case .census(let c):
            censusOccupation = c.occupation ?? ""
            censusAddress = c.address ?? ""
            censusDistrict = c.district ?? ""
            censusParish = c.parish ?? ""
            censusHousehold = c.household
        }
    }

    /// Build a `LifeEventDetails` payload from the current subform @State
    /// for `selectedType`. Returns nil when the user has typed nothing into
    /// the subform — we'd rather store nil than an empty struct.
    private func buildDetails() -> LifeEventDetails? {
        switch selectedType {
        case .militaryService:
            let m = MilitaryDetails(
                rank: nilIfEmpty(militaryRank),
                regiment: nilIfEmpty(militaryRegiment),
                unit: nilIfEmpty(militaryUnit),
                serviceNumber: nilIfEmpty(militaryServiceNumber),
                countryOfService: nilIfEmpty(militaryCountry),
                cemetery: nilIfEmpty(militaryCemetery),
                graveRef: nilIfEmpty(militaryGraveRef),
                honours: nilIfEmpty(militaryHonours)
            )
            return militaryHasAny(m) ? .military(m) : nil
        case .probate:
            let p = ProbateDetails(
                grantType: nilIfEmpty(probateGrantType),
                registry: nilIfEmpty(probateRegistry),
                probateNumber: nilIfEmpty(probateNumber),
                address: nilIfEmpty(probateAddress),
                ageAtDeath: Int(probateAgeAtDeathText.trimmingCharacters(in: .whitespaces))
            )
            return probateHasAny(p) ? .probate(p) : nil
        case .burial:
            let b = BurialDetails(
                cemetery: nilIfEmpty(burialCemetery),
                plot: nilIfEmpty(burialPlot),
                graveRef: nilIfEmpty(burialGraveRef),
                inscription: nilIfEmpty(burialInscription),
                isVeteran: burialIsVeteran
            )
            return burialHasAny(b) ? .burial(b) : nil
        case .census:
            let c = CensusDetails(
                occupation: nilIfEmpty(censusOccupation),
                address: nilIfEmpty(censusAddress),
                district: nilIfEmpty(censusDistrict),
                parish: nilIfEmpty(censusParish),
                household: censusHousehold
            )
            return censusHasAny(c) ? .census(c) : nil
        default:
            return nil
        }
    }

    private func militaryHasAny(_ m: MilitaryDetails) -> Bool {
        m.rank != nil || m.regiment != nil || m.unit != nil
            || m.serviceNumber != nil || m.countryOfService != nil
            || m.cemetery != nil || m.graveRef != nil || m.honours != nil
    }
    private func probateHasAny(_ p: ProbateDetails) -> Bool {
        p.grantType != nil || p.registry != nil || p.probateNumber != nil
            || p.address != nil || p.ageAtDeath != nil
    }
    private func burialHasAny(_ b: BurialDetails) -> Bool {
        b.cemetery != nil || b.plot != nil || b.graveRef != nil
            || b.inscription != nil || b.isVeteran
    }
    private func censusHasAny(_ c: CensusDetails) -> Bool {
        c.occupation != nil || c.address != nil || c.district != nil
            || c.parish != nil || !c.household.isEmpty
    }

    // MARK: - Subforms

    @ViewBuilder private var militarySubform: some View {
        detailGroup("Military Details") {
            detailField("Rank", text: $militaryRank, placeholder: "e.g. Private, Captain")
            detailField("Regiment", text: $militaryRegiment, placeholder: "e.g. Royal Engineers")
            detailField("Unit", text: $militaryUnit, placeholder: "e.g. 2nd Battalion")
            detailField("Service number", text: $militaryServiceNumber)
            detailField("Country of service", text: $militaryCountry, placeholder: "e.g. United Kingdom")
            detailField("Honours", text: $militaryHonours, placeholder: "e.g. DCM, MM")
            detailField("Cemetery", text: $militaryCemetery)
            detailField("Grave reference", text: $militaryGraveRef)
        }
    }

    @ViewBuilder private var probateSubform: some View {
        detailGroup("Probate Details") {
            detailField("Grant type", text: $probateGrantType, placeholder: "Will / Administration")
            detailField("Registry", text: $probateRegistry, placeholder: "e.g. Birmingham District Probate Registry")
            detailField("Probate number", text: $probateNumber)
            detailField("Address at probate", text: $probateAddress)
            detailField("Age at death", text: $probateAgeAtDeathText, placeholder: "e.g. 72")
        }
    }

    @ViewBuilder private var burialSubform: some View {
        detailGroup("Burial Details") {
            detailField("Cemetery", text: $burialCemetery)
            detailField("Plot", text: $burialPlot)
            detailField("Grave reference", text: $burialGraveRef)
            detailField("Inscription", text: $burialInscription)
            Toggle("Veteran", isOn: $burialIsVeteran)
                .font(AppTypography.cardBody)
        }
    }

    @ViewBuilder private var censusSubform: some View {
        detailGroup("Census Details") {
            detailField("Occupation", text: $censusOccupation)
            detailField("Address", text: $censusAddress)
            detailField("District", text: $censusDistrict)
            detailField("Parish", text: $censusParish)
            // Household members are imported from research; the editor
            // shows them read-only so the user can see the roster but
            // doesn't have to maintain it by hand. Adding/removing on the
            // fly is deferred until there's a workflow that needs it.
            if !censusHousehold.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Household (\(censusHousehold.count))")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                    ForEach(Array(censusHousehold.enumerated()), id: \.offset) { _, member in
                        Text("• \(member.name)\(member.relationship.isEmpty ? "" : " (\(member.relationship))")")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailField(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func descriptionPlaceholder(for type: LifeEventType) -> String {
        switch type {
        case .occupation: return "e.g. Framework knitter"
        case .residence: return "e.g. 42 King Street"
        case .militaryService: return "e.g. Royal Navy"
        case .education: return "e.g. Belper Grammar School"
        case .religion: return "e.g. Wesleyan Methodist"
        case .census: return "Household notes, head of household, etc."
        case .baptism, .burial: return "Officiant, parish, witnesses"
        case .probate: return "Executor, beneficiaries"
        case .immigration, .emigration: return "Origin/destination, vessel"
        case .other: return "Describe the event"
        }
    }

    private func parsedDate(_ raw: String) -> GenealogicalDate? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return GenealogicalDate(parsing: trimmed)
    }

    private func nilIfEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A citation FieldSource for a user-entered source name + URL, or empty.
    private func manualSource(name: String, url: String) -> [FieldSource] {
        guard !name.isEmpty || !url.isEmpty else { return [] }
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return [FieldSource(
            origin: SourceOrigin(identifier: slug.isEmpty ? "manual" : slug),
            raw: name.isEmpty ? url : name,
            addedAt: Date(),
            citation: Citation(title: name.isEmpty ? nil : name, url: url.isEmpty ? nil : url),
            quality: nil,
            confidence: confidence)]
    }

    private func save() {
        guard hasSignal else { return }
        let date = parsedDate(dateText)
        let endDate = selectedType.hasDuration ? parsedDate(endDateText) : nil
        let loc = nilIfEmpty(location)
        let desc = nilIfEmpty(eventDescription)
        let details = buildDetails()
        let name = sourceName.trimmingCharacters(in: .whitespaces)
        let url = sourceURL.trimmingCharacters(in: .whitespaces)
        let sources = manualSource(name: name, url: url)

        switch mode {
        case .add(let profileID):
            _ = appState.createLifeEvent(
                profileID: profileID,
                type: selectedType,
                date: date,
                endDate: endDate,
                location: loc,
                locationCode: locationCode,
                description: desc,
                details: details,
                sources: sources,
                confidence: confidence,
                sensitive: sensitive
            )
            // A burial with a source URL (e.g. Find a Grave) also lands as a
            // cited record in the evidence expander, with a link back — without
            // creating a second life event (this one already exists).
            if selectedType == .burial, !url.isEmpty {
                appState.addVerifiedRecord(
                    profileID: profileID,
                    input: VerifiedRecordInput(
                        type: .burial, sourceName: name.isEmpty ? "Source" : name, sourceURL: url,
                        date: dateText, place: location, detail: burialCemetery),
                    projectLifeEvent: false)
            }
        case .edit(let existing):
            var updated = existing
            updated.type = selectedType
            updated.date = date
            updated.endDate = endDate
            updated.location = loc
            updated.locationCode = locationCode
            updated.description = desc
            updated.details = details
            updated.confidence = confidence
            updated.sensitive = sensitive
            updated.sources = existing.sources + sources
            appState.updateLifeEvent(updated)
        }
        dismiss()
    }

    private func deleteEvent() {
        if case .edit(let event) = mode {
            appState.deleteLifeEvent(id: event.id)
            dismiss()
        }
    }
}
