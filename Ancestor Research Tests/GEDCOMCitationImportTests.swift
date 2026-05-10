import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for GEDCOM SOUR / PAGE / QUAY ingest (M16.1). The exporter's
/// SOUR/PAGE/QUAY blocks must round-trip back into `FieldSource.citation`
/// and `FieldSource.quality` so a tree exported and re-imported keeps
/// every formal citation intact — without this the audit engine flags
/// "missing citation" on every freshly imported tree.
struct GEDCOMCitationImportTests {

    // MARK: - Fixtures

    /// Minimal but realistic GEDCOM document with one SOUR + one INDI
    /// where BIRT references that source via `2 SOUR / 3 PAGE / 3 QUAY`.
    private static let citedSampleGEDCOM = """
0 HEAD
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @R1@ REPO
1 NAME General Register Office
0 @S1@ SOUR
1 ABBR FreeBMD Birth Index
1 TITL Birth Index 1834 Q1
1 PUBL General Register Office
1 REPO @R1@
0 @I1@ INDI
1 NAME Thomas /Land/
2 GIVN Thomas
2 SURN Land
1 SEX M
1 BIRT
2 DATE 25 JAN 1834
2 PLAC Belper, Derbyshire
2 SOUR @S1@
3 PAGE Volume 7b, page 213
3 QUAY 2
0 TRLR
"""

    private func makeCitedProfile(quality: EvidenceQuality = .primary) -> Profile {
        let citation = Citation(
            repository: "General Register Office",
            collection: "FreeBMD Birth Index",
            title: "Birth Index 1834 Q1",
            page: "Volume 7b, page 213",
            url: nil,
            dateAccessed: nil,
            notes: nil
        )
        let source = FieldSource(
            origin: .freebmd,
            raw: "freebmd",
            addedAt: Date(),
            citation: citation,
            quality: quality
        )
        return Profile(
            id: "@I1@",
            externalIDs: [:],
            firstName: "Thomas",
            lastName: "Land",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "25 JAN 1834"),
            birthLocation: "Belper, Derbyshire",
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [.birthDate: [source]],
            disputes: [:]
        )
    }

    // MARK: - Tests

    @Test func parserExtractsCitationFromSOURPAGEQUAY() {
        let result = GEDCOMParser.parse(content: Self.citedSampleGEDCOM)

        guard let profile = result.snapshot.profiles["@I1@"] else {
            Issue.record("Profile @I1@ not parsed")
            return
        }
        guard let birthSources = profile.sources[.birthDate], let source = birthSources.first else {
            Issue.record("Birth date field source missing")
            return
        }
        guard let citation = source.citation else {
            Issue.record("FieldSource.citation is nil — SOUR ingest failed")
            return
        }

        #expect(citation.title == "Birth Index 1834 Q1")
        #expect(citation.collection == "FreeBMD Birth Index")
        #expect(citation.repository == "General Register Office")
        #expect(citation.page == "Volume 7b, page 213")
        #expect(source.quality == .primary)
    }

    @Test func citationRoundTripPreservesAllFields() {
        let profile = makeCitedProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )

        let exported = GEDCOMExporter.export(snapshot)
        let parsed = GEDCOMParser.parse(content: exported.content)

        guard let imported = parsed.snapshot.profiles["@I1@"],
              let importedSources = imported.sources[.birthDate],
              let importedSource = importedSources.first,
              let importedCitation = importedSource.citation else {
            Issue.record("Round-trip lost the citation entirely")
            return
        }

        // Field-by-field equality of the citation itself.
        #expect(importedCitation.title == "Birth Index 1834 Q1")
        #expect(importedCitation.collection == "FreeBMD Birth Index")
        #expect(importedCitation.repository == "General Register Office")
        #expect(importedCitation.page == "Volume 7b, page 213")
        #expect(importedSource.quality == .primary)

        // Re-export — the citation lines (TITL/ABBR/PUBL/PAGE/QUAY) must
        // appear byte-for-byte the same as the first export.
        let reexported = GEDCOMExporter.export(parsed.snapshot).content
        #expect(reexported.contains("1 ABBR FreeBMD Birth Index"))
        #expect(reexported.contains("1 TITL Birth Index 1834 Q1"))
        #expect(reexported.contains("1 PUBL General Register Office"))
        #expect(reexported.contains("3 PAGE Volume 7b, page 213, FreeBMD Birth Index, General Register Office"))
        #expect(reexported.contains("3 QUAY 2"))
    }

    @Test func parserHandlesMultipleSOURReferencesPerField() {
        // BIRT has two `2 SOUR` refs with different QUAY values — the
        // higher-quality one wins.
        let ged = """
0 HEAD
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @S1@ SOUR
1 TITL Casual mention
0 @S2@ SOUR
1 TITL Original certificate
0 @I1@ INDI
1 NAME Thomas /Land/
1 BIRT
2 DATE 25 JAN 1834
2 SOUR @S1@
3 QUAY 1
2 SOUR @S2@
3 QUAY 3
0 TRLR
"""
        let result = GEDCOMParser.parse(content: ged)
        guard let profile = result.snapshot.profiles["@I1@"],
              let source = profile.sources[.birthDate]?.first else {
            Issue.record("Profile or birth source missing")
            return
        }
        #expect(source.quality == .direct)
        #expect(source.citation?.title == "Original certificate")
    }

    @Test func parserToleratesUnresolvedSOURReferences() {
        let ged = """
0 HEAD
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @I1@ INDI
1 NAME Thomas /Land/
1 BIRT
2 DATE 25 JAN 1834
2 SOUR @S99@
3 PAGE made up
3 QUAY 2
0 TRLR
"""
        let result = GEDCOMParser.parse(content: ged)

        // No crash, no citation attached, but a warning recorded.
        guard let profile = result.snapshot.profiles["@I1@"],
              let source = profile.sources[.birthDate]?.first else {
            Issue.record("Profile or birth source missing")
            return
        }
        #expect(source.citation == nil)
        #expect(result.warnings.contains(where: { $0.contains("@S99@") }))
    }

    @Test func parserExtractsEvidenceQualityFromQUAYTag() {
        // Each QUAY rawValue must round-trip to the corresponding
        // EvidenceQuality case. Build one cited birth per case and check.
        let cases: [(Int, EvidenceQuality)] = [
            (0, .unreliable),
            (1, .secondary),
            (2, .primary),
            (3, .direct),
        ]
        for (raw, expected) in cases {
            let ged = """
0 HEAD
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @S1@ SOUR
1 TITL Test
0 @I1@ INDI
1 NAME T /L/
1 BIRT
2 DATE 1834
2 SOUR @S1@
3 QUAY \(raw)
0 TRLR
"""
            let result = GEDCOMParser.parse(content: ged)
            let source = result.snapshot.profiles["@I1@"]?.sources[.birthDate]?.first
            #expect(source?.quality == expected, "QUAY \(raw) should map to \(expected)")
        }
    }
}
