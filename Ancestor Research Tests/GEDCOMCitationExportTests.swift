import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for GEDCOM SOUR / PAGE / QUAY emission. Per DESIGN.md §5.12 a
/// `Citation` carried by a `FieldSource` should round-trip into standard
/// GEDCOM citation tags so other genealogy tools can verify each fact.
struct GEDCOMCitationExportTests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String,
        firstName: String? = "Test",
        lastName: String? = "Person",
        gender: Gender? = .male,
        birthDate: String? = nil,
        birthLocation: String? = nil,
        deathDate: String? = nil,
        deathLocation: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: gender,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    /// Helper: split GEDCOM content into lines so tests can match by index.
    private func lines(_ result: GEDCOMExporter.ExportResult) -> [String] {
        result.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Tests

    @Test func citationOnBirthFieldRendersSourPageAndQuay() {
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
            raw: "freebmd-birth-1834",
            addedAt: Date(),
            citation: citation,
            quality: .primary
        )
        let profile = makeProfile(
            id: "@I1@",
            firstName: "Thomas",
            lastName: "Land",
            birthDate: "25 JAN 1834",
            birthLocation: "Belper, Derbyshire",
            sources: [.birthDate: [source]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        #expect(out.contains("0 @S1@ SOUR"))
        // Inline ref under the BIRT event — level 2 (child of event).
        #expect(out.contains("2 SOUR @S1@"))
        // PAGE combines page + collection + repository
        #expect(out.contains("3 PAGE Volume 7b, page 213, FreeBMD Birth Index, General Register Office"))
        // QUAY uses EvidenceQuality rawValue (.primary = 2)
        #expect(out.contains("3 QUAY 2"))
        // Title preserved on the SOUR record
        #expect(out.contains("1 TITL Birth Index 1834 Q1"))
        // Repository surfaces as PUBL
        #expect(out.contains("1 PUBL General Register Office"))
    }

    @Test func twoProfilesSharingCitationProduceOneSourRecord() {
        let citation = Citation(
            repository: "TNA",
            collection: "1851 Census of England and Wales",
            title: nil,
            page: "HO107/2147",
            url: nil,
            dateAccessed: nil,
            notes: nil
        )
        let source1 = FieldSource(
            origin: .freecen, raw: "1851", addedAt: Date(),
            citation: citation, quality: .primary
        )
        let source2 = FieldSource(
            origin: .freecen, raw: "1851", addedAt: Date(),
            citation: citation, quality: .primary
        )

        let p1 = makeProfile(
            id: "@I1@", firstName: "Thomas", birthDate: "1834",
            sources: [.birthDate: [source1]]
        )
        let p2 = makeProfile(
            id: "@I2@", firstName: "Mary", gender: .female, birthDate: "1840",
            sources: [.birthDate: [source2]]
        )
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@I1@": p1, "@I2@": p2],
            relationships: []
        )

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        // Exactly one `0 @S1@ SOUR` line.
        let occurrences = out.components(separatedBy: "0 @S1@ SOUR").count - 1
        #expect(occurrences == 1, "Expected exactly one SOUR record, got \(occurrences)")

        // No second SOUR record allocated.
        #expect(!out.contains("0 @S2@ SOUR"))

        // Both individuals reference @S1@ inline.
        let inlineRefs = out.components(separatedBy: "2 SOUR @S1@").count - 1
        #expect(inlineRefs == 2)
    }

    @Test func fieldSourceWithoutCitationEmitsNoSourLine() {
        let bareSource = FieldSource(
            origin: .gedcom,
            raw: "imported.ged",
            addedAt: Date(),
            citation: nil,
            quality: nil
        )
        let profile = makeProfile(
            id: "@I1@",
            firstName: "Anonymous",
            birthDate: "1900",
            sources: [.birthDate: [bareSource]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        // No SOUR records emitted at all.
        #expect(!out.contains("0 @S1@ SOUR"))
        // No inline ref under BIRT.
        #expect(!out.contains("2 SOUR @S"))
    }

    @Test func evidenceQualityPrimaryRendersAsQuayTwo() {
        // Each EvidenceQuality must round-trip to its rawValue for QUAY.
        let cases: [(EvidenceQuality, String)] = [
            (.unreliable, "3 QUAY 0"),
            (.secondary, "3 QUAY 1"),
            (.primary, "3 QUAY 2"),
            (.direct, "3 QUAY 3"),
        ]

        for (quality, expected) in cases {
            let citation = Citation(
                repository: nil, collection: "Test Collection",
                title: nil, page: "p1", url: nil,
                dateAccessed: nil, notes: nil
            )
            let source = FieldSource(
                origin: .manual, raw: "manual",
                addedAt: Date(),
                citation: citation, quality: quality
            )
            let profile = makeProfile(
                id: "@I1@", birthDate: "1900",
                sources: [.birthDate: [source]]
            )
            let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

            let result = GEDCOMExporter.export(snapshot)
            #expect(result.content.contains(expected),
                    "Expected '\(expected)' for quality \(quality)")
        }
    }

    @Test func urlOnlyCitationStillEmitsSourRecord() {
        // When all locator fields are absent but a URL is present, the URL
        // becomes the PAGE locator and is also recorded via the `_URL` tag
        // on the SOUR record. This keeps the citation discoverable in
        // viewers that don't recognise `_URL`.
        let citation = Citation(
            repository: nil, collection: nil, title: nil,
            page: nil,
            url: "https://www.freebmd.org.uk/cgi/information.pl?cite=ABC123",
            dateAccessed: nil,
            notes: nil
        )
        let source = FieldSource(
            origin: .freebmd, raw: "freebmd",
            addedAt: Date(),
            citation: citation, quality: .secondary
        )
        let profile = makeProfile(
            id: "@I1@", birthDate: "1834",
            sources: [.birthDate: [source]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        #expect(out.contains("0 @S1@ SOUR"))
        // PAGE falls back to the URL when no other locator is set.
        #expect(out.contains("3 PAGE https://www.freebmd.org.uk/cgi/information.pl?cite=ABC123"))
        // _URL tag also present on the SOUR record (custom GEDCOM extension).
        #expect(out.contains("1 _URL https://www.freebmd.org.uk/cgi/information.pl?cite=ABC123"))
        #expect(out.contains("3 QUAY 1"))
    }

    @Test func emptyDefaultCitationIsSkipped() {
        // An empty `Citation()` (all nil) carried on a FieldSource must not
        // produce a SOUR record — `Citation.isEmpty` is the gate.
        let citation = Citation()
        #expect(citation.isEmpty)

        let source = FieldSource(
            origin: .manual, raw: "manual",
            addedAt: Date(),
            citation: citation,
            quality: .unreliable
        )
        let profile = makeProfile(
            id: "@I1@", birthDate: "1900",
            sources: [.birthDate: [source]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        // No SOUR records — empty citation is treated as "no citation".
        #expect(!out.contains("0 @S1@ SOUR"))
        // No inline `2 SOUR @S` reference under the event either.
        #expect(!out.contains("2 SOUR @S"))
        // Even though quality was set, QUAY only ships when a citation does.
        #expect(!out.contains("3 QUAY"))
    }

    @Test func notesAndUrlAndDateAccessedRenderOnSourRecord() {
        let dateAccessed = ISO8601DateFormatter().date(from: "2026-04-25T00:00:00Z")
        let citation = Citation(
            repository: "Derbyshire Record Office",
            collection: "Belper Parish Registers",
            title: "Baptisms 1830-1840",
            page: "page 47",
            url: "https://example.org/belper",
            dateAccessed: dateAccessed,
            notes: "Entry partially illegible — '34' or '36' unclear."
        )
        let source = FieldSource(
            origin: .freereg, raw: "freereg",
            addedAt: Date(),
            citation: citation, quality: .direct
        )
        let profile = makeProfile(
            id: "@I1@", birthDate: "25 JAN 1834",
            sources: [.birthDate: [source]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let out = result.content

        #expect(out.contains("0 @S1@ SOUR"))
        #expect(out.contains("1 ABBR Belper Parish Registers"))
        #expect(out.contains("1 TITL Baptisms 1830-1840"))
        #expect(out.contains("1 PUBL Derbyshire Record Office"))
        #expect(out.contains("1 _URL https://example.org/belper"))
        #expect(out.contains("1 NOTE Entry partially illegible — '34' or '36' unclear."))
        #expect(out.contains("3 QUAY 3"))
    }

    @Test func deathFieldCitationIsAttachedToDeatEvent() {
        let citation = Citation(
            repository: nil,
            collection: "CWGC Casualty Record",
            title: nil,
            page: "Service no 12345",
            url: nil,
            dateAccessed: nil,
            notes: nil
        )
        let source = FieldSource(
            origin: .cwgc, raw: "cwgc",
            addedAt: Date(),
            citation: citation, quality: .primary
        )
        let profile = makeProfile(
            id: "@I1@",
            birthDate: "1895",
            deathDate: "15 JUL 1916",
            deathLocation: "Somme, France",
            sources: [.deathDate: [source]]
        )
        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": profile], relationships: [])

        let result = GEDCOMExporter.export(snapshot)
        let allLines = lines(result)

        // Find the `1 DEAT` line, then ensure `2 SOUR @S1@` follows within
        // the event block (i.e. before any sibling `1 ` line).
        guard let deatIdx = allLines.firstIndex(of: "1 DEAT") else {
            Issue.record("DEAT event missing")
            return
        }
        var sourSeen = false
        for line in allLines[(deatIdx + 1)...] {
            if line.hasPrefix("1 ") || line.hasPrefix("0 ") { break }
            if line == "2 SOUR @S1@" { sourSeen = true }
        }
        #expect(sourSeen, "Expected `2 SOUR @S1@` inside DEAT event block")
        #expect(result.content.contains("3 PAGE Service no 12345, CWGC Casualty Record"))
    }
}
