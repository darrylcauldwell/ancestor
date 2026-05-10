import Testing
import Foundation
@testable import Ancestor_Research

/// M16.13 — `GEDCOMExporter.ExportResult.dropped` must enumerate every
/// category of workbench-only data the caller is excluding from the
/// export, in addition to the per-profile dispute / extra-source entries
/// the exporter has always produced. Without these the post-export sheet
/// gives users a false sense that nothing was lost.
struct GEDCOMDroppedSummaryTests {

    // MARK: - Fixtures

    private func makeProfile() -> Profile {
        Profile(
            id: "@I1@",
            externalIDs: [:],
            firstName: "Test",
            lastName: "Person",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1834"),
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    // MARK: - Tests

    @Test func exporterEnumeratesHypothesesInDroppedWhenSummaryProvided() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let summary = WorkbenchExportSummary(
            hypothesisCount: 3,
            focusSetCount: 2,
            transactionCount: 17,
            workbenchNoteCount: 5
        )

        let result = GEDCOMExporter.export(snapshot, workbenchSummary: summary)

        #expect(result.dropped.contains(where: { $0.contains("3 hypotheses") }))
        #expect(result.dropped.contains(where: { $0.contains("2 focus sets") }))
        #expect(result.dropped.contains(where: { $0.contains("17 transactions") }))
        #expect(result.dropped.contains(where: { $0.contains("5 workbench notes") }))
    }

    @Test func exporterDoesNotMentionEmptyCategories() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        // Only hypotheses are non-zero; the other three categories must
        // not appear in the dropped log at all.
        let summary = WorkbenchExportSummary(
            hypothesisCount: 1,
            focusSetCount: 0,
            transactionCount: 0,
            workbenchNoteCount: 0
        )

        let result = GEDCOMExporter.export(snapshot, workbenchSummary: summary)

        #expect(result.dropped.contains(where: { $0.contains("1 hypotheses") }))
        #expect(!result.dropped.contains(where: { $0.contains("focus sets") }))
        #expect(!result.dropped.contains(where: { $0.contains("transactions") }))
        #expect(!result.dropped.contains(where: { $0.contains("workbench notes") }))
    }

    @Test func exporterPreservesExistingDroppedEntries() {
        // A profile with an extra source on the birthDate field — the
        // exporter should still emit "Dropped N additional source(s)..."
        // alongside the workbench summary entries.
        let extraSourceA = FieldSource(
            origin: .gedcom, raw: "first", addedAt: Date()
        )
        let extraSourceB = FieldSource(
            origin: .freebmd, raw: "second", addedAt: Date()
        )
        let profile = Profile(
            id: "@I1@",
            externalIDs: [:],
            firstName: "Test",
            lastName: "Person",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1834"),
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [.birthDate: [extraSourceA, extraSourceB]],
            disputes: [:]
        )
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let summary = WorkbenchExportSummary(hypothesisCount: 4)

        let result = GEDCOMExporter.export(snapshot, workbenchSummary: summary)

        #expect(result.dropped.contains(where: { $0.contains("additional source") }))
        #expect(result.dropped.contains(where: { $0.contains("4 hypotheses") }))
    }

    @Test func exporterOmitsWorkbenchSectionWhenSummaryIsNil() {
        // Callers that don't supply a summary must see the legacy
        // dropped[] (just per-profile dispute/extra-source entries).
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )

        let result = GEDCOMExporter.export(snapshot)
        #expect(!result.dropped.contains(where: { $0.contains("hypotheses") }))
        #expect(!result.dropped.contains(where: { $0.contains("focus sets") }))
    }
}
