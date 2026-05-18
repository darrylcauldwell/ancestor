import SwiftUI

/// "New Project" sheet — the named-creation dialog reachable from the welcome
/// screen's "+ New Project" button.
///
/// **Scope deliberately narrow.** GEDCOM file import, .ancestor archive import,
/// and the Sample Tree each have their own welcome-screen entry points (and
/// drag-and-drop) — they previously also appeared as data-source tabs in this
/// sheet, which created two parallel paths to the same outcome. Those tabs
/// were removed so the sheet now handles only the cases the welcome buttons
/// can't express:
///   • WikiTree API — credentials needed, low-traffic, doesn't merit a
///     top-level welcome button
///   • Start From Scratch — a named blank project, optionally followed by the
///     onboarding wizard
struct NewProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var sourceType: SourceType = .manual
    @State private var wikiTreeEmail = ""
    @State private var wikiTreePassword = ""
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
                Text("Start From Scratch").tag(SourceType.manual)
                Text("WikiTree API").tag(SourceType.wikitree)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            switch sourceType {
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
                Text("Have a GEDCOM file? Cancel and use **Import GEDCOM…** on the welcome screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
    }

    private var canCreate: Bool {
        guard !projectName.isEmpty else { return false }
        switch sourceType {
        case .wikitree:
            return !wikiTreeEmail.isEmpty && !wikiTreePassword.isEmpty
        case .manual:
            return true
        }
    }

    private func createProject() {
        switch sourceType {
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
    case wikitree, manual
}
