import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Sourcing-gate fix (2026-07-15): research applies must attach the
/// record's citation to the FieldSource they write. Previously the apply
/// path carried origin only — `FieldSource.citation` stayed nil forever, so
/// the Sourcing tab's visibility gate could never fire from research and
/// per-field citations were missing from every profile surface despite
/// living in evidence_records.
@MainActor
struct ApplyCitationTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    @Test func appliedFactCarriesItsCitation() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: "William Cauldwell",
                                 surname: "Cauldwell", givenName: "William",
                                 detailURL: "https://www.freebmd.org.uk/x", rawFields: [:]),
            deathYear: 1900, deathDate: nil, deathPlace: "Belper", age: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "143",
            spouseSurname: nil))
        let scored = ScoredRecord(id: "d1", record: record, verdict: .fact, gates: [], summary: "")

        let failures = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        #expect(failures.isEmpty, "apply reported failures: \(failures.map(\.what))")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let deathSources = after.sources[.deathDate] ?? []
        #expect(deathSources.contains { $0.citation != nil },
                "the applied deathDate must carry the record's citation")
        let cite = deathSources.compactMap(\.citation).first
        #expect(cite?.url == "https://www.freebmd.org.uk/x")
        #expect(cite?.notes?.contains("FreeBMD") == true,
                "citation notes carry the rendered full citation; got \(cite?.notes ?? "nil")")

        // Mirror of AppState.sourcingTabVisible — the Sourcing tab must be
        // earnable by a research apply, not only manual citation entry.
        let anyCited = after.sources.values.contains { $0.contains { $0.citation != nil } }
        #expect(anyCited, "sourcingTabVisible predicate must fire from a research apply")
    }
}
