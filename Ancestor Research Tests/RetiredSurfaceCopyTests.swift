import Testing
import Foundation

/// SC-consolidation follow-ups (review M8 + M9) — the surface consolidation
/// (3356bbb) retired the Research and Triage tabs and the Possible People
/// panel, but left live UI copy pointing at them, and an empty "Semantic
/// clustering" Section shell in Settings.
///
/// Views aren't unit-tested here (project convention), so these guards scan
/// the view SOURCE for the exact stale phrases that shipped — the same
/// #filePath-anchored repo access `AuditEngineTests.auditRealGEDCOM` uses.
/// Each phrase below existed verbatim in the named file before the fix, only
/// ever inside a user-facing string literal (or, for M8, the orphaned Section
/// header), so its reappearance means a retired surface is being named to the
/// user again.
struct RetiredSurfaceCopyTests {

    private func source(_ repoRelativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(repoRelativePath), encoding: .utf8)
    }

    /// M9 — the run-complete footer told the user to "review in Triage", and
    /// the mid-run copy sent them to "the Research tab"; both surfaces are
    /// gone (review happens in the detached record-review window / on the
    /// profile card).
    @Test func progressSheetNoLongerPointsAtRetiredTabs() throws {
        let text = try source("Ancestor Research/Views/Research/ResearchProgressSheet.swift")
        #expect(!text.contains("review in Triage"),
                "the narrowing-proposal label must not send the user to the retired Triage tab")
        #expect(!text.contains("check progress on the Research tab"),
                "the background-run copy must not send the user to the retired Research tab")
    }

    /// M9 — the Tasks leads banner's button said "Open Triage" while its
    /// handler (ContentView.openTriage) routes to the Workbench.
    @Test func tasksLeadsBannerNamesWhereItActuallyGoes() throws {
        let text = try source("Ancestor Research/Views/Tasks/UnifiedTasksView.swift")
        #expect(!text.contains("\"Open Triage\""),
                "the leads-banner button must name the Workbench it routes to, not the retired Triage tab")
    }

    /// M9 — the Getting Started flow paragraph still walked the retired
    /// Research → Triage tabs (bold-faced, so **Triage** only ever appeared
    /// in the user-facing markdown string).
    @Test func gettingStartedFlowDescribesTheCurrentSurfaces() throws {
        let text = try source("Ancestor Research/Views/ManualEntry/GettingStartedView.swift")
        #expect(!text.contains("**Triage**"),
                "the flow paragraph must not present Triage as a current surface")
        #expect(!text.contains("**Research**"),
                "the flow paragraph must not present the Research tab as a current surface")
    }

    /// M8 — Settings rendered a bare "Semantic clustering" heading with
    /// nothing under it: the Section shell survived the embedder-UI deletion.
    @Test func settingsCarriesNoOrphanedSemanticClusteringSection() throws {
        let text = try source("Ancestor Research/Views/Settings/SettingsPlaceholderView.swift")
        #expect(!text.contains("Section(\"Semantic clustering\")"),
                "the empty Section shell left by the embedder-UI removal must stay gone")
    }
}
