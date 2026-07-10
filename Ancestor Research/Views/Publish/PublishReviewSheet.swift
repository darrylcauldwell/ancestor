import SwiftUI
import CloudKit

// PUBLISHER_SPEC Change 4 (§5) — the pre-publish review screen.
//
// Every person is listed with their RESOLVED policy; auto→name-only
// redactions and never-acknowledged persons demand an explicit human
// confirmation before the first publish that includes them. Per-person
// overrides write `publish_policy`. Publishing runs the engine with
// live progress; every failure surfaces — nothing is swallowed.

@MainActor
@Observable
final class PublishReviewModel {
    struct PersonRow: Identifiable {
        let id: String                       // canonical profile id
        let displayName: String
        let yearsLabel: String
        var storedPolicy: PublishPolicy
        var resolved: ResolvedPublishPolicy
        let potentiallyLiving: Bool
        var acknowledged: Bool
    }

    enum Phase {
        case loading
        case reviewing
        case publishing(String)
        case done(PublishSummary)
        case failed(String)
    }

    struct MediaRow: Identifiable {
        let id: UUID
        let filename: String
        let caption: String?
        let kindLabel: String                // "Photo" / "Document"
        let ownerID: String
        let ownerName: String
        var ownerPublishable: Bool           // owner resolves .full — else opt-in has no effect
        var optedIn: Bool
    }

    let project: Project
    private(set) var rows: [PersonRow] = []
    private(set) var mediaRows: [MediaRow] = []
    private(set) var phase: Phase = .loading
    private var db: ProjectDatabase?

    init(project: Project) {
        self.project = project
    }

    var unacknowledgedCount: Int { rows.filter { !$0.acknowledged }.count }
    var redactedCount: Int { rows.filter { $0.resolved == .nameOnly }.count }
    var omittedCount: Int { rows.filter { $0.resolved == .omit }.count }
    var sharedMediaCount: Int { mediaRows.filter { $0.optedIn && $0.ownerPublishable }.count }
    var canPublish: Bool {
        if case .reviewing = phase { return unacknowledgedCount == 0 }
        return false
    }

    func load() {
        do {
            let (_, database) = try ProjectStore.openProject(project.id)
            self.db = database
            let snapshot = try database.buildSnapshot()
            let policies = try database.loadPublishPolicies()
            let acknowledged = try database.loadPublishAcknowledgements()
            var built: [PersonRow] = []
            for (id, profile) in snapshot.profiles where !profile.isDeleted {
                let living = snapshot.completeness(for: id).potentiallyLiving
                let stored = policies[id] ?? .auto
                var years = ""
                if let birthYear = profile.birthDate?.bestYear { years = "b. \(birthYear)" }
                if let deathYear = profile.deathDate?.bestYear {
                    years += years.isEmpty ? "d. \(deathYear)" : " – d. \(deathYear)"
                } else if living {
                    years += years.isEmpty ? "possibly living" : " – possibly living"
                }
                built.append(PersonRow(
                    id: id,
                    displayName: profile.displayName,
                    yearsLabel: years,
                    storedPolicy: stored,
                    resolved: PublishPolicyResolver.resolve(override: stored, potentiallyLiving: living),
                    potentiallyLiving: living,
                    acknowledged: acknowledged[id] != nil
                ))
            }
            // Attention first: unacknowledged, then redacted, then name.
            rows = built.sorted {
                if $0.acknowledged != $1.acknowledged { return !$0.acknowledged }
                if ($0.resolved == .nameOnly) != ($1.resolved == .nameOnly) { return $0.resolved == .nameOnly }
                return $0.displayName < $1.displayName
            }

            // Media opt-in (§4.2): profile-targeted photos/documents only —
            // transcriptions are citation material, lifeEvent/fieldSource
            // targets are excluded from v1 by decision log #7.
            let optIns = try database.loadPublishMediaOptIns()
            let resolvedByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.resolved) })
            mediaRows = try database.loadAttachments().compactMap { attachment in
                guard case .profile(let ownerID) = attachment.attachedTo,
                      attachment.mediaType != .transcription,
                      let owner = snapshot.profiles[ownerID]
                else { return nil }
                return MediaRow(
                    id: attachment.id,
                    filename: attachment.filename,
                    caption: attachment.caption,
                    kindLabel: attachment.mediaType == .photo ? "Photo" : "Document",
                    ownerID: ownerID,
                    ownerName: owner.displayName,
                    ownerPublishable: resolvedByID[ownerID] == .full,
                    optedIn: optIns.contains(attachment.id))
            }
            .sorted {
                if $0.ownerName != $1.ownerName { return $0.ownerName < $1.ownerName }
                return $0.filename < $1.filename
            }
            phase = .reviewing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func setPolicy(_ policy: PublishPolicy, for rowID: String) {
        guard let db, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        do {
            try db.setPublishPolicy(profileID: rowID, policy: policy)
            rows[index].storedPolicy = policy
            rows[index].resolved = PublishPolicyResolver.resolve(
                override: policy, potentiallyLiving: rows[index].potentiallyLiving)
            // A deliberate change is itself an acknowledgement.
            try db.acknowledgePublishPolicies(profileIDs: [rowID], at: Date())
            rows[index].acknowledged = true
            // Policy changes flip whether this person's media can publish.
            let publishable = rows[index].resolved == .full
            for mediaIndex in mediaRows.indices where mediaRows[mediaIndex].ownerID == rowID {
                mediaRows[mediaIndex].ownerPublishable = publishable
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func setMediaOptIn(_ optedIn: Bool, for attachmentID: UUID) {
        guard let db, let index = mediaRows.firstIndex(where: { $0.id == attachmentID }) else { return }
        do {
            try db.setPublishMediaOptIn(attachmentID: attachmentID, optedIn: optedIn)
            mediaRows[index].optedIn = optedIn
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func acknowledgeAll() {
        guard let db else { return }
        do {
            try db.acknowledgePublishPolicies(
                profileIDs: rows.filter { !$0.acknowledged }.map(\.id), at: Date())
            for index in rows.indices { rows[index].acknowledged = true }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Change 5 — fetch-or-create the share and present Apple's
    /// cloud-sharing window. Failures surface in the sheet's failed phase.
    func inviteFamily() {
        guard let db else { return }
        let projectID = project.id
        let projectName = project.name
        Task { [weak self] in
            do {
                let (share, container) = try await PublishSharing.share(
                    projectID: projectID, projectName: projectName, db: db)
                CloudSharingPresenter.present(share: share, container: container)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func publish() {
        guard let db, canPublish else { return }
        phase = .publishing("Starting…")
        let projectID = project.id
        let mediaDir = ProjectStore.mediaDirectory(for: projectID)
        Task { [weak self] in
            do {
                let summary = try await PublishEngine.publish(
                    projectID: projectID, db: db, mediaSourceDirectory: mediaDir,
                    progress: { [weak self] message in
                        if case .publishing = self?.phase { self?.phase = .publishing(message) }
                    })
                self?.phase = .done(summary)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct PublishReviewSheet: View {
    enum ReviewTab: String, CaseIterable {
        case people = "People"
        case media = "Media"
    }

    @State var model: PublishReviewModel
    @State private var tab: ReviewTab = .people
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { model.load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Publish “\(model.project.name)” to iCloud")
                    .font(AppTypography.cardTitle)
                Text("Living people are shared as name-only cards. Confirm every redaction before the tree is published to your family.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading tree…").frame(maxHeight: .infinity)
        case .reviewing:
            reviewList
        case .publishing(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(AppTypography.cardBody).foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        case .done(let summary):
            VStack(spacing: 8) {
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("Published generation \(summary.generation)")
                    .font(AppTypography.cardTitle)
                Text("\(summary.totalRecords) records confirmed by iCloud — \(summary.stats.inserted) new, \(summary.stats.updated) updated, \(summary.stats.deleted) removed, \(summary.stats.unchanged) unchanged.")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !summary.stats.missingMediaPaths.isEmpty {
                    Text("\(summary.stats.missingMediaPaths.count) media file(s) were missing on disk and were skipped.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Invite Family…") { model.inviteFamily() }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Publishing failed").font(AppTypography.cardTitle)
                Text(message)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
            .padding()
            .frame(maxHeight: .infinity)
        }
    }

    private var reviewList: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(ReviewTab.allCases, id: \.self) { tab in
                    Text(tab == .media
                         ? "Media (\(model.sharedMediaCount)/\(model.mediaRows.count))"
                         : "People (\(model.rows.count))")
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)

            switch tab {
            case .people: peopleList
            case .media: PublishMediaList(model: model)
            }

            Divider()
            HStack {
                Text(tab == .people
                     ? "\(model.rows.count) people — \(model.redactedCount) name-only, \(model.omittedCount) not published"
                     : "\(model.sharedMediaCount) of \(model.mediaRows.count) photos & documents will be shared — each counts against your iCloud storage")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.unacknowledgedCount > 0 {
                    Button("Confirm All Redactions (\(model.unacknowledgedCount))") {
                        model.acknowledgeAll()
                    }
                }
                Button("Publish") { model.publish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPublish)
                    .help(model.canPublish
                          ? "Publish the redacted tree to iCloud"
                          : "Confirm every person’s policy first")
            }
            .padding()
        }
    }

    private var peopleList: some View {
        List {
                ForEach(model.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName).font(AppTypography.cardBody)
                            Text(row.yearsLabel)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        policyBadge(row)
                        Picker("", selection: Binding(
                            get: { row.storedPolicy },
                            set: { model.setPolicy($0, for: row.id) }
                        )) {
                            Text("Auto").tag(PublishPolicy.auto)
                            Text("Full").tag(PublishPolicy.full)
                            Text("Name only").tag(PublishPolicy.nameOnly)
                            Text("Don’t publish").tag(PublishPolicy.omit)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        if !row.acknowledged {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                                .help("Not yet confirmed")
                        }
                    }
                }
            }
    }

    private func policyBadge(_ row: PublishReviewModel.PersonRow) -> some View {
        let (label, color): (String, Color) = switch row.resolved {
        case .full: ("Full", .green)
        case .nameOnly: ("Name only", .orange)
        case .omit: ("Hidden", .red)
        }
        return Text(label)
            .font(AppTypography.badge)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
