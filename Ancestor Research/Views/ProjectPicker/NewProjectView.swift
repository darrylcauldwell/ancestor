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
                }
            case .wikitree:
                VStack(spacing: 12) {
                    TextField("WikiTree Email", text: $wikiTreeEmail)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    SecureField("WikiTree Password", text: $wikiTreePassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createProject() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
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
        }
    }

    private func createProject() {
        switch sourceType {
        case .gedcom:
            guard let file = selectedFile else { return }
            appState.createAndImportProject(name: projectName, source: .gedcom(path: file.path))
        case .wikitree:
            appState.createAndImportProject(name: projectName, source: .wikitree(email: wikiTreeEmail))
            // Immediately connect and pull watchlist
            Task {
                await appState.connectWikiTree(
                    email: wikiTreeEmail,
                    password: wikiTreePassword
                )
            }
        }
        dismiss()
    }
}

private enum SourceType {
    case gedcom, wikitree
}
