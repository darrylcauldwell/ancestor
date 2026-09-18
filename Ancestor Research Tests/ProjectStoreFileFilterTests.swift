import Testing
import Foundation
@testable import Ancestor_Research

/// `ProjectStore.listProjects` opens every file it selects with
/// `ProjectDatabase.init`, which MIGRATES. The publisher's shared store and
/// sqlite-data's metadatabase sidecar live in the same directory, so a
/// too-broad `*.sqlite` filter wrote the project schema into both — and the
/// next publish died on sqlite-data's `hasSchemaChanges` assertion.
struct ProjectStoreFileFilterTests {
    private func url(_ name: String) -> URL {
        ProjectStore.projectsDirectory.appendingPathComponent(name)
    }

    @Test func projectFilesAreSelected() {
        #expect(ProjectStore.isProjectFile(url("11DA1253-26C6-4F3A-A34A-59FAD844D770.sqlite")))
    }

    @Test func publishedStoreIsNotAProject() {
        #expect(!ProjectStore.isProjectFile(PublishedStore.sharedURL))
    }

    @Test func metadatabaseSidecarIsNotAProject() {
        #expect(!ProjectStore.isProjectFile(
            url(".published.metadata-iCloud.dev.dreamfold.Ancestor-Research.sqlite")))
    }

    @Test func nonSQLiteFilesAreNotProjects() {
        #expect(!ProjectStore.isProjectFile(url("published.sqlite-wal")))
        #expect(!ProjectStore.isProjectFile(url("notes.json")))
    }
}
