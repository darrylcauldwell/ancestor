import UniformTypeIdentifiers
import SwiftUI

struct NewProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var sourceType: SourceType = .gedcom
    @State private var wikiTreeEmail = ""
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
                TextField("WikiTree Email", text: $wikiTreeEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(30)
        .frame(minWidth: 450, minHeight: 250)
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
        !projectName.isEmpty && (sourceType == .wikitree ? !wikiTreeEmail.isEmpty : selectedFile != nil)
    }

    private func createProject() {
        let source: DataSource
        switch sourceType {
        case .gedcom:
            guard let file = selectedFile else { return }
            source = .gedcom(path: file.path)
        case .wikitree:
            source = .wikitree(email: wikiTreeEmail)
        }
        appState.createAndImportProject(name: projectName, source: source)
        dismiss()
    }
}

private enum SourceType {
    case gedcom, wikitree
}
