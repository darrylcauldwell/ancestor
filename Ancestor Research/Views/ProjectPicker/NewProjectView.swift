import UniformTypeIdentifiers
import SwiftUI

struct NewProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var sourceType: SourceType = .gedcom
    @State private var wikiTreeEmail = ""
    @State private var wikiTreePassword = ""
    @State private var selectedFile: URL?
    @State private var showingFilePicker = false
    /// In-flight validation for the WikiTree credentials. Setting this true
    /// disables the Create button and swaps it for "Logging in…" so the user
    /// can't double-click while the credential check is running.
    @State private var isValidatingWikiTree = false
    /// Inline error from a failed WikiTree pre-validation. Lives inside the
    /// sheet so a bad password doesn't leave behind a half-created project
    /// (Task #56) — the sheet stays open and the user can correct the
    /// password without navigating to Settings.
    @State private var wikiTreeError: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("New Project")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Project Name", text: $projectName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            Picker("Data Source", selection: $sourceType) {
                Text("GEDCOM File").tag(SourceType.gedcom)
                Text("WikiTree API").tag(SourceType.wikitree)
                Text("Start From Scratch").tag(SourceType.manual)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            switch sourceType {
            case .gedcom:
                VStack(spacing: 8) {
                    if let file = selectedFile {
                        Label(file.lastPathComponent, systemImage: "doc.fill")
                    }
                    Button("Choose GEDCOM File...") {
                        showingFilePicker = true
                    }
                    Text("Or use the bundled sample — generated from a fictional 30-profile family.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Button {
                        useSampleGEDCOM()
                    } label: {
                        Label("Use Sample GEDCOM", systemImage: "doc.text")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            case .wikitree:
                VStack(spacing: 12) {
                    TextField("WikiTree Email", text: $wikiTreeEmail)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    SecureField("WikiTree Password", text: $wikiTreePassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    if let error = wikiTreeError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                }
            case .manual:
                Text("We'll guide you through entering yourself, your parents, and your grandparents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(isValidatingWikiTree ? "Logging in…" : "Create") { createProject() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isValidatingWikiTree)
            }
        }
        .padding(30)
        .frame(minWidth: 450, minHeight: 300)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.init(filenameExtension: "ged")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedFile = url
                if projectName.isEmpty {
                    projectName = url.deletingPathExtension().lastPathComponent
                }
            }
        }
    }

    private var canCreate: Bool {
        guard !projectName.isEmpty else { return false }
        switch sourceType {
        case .gedcom:
            return selectedFile != nil
        case .wikitree:
            return !wikiTreeEmail.isEmpty && !wikiTreePassword.isEmpty
        case .manual:
            return true
        }
    }

    /// Generate a sample GEDCOM from the demo data and feed it through the
    /// normal GEDCOM-import path. Reviewer-friendly entry that exercises the
    /// import code without requiring a hosted external file. The file is
    /// written to a temp directory; existing project name (or "Sample GEDCOM"
    /// fallback) is used.
    private func useSampleGEDCOM() {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("sample-\(UUID().uuidString).ged")

        let (profiles, relationships) = DemoDataGenerator.generate()
        let demoSnapshot = FamilyGraphSnapshot(profiles: profiles, relationships: relationships)
        do {
            _ = try GEDCOMExporter.export(demoSnapshot, to: tmpFile.path)
        } catch {
            appState.errorMessage = "Failed to write sample GEDCOM: \(error.localizedDescription)"
            return
        }

        let name = projectName.isEmpty ? "Sample GEDCOM" : projectName
        appState.createAndImportProject(name: name, source: .gedcom(path: tmpFile.path))
        dismiss()
    }

    private func createProject() {
        switch sourceType {
        case .gedcom:
            guard let file = selectedFile else { return }
            guard file.startAccessingSecurityScopedResource() else {
                appState.errorMessage = "Permission denied — could not access the selected file."
                return
            }
            defer { file.stopAccessingSecurityScopedResource() }
            appState.createAndImportProject(name: projectName, source: .gedcom(path: file.path))
            dismiss()
        case .wikitree:
            // Validate credentials FIRST. Only on success do we create the
            // project file and start the import — a bad password no longer
            // leaves behind an empty SQLite shell the user has no UI path
            // back to (Task #56).
            wikiTreeError = nil
            isValidatingWikiTree = true
            Task {
                do {
                    try await appState.validateWikiTreeLogin(
                        email: wikiTreeEmail,
                        password: wikiTreePassword
                    )
                } catch {
                    isValidatingWikiTree = false
                    wikiTreeError = "Login failed: \(error.localizedDescription)"
                    return
                }
                // Login succeeded; proceed with project creation + import.
                appState.createAndImportProject(name: projectName, source: .wikitree(email: wikiTreeEmail))
                isValidatingWikiTree = false
                dismiss()
                await appState.connectWikiTree(
                    email: wikiTreeEmail,
                    password: wikiTreePassword
                )
            }
        case .manual:
            appState.createAndImportProject(name: projectName, source: .manual)
            appState.showOnboardingWizard = true
            dismiss()
        }
    }
}

private enum SourceType {
    case gedcom, wikitree, manual
}
