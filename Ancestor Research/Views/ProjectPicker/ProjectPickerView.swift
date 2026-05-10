import SwiftUI
import UniformTypeIdentifiers

struct ProjectPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var showingNewProject = false

    // .ancestor archive export/import (M13)
    @State private var exportingProjectID: UUID?
    @State private var pendingExportName: String = "project"
    @State private var showingExporter = false
    @State private var showingImporter = false

    // GEDCOM/GEDZip import (M15)
    @State private var showingGEDCOMImporter = false

    // GEDCOM "Import as suggestions" — opens an existing project then
    // routes the picked file through `importGEDCOMAsCorrections` (M22).
    @State private var showingCorrectionsImporter = false
    @State private var correctionsTargetProjectID: UUID?

    var body: some View {
        VStack(spacing: 24) {
            Text(AppConstants.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)

            if appState.availableProjects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a new project, or tap **View Sample Tree** below to explore with fictional data.")
                }
            } else {
                List(appState.availableProjects) { project in
                    Button {
                        appState.openProject(project)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                    .font(.headline)
                                Text(project.source.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let date = project.lastRefreshed {
                                Text(date, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            exportingProjectID = project.id
                            pendingExportName = project.name
                            showingExporter = true
                        } label: {
                            Label("Export as .ancestor archive…", systemImage: "archivebox")
                        }
                        Button {
                            // Open the project then prompt for the GEDCOM
                            // file. The corrections path needs an active
                            // database; opening here keeps the picker as
                            // the single entry point.
                            appState.openProject(project)
                            correctionsTargetProjectID = project.id
                            showingCorrectionsImporter = true
                        } label: {
                            Label("Import GEDCOM as suggestions…", systemImage: "lightbulb")
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteProject(project.id)
                        }
                    }
                }
                .frame(maxWidth: 500, maxHeight: 300)
            }

            HStack(spacing: 12) {
                Button("New Project") {
                    showingNewProject = true
                }
                .buttonStyle(.glassProminent)

                Button {
                    showingImporter = true
                } label: {
                    Label("Import .ancestor…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.glass)
                .help("Import a .ancestor archive previously exported from this app")
                .accessibilityHint("Import a .ancestor archive previously exported from this app")

                Button {
                    showingGEDCOMImporter = true
                } label: {
                    Label("Import GEDCOM (.ged or .gdz)…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .help("Import a GEDCOM file or GEDZip container into a new project")
                .accessibilityHint("Import a GEDCOM file or GEDZip container into a new project")

                // Reviewer- and first-user-friendly entry: opens (or creates)
                // the bundled "Sample Family" project so every feature is
                // reachable without a GEDCOM file or WikiTree account.
                Button {
                    appState.openSampleProject()
                } label: {
                    Label("View Sample Tree", systemImage: "tree")
                }
                .buttonStyle(.glass)
                .help("Open a fictional 30-profile family for exploring the app's features")
                .accessibilityHint("Open a fictional 30-profile family for exploring the app's features")
            }

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
        .background(.ultraThinMaterial)
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
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.ancestorArchive, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .fileImporter(
            isPresented: $showingGEDCOMImporter,
            allowedContentTypes: [.gedcomFile, .gedZipFile, .data],
            allowsMultipleSelection: false
        ) { result in
            handleGEDCOMImportResult(result)
        }
        .fileImporter(
            isPresented: $showingCorrectionsImporter,
            allowedContentTypes: [.gedcomFile, .data],
            allowsMultipleSelection: false
        ) { result in
            handleCorrectionsImportResult(result)
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
