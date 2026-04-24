import SwiftUI

/// Root application state — tracks current project and snapshot.
@MainActor @Observable
final class AppState {
    var currentProject: Project?
    var currentDatabase: ProjectDatabase?
    var snapshot: FamilyGraphSnapshot = .empty
    var availableProjects: [Project] = []
    var isLoading = false
    var loadingMessage: String?
    var errorMessage: String?

    init() {
        refreshProjectList()
    }

    func refreshProjectList() {
        availableProjects = ProjectStore.listProjects()
    }

    func openProject(_ project: Project) {
        isLoading = true
        loadingMessage = "Opening project..."
        errorMessage = nil
        do {
            let (proj, db) = try ProjectStore.openProject(project.id)
            currentProject = proj
            currentDatabase = db
            snapshot = try db.buildSnapshot()
        } catch {
            errorMessage = "Failed to open project: \(error.localizedDescription)"
        }
        isLoading = false
        loadingMessage = nil
    }

    /// Create a new project and immediately import data from its source.
    func createAndImportProject(name: String, source: DataSource) {
        isLoading = true
        errorMessage = nil

        do {
            let (project, db) = try ProjectStore.createProject(name: name, source: source)
            currentProject = project
            currentDatabase = db

            switch source {
            case .gedcom(let path):
                try importGEDCOM(path: path, db: db)
            case .wikitree:
                // WikiTree credentials are entered separately in Settings
                // For now, create the project — user connects via Settings
                snapshot = .empty
            }

            refreshProjectList()
        } catch {
            errorMessage = "Failed to create project: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Import a GEDCOM file into the current database.
    private func importGEDCOM(path: String, db: ProjectDatabase) throws {
        loadingMessage = "Parsing GEDCOM file..."
        let parseResult = try GEDCOMParser.parse(fileAt: path)

        loadingMessage = "Saving \(parseResult.individualCount) profiles..."
        let transaction = try db.importSnapshot(parseResult.snapshot, source: path)

        loadingMessage = "Building tree..."
        snapshot = try db.buildSnapshot()

        // Update project metadata with refresh time
        if var project = currentProject {
            project = Project(
                id: project.id,
                name: project.name,
                source: project.source,
                createdAt: project.createdAt,
                lastRefreshed: transaction.completedAt
            )
            try db.saveProjectMeta(project)
            currentProject = project
        }

        if !parseResult.warnings.isEmpty {
            print("GEDCOM import warnings:")
            for warning in parseResult.warnings {
                print("  \(warning)")
            }
        }
    }

    func deleteProject(_ id: UUID) {
        do {
            try ProjectStore.deleteProject(id)
            if currentProject?.id == id {
                currentProject = nil
                currentDatabase = nil
                snapshot = .empty
            }
            refreshProjectList()
        } catch {
            errorMessage = "Failed to delete project: \(error.localizedDescription)"
        }
    }

    func closeProject() {
        currentProject = nil
        currentDatabase = nil
        snapshot = .empty
    }

    // MARK: - WikiTree

    private var wikiTreeClient = WikiTreeClient()

    /// Connect to WikiTree and fetch all watchlist profiles.
    func connectWikiTree(email: String, password: String) async {
        isLoading = true
        loadingMessage = "Logging in to WikiTree..."
        errorMessage = nil

        do {
            let user = try await wikiTreeClient.login(email: email, password: password)

            let (profiles, relationships) = try await wikiTreeClient.fetchWatchlistTree { message in
                Task { @MainActor in
                    self.loadingMessage = message
                }
            }

            let profileDict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let importSnapshot = FamilyGraphSnapshot(profiles: profileDict, relationships: relationships)

            guard let db = currentDatabase else { return }
            loadingMessage = "Saving \(profiles.count) profiles..."
            let transaction = try db.importSnapshot(importSnapshot, source: "wikitree://\(user.name)")

            snapshot = try db.buildSnapshot()

            if var project = currentProject {
                project = Project(
                    id: project.id, name: project.name, source: project.source,
                    createdAt: project.createdAt, lastRefreshed: transaction.completedAt
                )
                try db.saveProjectMeta(project)
                currentProject = project
            }
        } catch {
            errorMessage = "WikiTree error: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Refresh from WikiTree — superseded by refreshWikiTreeWithDiff().
    /// Kept as a direct refresh for cases where diff is not needed.
    func refreshWikiTree() async {
        await refreshWikiTreeWithDiff()
    }

    // MARK: - Refresh with Diff

    /// Pending diff waiting for user to accept or reject.
    var pendingDiff: DiffEngine.DiffResult?
    var pendingSnapshot: FamilyGraphSnapshot?

    /// Refresh from WikiTree — fetch new data and show diff before committing.
    func refreshWikiTreeWithDiff() async {
        guard case .wikitree = currentProject?.source else { return }
        isLoading = true
        loadingMessage = "Refreshing from WikiTree..."
        errorMessage = nil

        do {
            let (profiles, relationships) = try await wikiTreeClient.fetchWatchlistTree { message in
                Task { @MainActor in
                    self.loadingMessage = message
                }
            }

            let profileDict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let newSnapshot = FamilyGraphSnapshot(profiles: profileDict, relationships: relationships)

            // Compute diff
            let diff = DiffEngine.diff(old: snapshot, new: newSnapshot)

            if diff.isEmpty {
                // No changes — nothing to do
                loadingMessage = nil
                isLoading = false
                return
            }

            // Store pending diff for user review
            pendingDiff = diff
            pendingSnapshot = newSnapshot
        } catch {
            errorMessage = "Refresh error: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Accept the pending diff and commit changes.
    func acceptPendingDiff() {
        guard let newSnapshot = pendingSnapshot else { return }
        snapshot = newSnapshot

        if var project = currentProject {
            project = Project(
                id: project.id, name: project.name, source: project.source,
                createdAt: project.createdAt, lastRefreshed: Date()
            )
            try? currentDatabase?.saveProjectMeta(project)
            currentProject = project
        }

        pendingDiff = nil
        pendingSnapshot = nil
    }

    /// Reject the pending diff — keep current data.
    func rejectPendingDiff() {
        pendingDiff = nil
        pendingSnapshot = nil
    }

    // MARK: - Undo

    /// Undo the most recent transaction.
    func undoLastTransaction() {
        guard let db = currentDatabase else { return }

        do {
            let transactions = try db.loadTransactions(limit: 1)
            guard let latest = transactions.first else {
                errorMessage = "Nothing to undo."
                return
            }

            switch latest.undoStrategy {
            case .structural:
                // Delete all entities created by this transaction
                try db.undoStructural(transactionID: latest.id)
            case .replay:
                // Reverse each FieldChange
                try db.undoReplay(transactionID: latest.id)
            }

            // Record the undo as its own transaction
            let undoTx = Transaction(
                id: UUID(),
                kind: .undo(ofTransactionID: latest.id),
                undoStrategy: .replay,
                startedAt: Date(),
                completedAt: Date(),
                changeCount: latest.changeCount,
                profileCount: latest.profileCount
            )
            try db.saveTransaction(undoTx)

            // Rebuild snapshot
            snapshot = try db.buildSnapshot()
        } catch {
            errorMessage = "Undo failed: \(error.localizedDescription)"
        }
    }

    /// Export current project to GEDCOM file.
    func exportGEDCOM(to path: String) {
        guard !snapshot.profiles.isEmpty else {
            errorMessage = "No data to export."
            return
        }
        do {
            let result = try GEDCOMExporter.export(snapshot, to: path)
            if !result.dropped.isEmpty {
                print("GEDCOM export — dropped data:")
                for item in result.dropped {
                    print("  \(item)")
                }
            }
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
