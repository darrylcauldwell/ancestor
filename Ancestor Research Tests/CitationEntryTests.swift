import Testing
import Foundation
@testable import Ancestor_Research

/// Covers the M9 citation entry pipeline:
///   - Citation model invariants (isEmpty / formatted)
///   - CitationSuggestService frequency ranking & empty filtering
///   - DB round-trip via updateFieldSourceCitation + buildSnapshot
struct CitationEntryTests {

    // MARK: - Helpers

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(
        id: String = UUID().uuidString,
        firstName: String? = "Alice",
        lastName: String? = "Land"
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: nil, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    /// Build a snapshot whose profiles already carry FieldSources with
    /// citations on `firstName` — used to drive the suggest-service tests
    /// without reaching into the database.
    private func snapshotWithCitations(_ entries: [(repository: String?, collection: String?)]) -> FamilyGraphSnapshot {
        var profiles: [String: Profile] = [:]
        for (idx, entry) in entries.enumerated() {
            let id = "p\(idx)"
            let citation = Citation(
                repository: entry.repository,
                collection: entry.collection
            )
            let source = FieldSource(
                origin: .manualRecord,
                raw: "Alice",
                addedAt: Date(),
                citation: citation,
                quality: nil
            )
            var p = makeProfile(id: id)
            p.sources = [.firstName: [source]]
            profiles[id] = p
        }
        return FamilyGraphSnapshot(profiles: profiles, relationships: [])
    }

    // MARK: - Citation invariants

    @Test func citationIsEmpty_trueWhenAllFieldsBlank() {
        let empty = Citation()
        #expect(empty.isEmpty == true)

        let blanks = Citation(
            repository: "", collection: "", title: "",
            page: "", url: "", dateAccessed: nil, notes: ""
        )
        #expect(blanks.isEmpty == true)
    }

    @Test func citationIsEmpty_falseWhenAnyFieldHasContent() {
        let withRepo = Citation(repository: "TNA")
        #expect(withRepo.isEmpty == false)

        let withDate = Citation(dateAccessed: Date())
        #expect(withDate.isEmpty == false)

        let withNotes = Citation(notes: "checked at the archive")
        #expect(withNotes.isEmpty == false)
    }

    @Test func citationFormatted_emptyForEmptyCitation() {
        #expect(Citation().formatted == "")
    }

    @Test func citationFormatted_typicalEntry() {
        // Use a fixed date to avoid locale flakiness within the assertion.
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 14 Nov 2023
        let c = Citation(
            repository: "The National Archives",
            collection: "1851 Census",
            title: "Belper enumeration",
            page: "Vol 7b, p213",
            url: "https://example.org/record/1",
            dateAccessed: date,
            notes: nil
        )
        let f = c.formatted
        // Order is: collection, title, page, repository, url, date.
        #expect(f.contains("1851 Census"))
        #expect(f.contains("Belper enumeration"))
        #expect(f.contains("Vol 7b, p213"))
        #expect(f.contains("The National Archives"))
        #expect(f.contains("https://example.org/record/1"))
        #expect(f.contains("accessed"))
        #expect(f.hasSuffix("."))
    }

    // MARK: - CitationSuggestService

    @Test func repositories_rankByFrequency() {
        let snap = snapshotWithCitations([
            (repository: "TNA", collection: nil),
            (repository: "TNA", collection: nil),
            (repository: "TNA", collection: nil),
            (repository: "Derbyshire RO", collection: nil),
            (repository: "Derbyshire RO", collection: nil),
            (repository: "Belper Library", collection: nil),
        ])
        let result = CitationSuggestService.repositories(snapshot: snap)
        #expect(result.first == "TNA")
        #expect(result.dropFirst().first == "Derbyshire RO")
        #expect(result.contains("Belper Library"))
    }

    @Test func repositories_filtersEmptyAndNil() {
        let snap = snapshotWithCitations([
            (repository: "TNA", collection: nil),
            (repository: "", collection: nil),
            (repository: nil, collection: "Some collection"),
        ])
        let result = CitationSuggestService.repositories(snapshot: snap)
        #expect(result == ["TNA"])
    }

    @Test func collections_rankByFrequency() {
        let snap = snapshotWithCitations([
            (repository: nil, collection: "1851 Census"),
            (repository: nil, collection: "1851 Census"),
            (repository: nil, collection: "FreeBMD Birth Index"),
        ])
        let result = CitationSuggestService.collections(snapshot: snap)
        #expect(result.first == "1851 Census")
        #expect(result.contains("FreeBMD Birth Index"))
    }

    @Test func collections_filtersEmpties() {
        let snap = snapshotWithCitations([
            (repository: "TNA", collection: ""),
            (repository: nil, collection: nil),
            (repository: nil, collection: "1881 Census"),
        ])
        let result = CitationSuggestService.collections(snapshot: snap)
        #expect(result == ["1881 Census"])
    }

    @Test func suggestions_capAtFive() {
        // Distinct repositories, all frequency 1. Service must cap at 5.
        let snap = snapshotWithCitations(
            (1...8).map { (repository: "Repo \($0)", collection: nil) }
        )
        let result = CitationSuggestService.repositories(snapshot: snap)
        #expect(result.count == 5)
    }

    // MARK: - DB round-trip

    @Test func updateFieldSourceCitation_persistsOnSnapshot() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "rt-1", firstName: "Alice", lastName: "Land")
        try db.addProfile(profile, source: .manualRecord)

        let citation = Citation(
            repository: "TNA",
            collection: "1851 Census",
            page: "HO107/2148"
        )
        try db.updateFieldSourceCitation(
            profileID: "rt-1",
            field: .firstName,
            origin: .manualRecord,
            citation: citation,
            quality: .primary
        )

        let snap = try db.buildSnapshot()
        let sources = snap.profiles["rt-1"]?.sources[.firstName] ?? []
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.citation?.repository == "TNA")
        #expect(source.citation?.collection == "1851 Census")
        #expect(source.citation?.page == "HO107/2148")
        #expect(source.quality == .primary)
    }

    @Test func updateFieldSourceCitation_doesNotTouchOtherFields() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "rt-2", firstName: "Alice", lastName: "Land")
        try db.addProfile(profile, source: .manualRecord)

        let citation = Citation(repository: "TNA")
        try db.updateFieldSourceCitation(
            profileID: "rt-2",
            field: .firstName,
            origin: .manualRecord,
            citation: citation,
            quality: nil
        )

        let snap = try db.buildSnapshot()
        // lastName had its own source row from addProfile — it must remain
        // untouched by the firstName-scoped update.
        let lastNameSources = snap.profiles["rt-2"]?.sources[.lastName] ?? []
        #expect(lastNameSources.first?.citation == nil)
        #expect(lastNameSources.first?.quality == nil)
    }

    @Test func updateFieldSourceCitation_clearsWhenEmpty() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "rt-3", firstName: "Alice")
        try db.addProfile(profile, source: .manualRecord)

        // Attach a citation, then clear by passing an empty Citation.
        let initial = Citation(repository: "TNA")
        try db.updateFieldSourceCitation(
            profileID: "rt-3", field: .firstName, origin: .manualRecord,
            citation: initial, quality: .primary
        )
        try db.updateFieldSourceCitation(
            profileID: "rt-3", field: .firstName, origin: .manualRecord,
            citation: Citation(), quality: nil
        )

        let snap = try db.buildSnapshot()
        let source = snap.profiles["rt-3"]?.sources[.firstName]?.first
        #expect(source?.citation == nil)
        #expect(source?.quality == nil)
    }
}
