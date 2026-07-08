import SwiftUI
import UniformTypeIdentifiers

struct ProjectPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var showingNewProject = false

    // .ancestor archive export/import (M13)
    @State private var exportingProjectID: UUID?
    @State private var publishTarget: Project?
    @State private var unpublishTarget: Project?
    @State private var sharingBusy = false
    @State private var bundleExportError: String?
    @State private var pendingExportName: String = "project"
    @State private var showingExporter = false

    /// Single, enum-driven file-import slot. SwiftUI on macOS swallows
    /// silently when multiple `.fileImporter` modifiers are stacked on the
    /// same view — only one will trigger and the others get nothing on
    /// click. Routing every import flavour through one importer slot
    /// avoids the bug. Set this from any button; the importer modifier
    /// reads the current target to pick the right content types and the
    /// result handler routes to the right ingestion path.
    ///
    /// Note: the presentation flag is a *separate* `Bool` rather than a
    /// computed `Binding` over `activeImporter`. SwiftUI calls the
    /// presented-binding's setter (clearing the target) BEFORE firing
    /// the result handler, so a computed binding silently nukes the
    /// target the handler needs to read. Two states, one cleared by
    /// SwiftUI, the other cleared by the handler.
    @State private var activeImporter: ImporterTarget?
    @State private var isImporterPresented: Bool = false

    /// Set alongside `activeImporter = .corrections` so the result handler
    /// knows which existing project the GEDCOM-as-suggestions import is
    /// targeted at (M22).
    @State private var correctionsTargetProjectID: UUID?

    enum ImporterTarget: Identifiable, Hashable {
        case ancestor       // .ancestor archive → new project (M13)
        case gedcom         // .ged or .gdz → new project (M15)
        case corrections    // .ged → suggestions for an existing project (M22)
        var id: Self { self }
    }

    // Archive / permanent-delete
    @State private var showArchived = false
    @State private var pendingHardDelete: Project?

    // Drag-and-drop highlight state. Wrapped by .onDrop so the welcome window
    // shows an accent-coloured border the moment a draggable file is over it.
    @State private var isDropTargeted = false

    private var activeProjects: [Project] {
        appState.availableProjects.filter { !$0.isArchived }
    }
    private var archivedProjects: [Project] {
        appState.availableProjects.filter(\.isArchived)
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.availableProjects.isEmpty {
                welcomeContent
            } else {
                returningContent
            }

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 12)
            }
        }
        .padding(36)
        .frame(minWidth: 700, minHeight: 520)
        .background(.ultraThinMaterial)
        // Drag a .ged / .gdz / .ancestor file onto the window to import.
        // Discoverable for first-time users who have a tree file in Finder
        // and would rather drop than navigate the importer.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: AncestorArchiveExportRequest(),
            contentType: .ancestorArchive,
            defaultFilename: pendingExportName
        ) { result in
            handleExportResult(result)
        }
        .alert("Family bundle export failed", isPresented: Binding(
            get: { bundleExportError != nil },
            set: { if !$0 { bundleExportError = nil } }
        )) {
            Button("OK", role: .cancel) { bundleExportError = nil }
        } message: {
            Text(bundleExportError ?? "")
        }
        .sheet(item: $publishTarget) { project in
            PublishReviewSheet(model: PublishReviewModel(project: project))
        }
        .confirmationDialog(
            "Unpublish “\(unpublishTarget?.name ?? "")” from iCloud?",
            isPresented: Binding(
                get: { unpublishTarget != nil },
                set: { if !$0 { unpublishTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unpublish", role: .destructive) {
                if let project = unpublishTarget { runUnpublish(project) }
                unpublishTarget = nil
            }
            Button("Cancel", role: .cancel) { unpublishTarget = nil }
        } message: {
            Text("This removes the shared copy from iCloud and revokes every family invitation. Your research data on this Mac is unaffected, and you can publish again at any time.")
        }
        // Single importer, enum-driven — see `activeImporter` doc.
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: contentTypes(for: activeImporter ?? .gedcom),
            allowsMultipleSelection: false
        ) { result in
            let target = activeImporter
            activeImporter = nil
            switch target {
            case .ancestor:    handleImportResult(result)
            case .gedcom:      handleGEDCOMImportResult(result)
            case .corrections: handleCorrectionsImportResult(result)
            case .none:        break
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingHardDelete?.name ?? "")\" permanently?",
            isPresented: Binding(
                get: { pendingHardDelete != nil },
                set: { if !$0 { pendingHardDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                if let project = pendingHardDelete {
                    appState.deleteProject(project.id)
                }
                pendingHardDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingHardDelete = nil }
        } message: {
            Text("This removes the SQLite file, media, thumbnails, and backups. It cannot be undone.")
        }
    }

    // MARK: - Welcome (no projects yet)

    /// First-time / reviewer landing. The hero invites the visitor to open
    /// the bundled Sample Family in one click — no GEDCOM, no WikiTree
    /// account, no Settings detour. Secondary actions sit beneath an
    /// "or start your own" divider with reduced visual weight so the path
    /// of least resistance is obvious. Aligned with the App Review feedback
    /// from May 2026 which got stuck on the previous all-buttons-equal layout.
    @ViewBuilder
    private var welcomeContent: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(AppConstants.displayName)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Research your family tree against seven free historical sources.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                appState.openSampleProject()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "tree.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open Sample Tree")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("See how the app works with a fictional 30-person family.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 520, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .help("Open a fictional 30-profile family for exploring the app's features")
            .accessibilityHint("Open a fictional 30-profile family for exploring the app's features")

            HStack(spacing: 12) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(maxWidth: 90, maxHeight: 1)
                Text("or start your own")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(.tertiary)
                    .frame(maxWidth: 90, maxHeight: 1)
            }

            HStack(spacing: 12) {
                Button {
                    showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.glass)

                Button {
                    presentImporter(.gedcom)
                } label: {
                    Label("Import GEDCOM…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)

                Button {
                    presentImporter(.ancestor)
                } label: {
                    Label("Import .ancestor…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.glass)
            }

            VStack(spacing: 4) {
                Text("Tip: drag a .ged, .gdz or .ancestor file onto this window to import.")
                Link(
                    "Exporting from Ancestry, MyHeritage, or FindMyPast?",
                    destination: URL(string: "https://github.com/darrylcauldwell/ancestor/blob/main/SUPPORT.md#exporting-a-gedcom-from-another-tree-app")!
                )
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Returning visitor (projects exist)

    /// Streamlined list view shown when at least one project already exists.
    /// The hero is dropped — the visitor knows what the app is — and the
    /// list of projects is the primary surface. New Project + Sample Tree
    /// stay easily reachable from a slim toolbar row above the list.
    @ViewBuilder
    private var returningContent: some View {
        VStack(spacing: 14) {
            HStack {
                Text(AppConstants.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    appState.openSampleProject()
                } label: {
                    Label("Sample Tree", systemImage: "tree")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Open a fictional 30-profile family for exploring the app's features")
                Button {
                    presentImporter(.gedcom)
                } label: {
                    Label("Import GEDCOM…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button {
                    presentImporter(.ancestor)
                } label: {
                    Label("Import .ancestor…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button {
                    showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: 620)

            List {
                Section {
                    ForEach(activeProjects) { project in
                        projectRow(project)
                            .contextMenu { activeContextMenu(project) }
                    }
                }
                if showArchived && !archivedProjects.isEmpty {
                    Section("Archived") {
                        ForEach(archivedProjects) { project in
                            projectRow(project)
                                .opacity(0.6)
                                .contextMenu { archivedContextMenu(project) }
                        }
                    }
                }
            }
            .frame(maxWidth: 620, minHeight: 320)

            if !archivedProjects.isEmpty {
                Toggle(isOn: $showArchived) {
                    Text("Show archived (\(archivedProjects.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: 620, alignment: .trailing)
            }
        }
    }

    // MARK: - Import target → allowed content types

    /// Show the import file picker for the given target. Always set both
    /// `activeImporter` AND `isImporterPresented` together — the
    /// presentation flag drives SwiftUI's panel; the target tells the
    /// result handler which ingestion path to take. Setting only one
    /// silently does nothing (the bug fixed in T27.5).
    private func presentImporter(_ target: ImporterTarget) {
        activeImporter = target
        isImporterPresented = true
    }

    /// Allowed types per import target. `.data` is deliberately omitted —
    /// including it makes the macOS panel show every file (defeating the
    /// filter). If users have legitimately misnamed files that the system
    /// doesn't tag as `.ged`/`.gdz`/`.ancestor`, drag-and-drop still works
    /// (the drop handler routes by extension).
    private func contentTypes(for target: ImporterTarget) -> [UTType] {
        switch target {
        case .ancestor:    return [.ancestorArchive]
        case .gedcom:      return [.gedcomFile, .gedZipFile]
        case .corrections: return [.gedcomFile]
        }
    }

    // MARK: - Drag-and-drop handler

    /// Accept a single dropped file URL and route to the right importer
    /// based on extension. Mirrors the buttons' import paths so behaviour
    /// is identical whether the user drags or clicks. Returns true to
    /// claim the drop so the system shows a green plus cursor.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                routeImportedFile(url)
            }
        }
        return true
    }

    /// Branch a dropped URL to the right importer. Mirrors
    /// `handleGEDCOMImportResult` + `handleImportResult` so the drop path
    /// produces identical results to clicking the corresponding button.
    private func routeImportedFile(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ancestor", "zip":
            appState.importProjectArchive(from: url)
        case "gdz":
            appState.importGEDZip(from: url)
        case "ged":
            let projectName = url.deletingPathExtension().lastPathComponent
            appState.createAndImportProject(
                name: projectName.isEmpty ? "Imported GEDCOM" : projectName,
                source: .gedcom(path: url.path)
            )
        default:
            appState.errorMessage = "Unsupported file: \(url.lastPathComponent). Use .ged, .gdz, or .ancestor."
        }
    }

    // MARK: - Row + context menus

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        Button {
            appState.openProject(project)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.headline)
                        if project.isArchived {
                            Text("Archived")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(project.source.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = project.archivedAt ?? project.lastRefreshed {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// PUBLISHER_SPEC Change 5 — Apple's cloud-sharing window for the
    /// published tree (invite + manage participants; read-only enforced
    /// server-side). Requires a prior publish.
    private func presentFamilySharing(_ project: Project) {
        sharingBusy = true
        Task {
            defer { sharingBusy = false }
            do {
                let (_, db) = try ProjectStore.openProject(project.id)
                let (share, container) = try await PublishSharing.share(
                    projectID: project.id, projectName: project.name, db: db)
                CloudSharingPresenter.present(share: share, container: container)
            } catch {
                bundleExportError = error.localizedDescription
            }
        }
    }

    /// PUBLISHER_SPEC Change 5 — unpublish (GDPR-erasure path). Zone
    /// deletion evicts all participants server-side; identity and
    /// generation survive locally so a republish stays monotonic.
    private func runUnpublish(_ project: Project) {
        Task {
            do {
                let (_, db) = try ProjectStore.openProject(project.id)
                try await PublishSharing.unpublish(projectID: project.id, db: db)
            } catch {
                bundleExportError = error.localizedDescription
            }
        }
    }

    /// PUBLISHER_SPEC Change 2 — offline family bundle (redacted §4
    /// schema as JSON + media). Same permanent record UUIDs the CloudKit
    /// publish will use; never touches published_state/publish_meta.
    private func exportFamilyBundle(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the family bundle folder"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let (_, db) = try ProjectStore.openProject(project.id)
            let destination = directory.appendingPathComponent(
                "\(project.name) Family Bundle", isDirectory: true)
            let summary = try FamilyBundleExporter.export(
                db: db,
                mediaSourceDirectory: ProjectStore.mediaDirectory(for: project.id),
                to: destination,
                now: Date()
            )
            if !summary.missingMediaPaths.isEmpty {
                bundleExportError = "Bundle exported, but \(summary.missingMediaPaths.count) media file(s) were missing on disk and were skipped."
            }
            NSWorkspace.shared.activateFileViewerSelecting([summary.bundleURL])
        } catch {
            bundleExportError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func activeContextMenu(_ project: Project) -> some View {
        Button {
            exportingProjectID = project.id
            pendingExportName = project.name
            showingExporter = true
        } label: {
            Label("Export as .ancestor archive…", systemImage: "archivebox")
        }
        Button {
            exportFamilyBundle(project)
        } label: {
            Label("Export Family Bundle…", systemImage: "person.2.crop.square.stack")
        }
        Button {
            publishTarget = project
        } label: {
            Label("Publish Tree to iCloud…", systemImage: "icloud.and.arrow.up")
        }
        Button {
            presentFamilySharing(project)
        } label: {
            Label("Family Sharing…", systemImage: "person.crop.circle.badge.plus")
        }
        .disabled(sharingBusy)
        Button {
            unpublishTarget = project
        } label: {
            Label("Unpublish Tree…", systemImage: "icloud.slash")
        }
        Button {
            appState.openProject(project)
            correctionsTargetProjectID = project.id
            presentImporter(.corrections)
        } label: {
            Label("Import GEDCOM as suggestions…", systemImage: "lightbulb")
        }
        Divider()
        Button(role: .destructive) {
            appState.archiveProject(project.id)
        } label: {
            Label("Archive", systemImage: "archivebox.fill")
        }
    }

    @ViewBuilder
    private func archivedContextMenu(_ project: Project) -> some View {
        Button {
            appState.unarchiveProject(project.id)
        } label: {
            Label("Unarchive", systemImage: "tray.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            pendingHardDelete = project
        } label: {
            Label("Delete permanently…", systemImage: "trash")
        }
    }

    private func handleExportResult(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            guard let id = exportingProjectID else { return }
            // The fileExporter creates an empty placeholder at the URL —
            // ProjectArchive.export removes and replaces it. Treat the
            // returned URL as the destination.
            appState.exportProjectArchive(projectID: id, to: url)
            exportingProjectID = nil
        case .failure(let error):
            // User cancellation surfaces as a CocoaError.userCancelled,
            // which we silently ignore.
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                appState.errorMessage = "Archive export failed: \(error.localizedDescription)"
            }
            exportingProjectID = nil
        }
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Sandboxed apps need a security-scoped resource handshake to
            // read user-picked files. Mirrors the GEDCOM import path.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            appState.importProjectArchive(from: url)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                appState.errorMessage = "Archive import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Handle GEDCOM imports targeted at an already-open project — produces
    /// hypotheses for overlapping profiles instead of overwriting them
    /// (M22 "Import corrections as suggestions").
    private func handleCorrectionsImportResult(_ result: Result<[URL], any Error>) {
        defer { correctionsTargetProjectID = nil }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            appState.importGEDCOMAsCorrections(from: url)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                appState.errorMessage = "Suggestions import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Handle GEDCOM (.ged) and GEDZip (.gdz) imports. Branches on the file
    /// extension since the two are structurally different — `.ged` is plain
    /// text we hand to `createAndImportProject`, `.gdz` is a zip container
    /// that goes through `importGEDZip`.
    private func handleGEDCOMImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            if ext == "gdz" {
                appState.importGEDZip(from: url)
            } else {
                // Treat anything else (.ged, no extension) as plain GEDCOM
                // text. Mirrors the existing NewProjectView path.
                let projectName = url.deletingPathExtension().lastPathComponent
                appState.createAndImportProject(
                    name: projectName.isEmpty ? "Imported GEDCOM" : projectName,
                    source: .gedcom(path: url.path)
                )
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                appState.errorMessage = "GEDCOM import failed: \(error.localizedDescription)"
            }
        }
    }
}

nonisolated extension DataSource {
    var description: String {
        switch self {
        case .gedcom(let path):
            "GEDCOM: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .wikitree(let email):
            "WikiTree: \(email)"
        case .manual:
            "Manual entry"
        }
    }
}

// MARK: - .ancestor file type + placeholder export document

nonisolated extension UTType {
    /// `.ancestor` archives are zip files with a custom extension. We
    /// register a child of `.zip` so Finder still recognises them as
    /// archives if the user wants to peek inside.
    static var ancestorArchive: UTType {
        UTType(exportedAs: "dev.dreamfold.ancestor-archive", conformingTo: .zip)
    }

    /// Plain GEDCOM (`.ged`) — UTF-8 text per spec.
    static var gedcomFile: UTType {
        UTType(filenameExtension: "ged") ?? .plainText
    }

    /// GEDZip container (`.gdz`) — zip file holding `gedcom.ged` + `media/`.
    static var gedZipFile: UTType {
        UTType(filenameExtension: "gdz") ?? .zip
    }
}

/// Placeholder FileDocument used to satisfy `.fileExporter`. The actual
/// archive bytes are written by `ProjectArchive.export` directly to the
/// chosen URL; `.fileExporter` insists on a document, but we override the
/// resulting file in `handleExportResult`.
nonisolated struct AncestorArchiveExportRequest: FileDocument {
    static var readableContentTypes: [UTType] { [.ancestorArchive, .zip] }
    static var writableContentTypes: [UTType] { [.ancestorArchive, .zip] }

    init() {}

    init(configuration: ReadConfiguration) throws {
        // Not actually used — fileExporter only writes.
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Empty placeholder — the real bytes are written post-export.
        FileWrapper(regularFileWithContents: Data())
    }
}
