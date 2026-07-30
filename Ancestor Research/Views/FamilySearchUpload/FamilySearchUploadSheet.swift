import SwiftUI
import AncestorKit

// FamilySearch User Tree upload wizard (WL5 — FAMILYSEARCH_TREES_WRITE_SPEC
// §6). Clones the PublishReviewSheet idiom: an @Observable model with a Phase
// enum, review-then-confirm before anything leaves the machine, live progress
// during the run, and an honest summary (including per-entity failures) after.
// The two irreversibles — the one-way hidden flip and the lifetime-fixed
// access fields — are stated in plain language and explicitly confirmed.

@MainActor
@Observable
final class FamilySearchUploadModel {
    enum Phase {
        case loading
        case reviewing
        case uploading(String)
        case done(FSUploadSummary)
        case failed(String)
    }

    private let database: ProjectDatabase
    private(set) var phase: Phase = .loading
    private(set) var plan: FSUploadPlan?

    var treeName: String
    var treeDescription: String = "Uploaded from Ancestor Research."
    var isPrivate = true
    var oneWayConfirmed = false
    var startingProfileID: String?
    var signInNeeded = false

    init(database: ProjectDatabase, suggestedName: String) {
        self.database = database
        self.treeName = suggestedName
    }

    var includedCount: Int { plan?.persons.count ?? 0 }
    var omittedLiving: Int { (plan?.omitted.values.filter { $0.contains("living") }.count) ?? 0 }
    var omittedOther: Int { (plan?.omitted.count ?? 0) - omittedLiving }
    var relationshipCount: Int { (plan?.couples.count ?? 0) + (plan?.childAndParents.count ?? 0) }
    var sourceCount: Int { plan?.sourceDescriptions.count ?? 0 }
    var personChoices: [(id: String, name: String)] {
        plan?.persons.map { ($0.profileID, $0.displayName) } ?? []
    }
    var canUpload: Bool {
        if case .reviewing = phase {
            return oneWayConfirmed && !treeName.trimmingCharacters(in: .whitespaces).isEmpty && includedCount > 0
        }
        return false
    }

    private var config: FamilySearchTreeEncoder.Config {
        .init(treeName: treeName.trimmingCharacters(in: .whitespaces),
              treeDescription: treeDescription,
              environment: .beta,
              currentYear: Calendar.current.component(.year, from: Date()))
    }

    func load() {
        do {
            let snapshot = try database.buildSnapshot()
            let relationshipCitations = (try? database.familySearchRelationshipCitations()) ?? [:]
            plan = try FamilySearchTreeEncoder.makePlan(
                snapshot: snapshot, relationshipCitations: relationshipCitations, config: config)
            if startingProfileID == nil { startingProfileID = plan?.persons.first?.profileID }
            phase = .reviewing
        } catch {
            phase = .failed("Could not prepare the upload: \(error.localizedDescription)")
        }
    }

    func upload() {
        guard canUpload else { return }
        phase = .uploading("Preparing…")
        Task { [weak self] in
            guard let self else { return }
            guard await FamilySearchTokenStore.shared.validAccessToken(environment: .beta) != nil else {
                self.signInNeeded = true
                self.phase = .reviewing
                return
            }
            do {
                // Re-plan with the final name/description (cheap, pure) so the
                // group/tree bodies carry what the user actually typed.
                let snapshot = try self.database.buildSnapshot()
                let relationshipCitations = (try? self.database.familySearchRelationshipCitations()) ?? [:]
                let config = self.config
                let plan = try FamilySearchTreeEncoder.makePlan(
                    snapshot: snapshot, relationshipCitations: relationshipCitations, config: config)

                // Resume an interrupted run for this environment when one
                // exists — otherwise a fresh run id.
                let prior = try? self.database.latestFamilySearchUploadRun(environment: "beta")
                let runID = (prior?.phase == "uploading" || prior?.phase == "created")
                    ? prior!.id : UUID().uuidString

                let client = FamilySearchClient(
                    environment: .beta,
                    tokenSource: KeychainFamilySearchTokenSource(environment: .beta))
                let service = FamilySearchTreeUploadService(
                    client: client, database: self.database, environment: .beta)
                let summary = try await service.upload(
                    plan: plan, config: config, runID: runID,
                    startingProfileID: self.startingProfileID,
                    isPrivate: self.isPrivate,
                    progress: { message in
                        Task { @MainActor [weak self] in
                            if case .uploading = self?.phase { self?.phase = .uploading(message) }
                        }
                    })
                self.phase = .done(summary)
            } catch FamilySearchClientError.notAuthenticated {
                self.signInNeeded = true
                self.phase = .reviewing
            } catch {
                self.phase = .failed("Upload interrupted: \(error.localizedDescription). Progress is saved — run Upload again to resume.")
            }
        }
    }
}

/// Identifiable wrapper so presentation uses `.sheet(item:)` (the
/// `isPresented` + `if let` shape renders an EmptyView rectangle — project
/// memory feedback_sheet_isPresented_race).
struct FamilySearchUploadContext: Identifiable {
    let id = UUID()
    let database: ProjectDatabase
    let suggestedName: String
}

struct FamilySearchUploadSheet: View {
    @State var model: FamilySearchUploadModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { model.load() }
        .onChange(of: model.signInNeeded) { _, needed in
            if needed {
                dismiss()
                appState.familySearchSignInPrompt = true
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Upload Tree to FamilySearch", systemImage: "square.and.arrow.up.on.square")
                .font(AppTypography.popoverTitle)
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Preparing upload…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .reviewing:
            reviewForm

        case .uploading(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                Text("Progress is saved continuously — if the upload is interrupted, running it again resumes where it stopped.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .done(let summary):
            doneView(summary)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(AppTypography.cardBody)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button("Try Again") { model.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewForm: some View {
        Form {
            Section("What uploads") {
                LabeledContent("Deceased persons", value: "\(model.includedCount)")
                LabeledContent("Relationships", value: "\(model.relationshipCount)")
                LabeledContent("Source citations", value: "\(model.sourceCount)")
                if model.omittedLiving > 0 {
                    LabeledContent("Living people excluded", value: "\(model.omittedLiving)")
                        .help("Living and potentially-living people never leave the app.")
                }
                if model.omittedOther > 0 {
                    LabeledContent("Empty placeholders excluded", value: "\(model.omittedOther)")
                }
            }
            Section("Tree") {
                TextField("Tree name", text: $model.treeName)
                TextField("Description", text: $model.treeDescription)
                Picker("Starting person", selection: $model.startingProfileID) {
                    ForEach(model.personChoices, id: \.id) { choice in
                        Text(choice.name).tag(Optional(choice.id))
                    }
                }
                .help("The person FamilySearch opens the tree on.")
            }
            Section("Visibility") {
                Toggle("Keep the tree private on FamilySearch", isOn: $model.isPrivate)
                Text(model.isPrivate
                     ? "Private: only you (and people you invite on FamilySearch) can see it. It will not appear in FamilySearch searches or matches — so FamilySearch cannot send record hints back for these people until it is made public."
                     : "Public: the deceased persons in this tree become searchable on FamilySearch, and FamilySearch can match records against them (the hints this app can then harvest).")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $model.oneWayConfirmed) {
                    Text("I understand the tree becomes permanently visible in my FamilySearch account once uploaded (FamilySearch does not allow re-hiding it), and that after 2 years of inactivity FamilySearch makes private trees public.")
                        .font(AppTypography.cardMeta)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Upload") { model.upload() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canUpload)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func doneView(_ summary: FSUploadSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: summary.failures.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(summary.failures.isEmpty ? .green : .orange)
                VStack(alignment: .leading) {
                    Text(summary.finalized
                         ? "“\(summary.treeName)” is live on FamilySearch (beta)"
                         : "“\(summary.treeName)” uploaded — not yet finalized")
                        .font(AppTypography.cardTitle)
                    Text("Tree ID: \(summary.treeID)")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("Persons created").font(AppTypography.cardBody)
                    Text("\(summary.personsCreated)\(summary.personsSkipped > 0 ? " (+\(summary.personsSkipped) already uploaded)" : "")")
                        .font(AppTypography.cardBody).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Relationships").font(AppTypography.cardBody)
                    Text("\(summary.relationshipsCreated)\(summary.relationshipsSkipped > 0 ? " (+\(summary.relationshipsSkipped) already uploaded)" : "")")
                        .font(AppTypography.cardBody).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Sources").font(AppTypography.cardBody)
                    Text("\(summary.sourceDescriptionsCreated) descriptions, \(summary.sourceReferencesAttached) attached")
                        .font(AppTypography.cardBody).foregroundStyle(.secondary)
                }
                if !summary.omitted.isEmpty {
                    GridRow {
                        Text("Kept local").font(AppTypography.cardBody)
                        Text("\(summary.omitted.count) living/placeholder people")
                            .font(AppTypography.cardBody).foregroundStyle(.secondary)
                    }
                }
            }
            if let note = summary.finalizeNote {
                Text(note)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
            }
            if !summary.failures.isEmpty {
                Text("\(summary.failures.count) item(s) failed — run Upload again to retry them:")
                    .font(AppTypography.cardMeta)
                List(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.stage) \(failure.localKey): \(failure.message)")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 80, maxHeight: 140)
            }
            Spacer()
            HStack {
                Link("Open FamilySearch (beta)", destination: URL(string: "https://beta.familysearch.org")!)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
