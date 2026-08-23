import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// The tree teaches the search what it has already confirmed.
///
/// `name_equivalences` has existed as a table, a save function and a load
/// function since the schema was written — called by nothing. Meanwhile Mary
/// was STEVENSON at her 1846 marriage and STEPHENSON at her 1823 baptism, and
/// that pairing had to be rediscovered by hand on FreeREG because no search
/// carried it. Applying the baptism taught the app nothing.
///
/// Applying a record IS a human saying "this record is this person". When the
/// spellings differ, that is a confirmed variant for this tree.
@MainActor
struct LearnedSurnameEquivalenceTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        return db
    }

    private func mary(lastName: String = "Stevenson", married: String? = nil) -> Profile {
        Profile(id: "mary", firstName: "Mary", lastName: lastName,
                marriedSurname: married, gender: .female,
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func parishRecord(surname: String) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(id: "b", sourceID: "freereg", name: "Mary \(surname)",
                                 surname: surname, givenName: "Mary",
                                 detailURL: nil, rawFields: [:]),
            eventType: "baptism", eventYear: 1823, parish: "Youlgreave", county: "Derbyshire",
            fatherName: "John STEPHENSON", motherName: "Lydia"))
    }

    // MARK: - Learning

    /// THE SPECIMEN.
    @Test func applyingADifferentlySpelledRecordTeachesThePair() throws {
        let db = try makeDB()
        AppState.learnSurnameEquivalence(
            from: parishRecord(surname: "STEPHENSON"), profile: mary(), db: db)
        let pairs = try db.loadNameEquivalences()
            .map { Set([$0.0.uppercased(), $0.1.uppercased()]) }
        #expect(pairs.contains(["STEPHENSON", "STEVENSON"]),
                "applying her baptism must teach STEVENSON ≡ STEPHENSON")
    }

    /// The same spelling teaches nothing — there is no variant to learn.
    @Test func anIdenticalSurnameTeachesNothing() throws {
        let db = try makeDB()
        AppState.learnSurnameEquivalence(
            from: parishRecord(surname: "Stevenson"), profile: mary(), db: db)
        #expect(try db.loadNameEquivalences().isEmpty)
    }

    /// A CENSUS surname can fall back to the household head when the target
    /// marker doesn't survive parsing — teaching a wife her husband's surname
    /// as a variant of her maiden one.
    @Test func censusRecordsNeverTeach() throws {
        let db = try makeDB()
        let census = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c", sourceID: "freecen", name: "Mary HOLMES",
                                 surname: "HOLMES", givenName: "Mary",
                                 detailURL: nil, rawFields: [:]),
            censusYear: 1861))
        AppState.learnSurnameEquivalence(from: census, profile: mary(), db: db)
        #expect(try db.loadNameEquivalences().isEmpty,
                "a census surname is not evidence of a spelling variant")
    }

    /// Her MARRIED surname is a different fact about her, not a spelling of her
    /// maiden name.
    @Test func aMarriedSurnameIsNotAVariant() throws {
        let db = try makeDB()
        AppState.learnSurnameEquivalence(
            from: parishRecord(surname: "HOLMES"),
            profile: mary(married: "Holmes"), db: db)
        #expect(try db.loadNameEquivalences().isEmpty)
    }

    /// Two unrelated surnames on one applied record mean something else went
    /// wrong. That must not be laundered into a permanent search rule.
    @Test func dissimilarSurnamesAreNotLearned() throws {
        let db = try makeDB()
        AppState.learnSurnameEquivalence(
            from: parishRecord(surname: "WHEELDON"), profile: mary(), db: db)
        #expect(try db.loadNameEquivalences().isEmpty,
                "STEVENSON and WHEELDON is a bad apply, not a variant")
    }

    // MARK: - Teaching the query builder

    /// Both directions, because the table stores an unordered pair and the
    /// lookup is by key.
    @Test func theLookupMapIsSymmetric() throws {
        let db = try makeDB()
        try db.saveNameEquivalence(nameA: "STEVENSON", nameB: "STEPHENSON")
        let map = ResearchRunService.learnedSurnameVariants(database: db)
        #expect(map["STEVENSON"]?.contains("STEPHENSON") == true)
        #expect(map["STEPHENSON"]?.contains("STEVENSON") == true)
    }

    /// A learned pair reaches the actual variant fan-out — the point of the
    /// whole exercise.
    @Test func aLearnedPairReachesTheQueryFanOut() throws {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        let source = try #require(registry.allSources().first { $0.sourceID == "freereg" })
        let query = RecordQuery(
            surname: "Stevenson", givenName: "Mary", recordType: .baptism,
            yearFrom: 1820, yearTo: 1827, gender: .female, region: nil,
            sourceParams: .freeREG(FreeREGParams(chapmanCodes: ["DBY"])))

        let without = SearchDispatcher.applyStrictness(
            [query], strictness: .variant, source: source)
        let with = SearchDispatcher.applyStrictness(
            [query], strictness: .variant, source: source,
            learnedSurnameVariants: ["STEVENSON": ["STEPHENSON"]])

        let learned = Set(with.compactMap(\.surname).map { $0.uppercased() })
        #expect(learned.contains("STEPHENSON"))
        #expect(with.count >= without.count)
    }

    /// No database means no learning and no crash — the pipeline runs without
    /// one in tests and previews.
    @Test func noDatabaseYieldsAnEmptyMap() {
        #expect(ResearchRunService.learnedSurnameVariants(database: nil).isEmpty)
    }
}
