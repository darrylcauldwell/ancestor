import SwiftUI

struct ProjectPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var showingNewProject = false

    var body: some View {
        VStack(spacing: 24) {
            Text(AppConstants.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)

            if appState.availableProjects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a new project to get started.")
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
                        Button("Delete", role: .destructive) {
                            appState.deleteProject(project.id)
                        }
                    }
                }
                .frame(maxWidth: 500, maxHeight: 300)
            }

            Button("New Project") {
                showingNewProject = true
            }
            .buttonStyle(.glassProminent)

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingNewProject) {
            NewProjectView()
        }
    }
}

extension DataSource {
    var description: String {
        switch self {
        case .gedcom(let path):
            "GEDCOM: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .wikitree(let email):
            "WikiTree: \(email)"
        }
    }
}
