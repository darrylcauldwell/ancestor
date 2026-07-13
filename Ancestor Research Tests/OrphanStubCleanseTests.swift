import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// IMPORT_DEDUPE_SPEC — orphan-stub detection + cleanse, reproducing the
/// live Ancestry-export case (Carter / Mary Ward / Keyworth) as a
/// synthetic fixture (no real family data).
@MainActor
struct OrphanStubCleanseTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func profile(_ id: String, first: String?, last: String,
                         birth: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
    }

    /// Fixture: a linked couple + child (edge-bearing), plus three empty
    /// orphan stubs (surname-only "Carter", named "Mary Ward", named
    /// "George Keyworth") each duplicating a linked profile.
    private func seedFixture(_ db: ProjectDatabase) throws {
        // Linked family: John Carter m. Betsy, child Mary Ward is a
        // separate linked person; George Keyworth linked as a parent.
        _ = try db.addProfile(profile("carter_linked", first: "John", last: "Carter"), source: .gedcom)
        _ = try db.addProfile(profile("betsy", first: "Betsy", last: "Cauldwell"), source: .gedcom)
        _ = try db.addProfile(profile("maryward_linked", first: "Mary", last: "Ward", birth: "1900"), source: .gedcom)
        _ = try db.addProfile(profile("george_linked", first: "George", last: "Keyworth", birth: "1904"), source: .gedcom)
        _ = try db.addProfile(profile("child", first: "Ann", last: "Carter"), source: .gedcom)
        // Edges make the above edge-bearing.
        _ = try db.addRelationship(Relationship(id: UUID(), from: "carter_linked", to: "betsy", type: .spouse, role: nil, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(Relationship(id: UUID(), from: "carter_linked", to: "child", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(Relationship(id: UUID(), from: "maryward_linked", to: "child", type: .parent, role: .mother, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(Relationship(id: UUID(), from: "george_linked", to: "child", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))

        // The orphan stubs: no edges, no data.
        _ = try db.addProfile(profile("carter_stub", first: nil, last: "Carter"), source: .gedcom)       // surname-only
        _ = try db.addProfile(profile("maryward_stub", first: "Mary", last: "Ward"), source: .gedcom)     // named, empty
        _ = try db.addProfile(profile("george_stub", first: "George", last: "Keyworth"), source: .gedcom) // named, empty
    }

    // MARK: - Detection

    @Test func detectsAllThreeStubsIncludingSurnameOnly() throws {
        let db = try makeDB()
        try seedFixture(db)
        let snapshot = try db.buildSnapshot()

        let candidates = OrphanStubDetector.candidates(in: snapshot)
        let stubIDs = Set(candidates.map(\.stubID))
        // The surname-only Carter stub — the case DuplicateDetectionRule misses.
        #expect(stubIDs.contains("carter_stub"))
        #expect(stubIDs.contains("maryward_stub"))
        #expect(stubIDs.contains("george_stub"))
        // All three are empty → all cleansable.
        #expect(Set(OrphanStubDetector.cleansableEmptyStubIDs(in: snapshot))
            == ["carter_stub", "maryward_stub", "george_stub"])
        // The linked profiles are never themselves stubs.
        #expect(!stubIDs.contains("carter_linked"))
        #expect(!stubIDs.contains("maryward_linked"))
    }

    @Test func droppedMiddleNameStubIsMatched() throws {
        // The Dorothy Keyworth case: stub "Dorothy Keyworth" (no middle
        // name, no data) duplicates the linked "Dorothy Winnifred Keyworth".
        let db = try makeDB()
        _ = try db.addProfile(profile("dw_linked", first: "Dorothy Winnifred", last: "Keyworth", birth: "1901"), source: .gedcom)
        _ = try db.addProfile(profile("dw_child", first: "Ann", last: "Keyworth"), source: .gedcom)
        _ = try db.addRelationship(Relationship(id: UUID(), from: "dw_linked", to: "dw_child", type: .parent, role: .mother, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addProfile(profile("dorothy_stub", first: "Dorothy", last: "Keyworth"), source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let candidates = OrphanStubDetector.candidates(in: snapshot)
        #expect(candidates.contains { $0.stubID == "dorothy_stub" && $0.targetID == "dw_linked" })
        #expect(OrphanStubDetector.cleansableEmptyStubIDs(in: snapshot).contains("dorothy_stub"))
        // Conservative: a DIFFERENT primary forename never matches.
        #expect(OrphanStubDetector.givenNameMatch(stub: "MARGARET DOROTHY", target: "DOROTHY WINNIFRED") == nil)
    }

    @Test func surnameOnlyStubBeatsDuplicateDetectionBlindSpot() throws {
        let db = try makeDB()
        try seedFixture(db)
        let snapshot = try db.buildSnapshot()
        guard let stub = snapshot.profiles["carter_stub"] else { Issue.record("stub missing"); return }

        // DuplicateDetectionRule scores surname(0.4)+given(0)+year(0) = 0.4 < 0.7 → misses it.
        let dupResults = DuplicateDetectionRule().evaluate(profile: stub, snapshot: snapshot)
        #expect(dupResults.isEmpty)
        // OrphanStubRule catches it.
        let orphanResults = OrphanStubRule().evaluate(profile: stub, snapshot: snapshot)
        #expect(!orphanResults.isEmpty)
        #expect(orphanResults.first?.message.contains("surname-only") == true)
    }

    // MARK: - Cleanse

    @Test func cleanseRemovesEmptyStubsLosesNothingIdempotent() throws {
        let db = try makeDB()
        try seedFixture(db)
        var snapshot = try db.buildSnapshot()
        let before = snapshot.profiles.count

        let removed = try ProfileMergeEngine.cleanseAllEmptyStubs(snapshot: snapshot, db: db)
        #expect(removed == 3)
        snapshot = try db.buildSnapshot()
        #expect(snapshot.profiles.count == before - 3)
        // The linked profiles and edges survive untouched.
        #expect(snapshot.profiles["carter_linked"] != nil)
        #expect(snapshot.profiles["maryward_linked"] != nil)
        #expect(snapshot.relationships.count == 4)

        // Idempotent — a second pass finds nothing.
        let again = try ProfileMergeEngine.cleanseAllEmptyStubs(snapshot: snapshot, db: db)
        #expect(again == 0)
    }

    @Test func cleanseRefusesAStubThatGainedData() throws {
        let db = try makeDB()
        try seedFixture(db)
        // Give the "empty" George stub a birth date — it's no longer a
        // safe empty cleanse.
        _ = try db.editProfile(profileID: "george_stub", changes: [],
            dateChanges: [(.birthDate, nil, GenealogicalDate(parsing: "1905"))],
            source: SourceOrigin(identifier: "manual.edit"))
        let snapshot = try db.buildSnapshot()

        // It's still detected (name match) but NOT in the cleansable set.
        #expect(!OrphanStubDetector.cleansableEmptyStubIDs(in: snapshot).contains("george_stub"))
        let didRemove = try ProfileMergeEngine.cleanseEmptyStub(
            stubID: "george_stub", snapshot: snapshot, db: db)
        #expect(didRemove == false)
        #expect(try db.buildSnapshot().profiles["george_stub"] != nil)
    }

    // MARK: - General merge (edge redirect)

    @Test func mergeRedirectsEdgesAndDeletesLoser() throws {
        let db = try makeDB()
        try seedFixture(db)
        // Merge the linked Mary Ward (loser) into a new winner, verifying
        // her parent-of-child edge repoints.
        _ = try db.addProfile(profile("maryward_winner", first: "Mary", last: "Ward", birth: "1900"), source: .gedcom)
        let snapshot = try db.buildSnapshot()

        try ProfileMergeEngine.merge(
            loserID: "maryward_linked", winnerID: "maryward_winner",
            snapshot: snapshot, db: db)

        let after = try db.buildSnapshot()
        #expect(after.profiles["maryward_linked"] == nil)
        // The child now has maryward_winner as a mother-edge source.
        let motherEdges = after.relationships.filter {
            $0.type == .parent && $0.to == "child" && $0.role == .mother
        }
        #expect(motherEdges.count == 1)
        #expect(motherEdges.first?.from == "maryward_winner")
    }
}
