import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Headless project creation from a GEDCOM — env-gated TOOL, not a test.
/// Mirrors `AppState.importGEDCOM`'s exact flow (parse → empty-target
/// guard → importSnapshot → post-import conflict sweep → meta refresh)
/// through the app's own code paths, never raw SQL. The created project
/// appears in the app's picker on next launch (directory-scan discovery).
///
///   env TEST_RUNNER_RUN_GEDCOM_PROJECT_CREATE=1 \
///       TEST_RUNNER_GEDCOM_FILENAME=<name in Application Support/AncestorResearch/import-inbox/> \
///       TEST_RUNNER_GEDCOM_PROJECT_NAME="<project name>" \
///   xcodebuild test … -only-testing:"Ancestor Research Tests/GEDCOMProjectCreationTool"
///
/// The GEDCOM must be staged into the app container's `import-inbox/`
/// first — the test host runs inside the app sandbox and cannot read
/// ~/Downloads.
@MainActor
struct GEDCOMProjectCreationTool {

    @Test func createProjectFromStagedGEDCOM() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_GEDCOM_PROJECT_CREATE"] == "1" else { return }
        let filename = env["GEDCOM_FILENAME"] ?? ""
        let projectName = env["GEDCOM_PROJECT_NAME"] ?? "Imported GEDCOM"
        guard !filename.isEmpty else {
            Issue.record("GEDCOM_FILENAME not provided")
            return
        }

        let inbox = ProjectStore.projectsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("import-inbox", isDirectory: true)
        let gedcomURL = inbox.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: gedcomURL.path) else {
            Issue.record("staged GEDCOM not found at \(gedcomURL.path)")
            return
        }

        // Parse first — a malformed file must fail before any project
        // file is created.
        let parseResult = try GEDCOMParser.parse(fileAt: gedcomURL.path)
        print("TOOL: parsed \(parseResult.individualCount) individuals from \(filename)")
        #expect(parseResult.individualCount > 0)

        let (project, db) = try ProjectStore.createProject(
            name: projectName,
            source: .gedcom(path: gedcomURL.path))

        // Mirror AppState.importGEDCOM: empty-target guard, transactional
        // import, post-import sweep (CL2 T-C trigger — latent
        // contradictions surface immediately).
        let existing = (try? db.buildSnapshot().profiles.count) ?? 0
        #expect(existing == 0)
        _ = try db.importSnapshot(parseResult.snapshot, source: gedcomURL.path)
        let snapshot = try db.buildSnapshot()
        let sweep = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        // Meta refresh (the app records lastRefreshed after import).
        let refreshed = Project(
            id: project.id, name: project.name, source: project.source,
            homePersonID: project.homePersonID, createdAt: project.createdAt,
            lastRefreshed: Date())
        try db.saveProjectMeta(refreshed)

        print("TOOL: project '\(projectName)' created — id \(project.id.uuidString)")
        print("TOOL: profiles=\(snapshot.profiles.count) relationships=\(snapshot.relationships.count)")
        print("TOOL: post-import sweep touched \(sweep.disputesTouched) dispute(s) across \(sweep.profilesScanned) profiles")
        #expect(snapshot.profiles.count == parseResult.individualCount)
    }
}
