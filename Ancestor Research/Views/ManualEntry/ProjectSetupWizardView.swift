import SwiftUI

/// PROJECT_ONBOARDING_SPEC Part A — the project SETUP wizard (distinct from
/// the family-entry `OnboardingWizardView`). A short, skippable flow shown once
/// per project at create / GEDCOM import / WikiTree connect, surfacing the
/// settings that materially change research quality but are otherwise
/// discoverable-by-accident.
///
/// Steps: 1 — home region / Chapman anchor; 2 — enable local AI (the unified
/// consent screen for the reasoning model + semantic embedder, replacing the
/// two previously-silent downloads). Steps 3–4 (home person, sources) grow
/// later.
///
/// Doctrine: nothing here blocks diving in. Every step is skippable and the
/// defaults (no anchor → derive per profile; no models → deterministic) leave
/// the project fully usable.
struct ProjectSetupWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var sourceRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome

    // Step 2 — download progress (nil = not downloading), and the persisted
    // consent flag for the semantic embedder (shared with the launch
    // auto-load in ContentRoot and the Settings toggle).
    @State private var reasoningProgress: Double?
    @State private var semanticProgress: Double?
    @AppStorage("semanticEmbedderEnabled") private var semanticEmbedderEnabled = false

    // Step 3 — local home-person selection (owned here so "Change" can clear
    // the search without persisting nil; the pick persists on change).
    @State private var homePersonID: String?
    @State private var homePersonSeeded = false

    private enum Step: Int, CaseIterable {
        case welcome        // Step 0 — orientation
        case homeRegion     // Step 1 — Chapman anchor
        case localAI        // Step 2 — enable local AI
        case homePerson     // Step 3 — you-are-here anchor
        case sources        // Step 4 — free sources + etiquette

        var title: String {
            switch self {
            case .welcome:    return "A couple of quick choices"
            case .homeRegion: return "Where is this family mostly from?"
            case .localAI:    return "Local AI (optional)"
            case .homePerson: return "Who is the tree centred on?"
            case .sources:    return "Where research looks"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .welcome:    welcomeStep
                    case .homeRegion: homeRegionStep
                    case .localAI:    localAIStep
                    case .homePerson: homePersonStep
                    case .sources:    sourcesStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            if !homePersonSeeded {
                homePersonID = appState.currentProject?.homePersonID
                homePersonSeeded = true
            }
        }
        .onChange(of: homePersonID) { _, newValue in
            // Persist only a positive pick — "Change" clears the local
            // selection to re-open the search and must not clear the anchor.
            if let newValue { appState.setHomePerson(id: newValue) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up this project")
                .font(.title3).fontWeight(.semibold)
            Text(step.title)
                .font(.title2).fontWeight(.semibold)
            ProgressView(value: progress)
                .tint(.accentColor)
        }
        .padding(20)
    }

    private var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    // MARK: - Step 0 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This takes about a minute and you can skip any part — the app works fully with the defaults.")
                .foregroundStyle(.secondary)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home region").fontWeight(.semibold)
                    Text("The county your research falls back to when a record has no place of its own. The single biggest lever on search quality.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "map").foregroundStyle(.blue)
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local AI").fontWeight(.semibold)
                    Text("Optional on-device models that sharpen suggestions and clustering. Off by default — the app is fully functional without them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "cpu").foregroundStyle(.blue)
            }
            Text("You can change any of this later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 1 — Home region

    private var homeRegionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick the county most of this family comes from. It anchors searches for any relative whose own birth place can't provide one — people who already have a location keep deriving their own county.")
                .foregroundStyle(.secondary)

            // Live-saving binding, exactly like the Settings home-county picker
            // (via AppState.setHomeChapmanCode) — same registry, so the two can
            // never diverge. "" = derive per profile (no hardcoded region).
            Picker("Home county", selection: Binding(
                get: { appState.currentProject?.homeChapmanCode ?? "" },
                set: { appState.setHomeChapmanCode($0) }
            )) {
                Text("None — derive per profile").tag("")
                ForEach(UKChapmanCodes.shared.gbAndChannelIslands(), id: \.code) { entry in
                    Text("\(entry.name) (\(entry.code))").tag(entry.code)
                }
            }
            .pickerStyle(.menu)

            if (appState.currentProject?.homeChapmanCode ?? "").isEmpty {
                Text("No anchor set — each profile derives its own county from its birth location. You can set one any time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 2 — Enable local AI

    private var localAIStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("These on-device models are optional and off by default. Nothing leaves your Mac, and every feature has a deterministic fallback — enable them only if you want the extra help.")
                .foregroundStyle(.secondary)

            reasoningModelRow
            Divider()
            semanticModelRow
        }
    }

    /// The reasoning model. "Enabled" here means "downloaded" — the app
    /// auto-loads it on launch once the files are present, so a download is
    /// the whole opt-in (no separate flag).
    private var reasoningModelRow: some View {
        let model = ReasoningModel.default
        let downloaded = LocalInferenceService.shared.onDiskBytes(for: model) > 1_000_000_000
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reasoning model — \(model.displayName)").fontWeight(.semibold)
                    Text("Next-search suggestions, candidate comparison, evidence extraction. About \(Int(model.memoryEstimateGB)) GB.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if downloaded {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else if let p = reasoningProgress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    Button("Download") { downloadReasoning(model) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    /// The semantic embedder. Its opt-in IS a persisted flag (unlike the
    /// reasoning model, it had no auto-use before) — enabling it downloads the
    /// model and, from then on, the app auto-uses it whenever present.
    @ViewBuilder
    private var semanticModelRow: some View {
        #if canImport(MLXEmbedders) && canImport(MLX)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Semantic clustering").fontWeight(.semibold)
                    Text("Tighter \u{201C}Possible People\u{201D} grouping via meaning, not just spelling. About \(MLXTextEmbedder.estimatedSizeMB) MB.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = semanticProgress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    Toggle("", isOn: Binding(
                        get: { semanticEmbedderEnabled },
                        set: { on in
                            semanticEmbedderEnabled = on
                            if on { downloadSemantic() }
                        }
                    ))
                    .labelsHidden()
                }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 2) {
            Text("Semantic clustering").fontWeight(.semibold)
            Text("Not available in this build.")
                .font(.callout).foregroundStyle(.secondary)
        }
        #endif
    }

    // MARK: - Step 3 — Home person

    private var homePersonStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick the person the tree is centred on — usually you, or whoever you research outward from. It anchors navigation, the relationship calculator, and how far automated research reaches.")
                .foregroundStyle(.secondary)

            if appState.snapshot.profiles.isEmpty {
                Text("No people yet — add some first, then set a home person any time from a profile's menu.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // The reusable searchable picker (same control AddFamily and the
                // relationship calculator use). Persisted on change via
                // AppState.setHomePerson.
                ProfilePickerField(
                    label: "Home person",
                    snapshot: appState.snapshot,
                    selectedID: $homePersonID)
                if homePersonID == nil {
                    Text("Optional — you can set or change this later from any profile's menu (“Set as Home Person”).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 4 — Sources

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Research looks across these free UK record sources on your behalf. They're enabled by default — leave them as they are, or turn any off.")
                .foregroundStyle(.secondary)

            ForEach(generalSources, id: \.sourceID) { source in
                Toggle(isOn: Binding(
                    get: { sourceRegistry.isEnabled(source.sourceID) },
                    set: { sourceRegistry.setEnabled(sourceID: source.sourceID, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.descriptiveName).font(.callout)
                        Text(source.tosStatus.summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }

            Label {
                Text("Some of these are run by volunteers with daily limits. The app paces itself automatically and never hammers them — you don't need to do anything.")
                    .font(.callout).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "hand.raised").foregroundStyle(.blue)
            }
            Text("Full terms, coverage, and per-source detail are in Settings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The bundled general sources, sorted for a stable list.
    private var generalSources: [any RecordSource] {
        sourceRegistry.allSources()
            .filter { $0.kind == .general }
            .sorted { $0.descriptiveName < $1.descriptiveName }
    }

    // MARK: - Downloads (non-blocking; owned by the shared services, so they
    // continue even if the wizard is dismissed mid-download)

    private func downloadReasoning(_ model: ReasoningModel) {
        reasoningProgress = 0
        Task {
            try? await LocalInferenceService.shared.loadModel(
                configuration: model.configuration,
                onProgress: { fraction in
                    Task { @MainActor in reasoningProgress = fraction }
                })
            await MainActor.run { reasoningProgress = nil }
        }
    }

    private func downloadSemantic() {
        #if canImport(MLXEmbedders) && canImport(MLX)
        semanticProgress = 0
        Task {
            try? await MLXTextEmbedder.shared.loadModel(
                onProgress: { fraction in
                    Task { @MainActor in semanticProgress = fraction }
                })
            await MainActor.run { semanticProgress = nil }
        }
        #endif
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
                    .buttonStyle(.glass)
            }
            Spacer()
            Button("Skip setup") { finish() }
                .buttonStyle(.glass)
                .controlSize(.small)
            if step == Step.allCases.last {
                Button("Done") { finish() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Navigation

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    /// Mark setup done (so it never auto-offers again) and close. Both "Done"
    /// and "Skip setup" route here — skipping is a valid completion. The home
    /// region was already saved live by its picker; any in-flight model
    /// download continues on its shared service after this closes.
    private func finish() {
        appState.finishSetup()
        dismiss()
    }
}
