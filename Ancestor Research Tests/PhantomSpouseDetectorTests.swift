import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// IMPORT_DEDUPE_SPEC Change 4 — phantom-spouse detection, reproducing the
/// live William Henry Keyworth four-spouse case as a synthetic fixture (two
/// real wives with dates, two dateless phantom stubs each tied only to William).
/// No real family data.
@MainActor
struct PhantomSpouseDetectorTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func profile(_ id: String, first: String?, last: String?,
                         middle: String? = nil, birth: String? = nil,
                         death: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: middle, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: death.map { GenealogicalDate(parsing: $0) }, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseEdge(_ from: String, _ to: String) -> Relationship {
        Relationship(id: UUID(), from: from, to: to, type: .spouse, role: nil,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// William (anchor, edge-bearing via a child) + two documented wives
    /// (Emma, Wallace — both with dates) + two dateless phantoms (Gerty,
    /// Carroll). Edge directions deliberately mixed to exercise both sides.
    private func seedKeyworth(_ db: ProjectDatabase, wallaceMiddle: String? = nil) throws {
        _ = try db.addProfile(profile("william", first: "William Henry", last: "Keyworth", birth: "1875"), source: .gedcom)
        _ = try db.addProfile(profile("child", first: "Florence", last: "Keyworth", birth: "1900"), source: .gedcom)
        _ = try db.addProfile(profile("emma", first: "Emma", last: "Gladwin", birth: "1868", death: "1909"), source: .gedcom)
        _ = try db.addProfile(profile("wallace", first: "Elizabeth", last: "Wallace", middle: wallaceMiddle, birth: "1871", death: "1916"), source: .gedcom)
        _ = try db.addProfile(profile("gerty", first: "Gerty", last: nil), source: .gedcom)         // phantom, empty
        _ = try db.addProfile(profile("carroll", first: "Elizabeth", last: "Carroll"), source: .gedcom) // phantom, empty
        // William → child makes William edge-bearing (not itself a phantom).
        _ = try db.addRelationship(Relationship(id: UUID(), from: "william", to: "child", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        // Documented wives (william → spouse); phantoms (phantom → william).
        _ = try db.addRelationship(spouseEdge("william", "emma"))
        _ = try db.addRelationship(spouseEdge("william", "wallace"))
        _ = try db.addRelationship(spouseEdge("gerty", "william"))
        _ = try db.addRelationship(spouseEdge("carroll", "william"))
    }

    // MARK: - AC1 / AC2 — the Keyworth case

    @Test func bothPhantomsDetectedAnchoredToWilliamWithDocumentedChoices() throws {
        let db = try makeDB(); try seedKeyworth(db)
        let snapshot = try db.buildSnapshot()

        let candidates = PhantomSpouseDetector.candidates(in: snapshot)
        let byPhantom = Dictionary(uniqueKeysWithValues: candidates.map { ($0.phantomID, $0) })

        // Both phantoms fire, both anchored to William.
        #expect(byPhantom["gerty"]?.anchorID == "william")
        #expect(byPhantom["carroll"]?.anchorID == "william")
        // Documented spouse SET = Emma + Wallace (sorted by id), never the
        // phantoms — carried on BOTH candidates regardless of the suggestion.
        #expect(byPhantom["gerty"]?.documentedSpouseIDs == ["emma", "wallace"])
        #expect(byPhantom["carroll"]?.documentedSpouseIDs == ["emma", "wallace"])
        // "Gerty" matches neither wife's stored name → ambiguous among the two
        // documented wives → NO silent single target (the card presents
        // choices), but the phantom is NOT dropped (AC2).
        #expect(byPhantom["gerty"]?.suggestedTargetID == nil)
        #expect(byPhantom["gerty"]?.nameContainment == false)
        // "Elizabeth" Carroll shares the given name of the "Elizabeth" wife, so
        // the name-containment tiebreak (decision #8) routes her to Wallace and
        // not Emma — a single, well-defined suggestion even amid two documented
        // wives. Still user-confirmed (decision #9); never auto-merged.
        #expect(byPhantom["carroll"]?.suggestedTargetID == "wallace")
        #expect(byPhantom["carroll"]?.nameContainment == true)
        // The documented wives are never themselves flagged as phantoms.
        #expect(byPhantom["emma"] == nil)
        #expect(byPhantom["wallace"] == nil)
    }

    @Test func ruleFiresForEachPhantomOnly() throws {
        let db = try makeDB(); try seedKeyworth(db)
        let snapshot = try db.buildSnapshot()
        let rule = PhantomSpouseRule()

        #expect(!rule.evaluate(profile: snapshot.profiles["gerty"]!, snapshot: snapshot).isEmpty)
        #expect(!rule.evaluate(profile: snapshot.profiles["carroll"]!, snapshot: snapshot).isEmpty)
        // Not for the anchor, nor the real wives.
        #expect(rule.evaluate(profile: snapshot.profiles["william"]!, snapshot: snapshot).isEmpty)
        #expect(rule.evaluate(profile: snapshot.profiles["wallace"]!, snapshot: snapshot).isEmpty)
        // The message names the anchor and the documented choices, in plain terms.
        let msg = rule.evaluate(profile: snapshot.profiles["gerty"]!, snapshot: snapshot).first!.message
        #expect(msg.contains("William Henry Keyworth"))
        #expect(msg.contains("Elizabeth Wallace"))
    }

    // MARK: - Decision #8 — name-containment booster + tiebreak

    @Test func middleNameContainmentSinglesOutTargetAmongDocumentedSet() throws {
        // Containment matches on NAME TOKENS (given or middle), not diminutives:
        // a phantom "Gertrude" is contained in a wife stored as "Elizabeth
        // Gertrude Wallace" (via her middle name) but not in "Emma Gladwin", so
        // the ambiguous two-wife set resolves to Wallace. (A phantom "Gerty"
        // would NOT match — "Gerty" is a diminutive, not a token of "Gertrude".)
        let db = try makeDB()
        _ = try db.addProfile(profile("man", first: "William", last: "Keyworth", birth: "1875"), source: .gedcom)
        _ = try db.addProfile(profile("kid", first: "Florence", last: "Keyworth", birth: "1900"), source: .gedcom)
        _ = try db.addProfile(profile("emma", first: "Emma", last: "Gladwin", birth: "1868", death: "1909"), source: .gedcom)
        _ = try db.addProfile(profile("wallace", first: "Elizabeth", last: "Wallace", middle: "Gertrude", birth: "1871", death: "1916"), source: .gedcom)
        _ = try db.addProfile(profile("phantom", first: "Gertrude", last: nil), source: .gedcom)
        _ = try db.addRelationship(Relationship(id: UUID(), from: "man", to: "kid", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(spouseEdge("man", "emma"))
        _ = try db.addRelationship(spouseEdge("man", "wallace"))
        _ = try db.addRelationship(spouseEdge("phantom", "man"))
        let snapshot = try db.buildSnapshot()

        let cand = PhantomSpouseDetector.candidates(in: snapshot).first { $0.phantomID == "phantom" }
        #expect(cand?.documentedSpouseIDs == ["emma", "wallace"])
        #expect(cand?.suggestedTargetID == "wallace")
        #expect(cand?.nameContainment == true)
        // A diminutive that is NOT a shared token does not resolve the ambiguity.
        let wallace = snapshot.profiles["wallace"]!
        #expect(PhantomSpouseDetector.nameContained(
            phantom: profile("g", first: "Gerty", last: nil), in: wallace) == false)
    }

    // MARK: - AC3 / AC4 — real footprints never fire

    @Test func datedSpouseOnlyProfileDoesNotFire() throws {
        // A thin but real person: sole edge is a spouse-link, but she HAS a
        // birth date → not empty → not a phantom (AC3).
        let db = try makeDB()
        _ = try db.addProfile(profile("him", first: "John", last: "Smith", birth: "1880"), source: .gedcom)
        _ = try db.addProfile(profile("kid", first: "Ann", last: "Smith", birth: "1905"), source: .gedcom)
        _ = try db.addProfile(profile("thinwife", first: "Jane", last: "Doe", birth: "1882"), source: .gedcom)
        _ = try db.addRelationship(Relationship(id: UUID(), from: "him", to: "kid", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(spouseEdge("him", "thinwife"))
        let snapshot = try db.buildSnapshot()

        #expect(!PhantomSpouseDetector.candidates(in: snapshot).contains { $0.phantomID == "thinwife" })
    }

    @Test func spousePlusChildEdgeDoesNotFire() throws {
        // Empty on data, but has TWO edges (spouse + child) → real footprint (AC4).
        let db = try makeDB()
        _ = try db.addProfile(profile("dad", first: "John", last: "Smith", birth: "1880"), source: .gedcom)
        _ = try db.addProfile(profile("mum", first: "Jane", last: "Smith"), source: .gedcom)   // empty
        _ = try db.addProfile(profile("baby", first: "Ann", last: "Smith", birth: "1905"), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("dad", "mum"))
        _ = try db.addRelationship(Relationship(id: UUID(), from: "mum", to: "baby", type: .parent, role: .mother, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        let snapshot = try db.buildSnapshot()

        #expect(!PhantomSpouseDetector.candidates(in: snapshot).contains { $0.phantomID == "mum" })
    }

    // MARK: - AC5 — anchor with no documented spouse still fires (nil target)

    @Test func phantomWithNoDocumentedSpouseFiresWithNilTarget() throws {
        // A dateless spouse-only stub whose anchor's ONLY other spouse is
        // itself empty → no documented target, but it still surfaces for
        // manual review (AC5).
        let db = try makeDB()
        _ = try db.addProfile(profile("man", first: "Tom", last: "Jones", birth: "1850"), source: .gedcom)
        _ = try db.addProfile(profile("kid2", first: "Sue", last: "Jones", birth: "1875"), source: .gedcom)
        _ = try db.addProfile(profile("phantomA", first: "Mary", last: nil), source: .gedcom)   // empty phantom
        _ = try db.addRelationship(Relationship(id: UUID(), from: "man", to: "kid2", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(spouseEdge("man", "phantomA"))
        let snapshot = try db.buildSnapshot()

        let cand = PhantomSpouseDetector.candidates(in: snapshot).first { $0.phantomID == "phantomA" }
        #expect(cand != nil)
        #expect(cand?.suggestedTargetID == nil)
        #expect(cand?.documentedSpouseIDs.isEmpty == true)
    }

    @Test func singleDocumentedSpouseIsSuggestedDirectly() throws {
        // The clean common case: one real wife + one phantom → suggest the wife.
        let db = try makeDB()
        _ = try db.addProfile(profile("man", first: "Tom", last: "Jones", birth: "1850"), source: .gedcom)
        _ = try db.addProfile(profile("kid2", first: "Sue", last: "Jones", birth: "1875"), source: .gedcom)
        _ = try db.addProfile(profile("realwife", first: "Mary", last: "Jones", birth: "1852", death: "1900"), source: .gedcom)
        _ = try db.addProfile(profile("phantomA", first: "May", last: nil), source: .gedcom)
        _ = try db.addRelationship(Relationship(id: UUID(), from: "man", to: "kid2", type: .parent, role: .father, subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        _ = try db.addRelationship(spouseEdge("man", "realwife"))
        _ = try db.addRelationship(spouseEdge("man", "phantomA"))
        let snapshot = try db.buildSnapshot()

        let cand = PhantomSpouseDetector.candidates(in: snapshot).first { $0.phantomID == "phantomA" }
        #expect(cand?.suggestedTargetID == "realwife")
    }

    // MARK: - Change 5 — "separate people" reviewed marker persists + filters

    @Test func reviewedMarkerPersistsAndFiltersFromScan() throws {
        let db = try makeDB(); try seedKeyworth(db)

        // "These were separate people" on Gerty writes the reviewed marker.
        try db.markPhantomSpouseReviewed(profileID: "gerty")
        #expect(try db.reviewedPhantomSpouseIDs() == ["gerty"])

        // The pure detector still finds BOTH — the marker lives outside the
        // snapshot — but the scan's app-layer filter (mirrored here) drops the
        // reviewed one so it stops nagging (Change 5 AC2).
        let all = PhantomSpouseDetector.candidates(in: try db.buildSnapshot())
        #expect(Set(all.map(\.phantomID)) == ["carroll", "gerty"])
        let reviewed = try db.reviewedPhantomSpouseIDs()
        #expect(all.filter { !reviewed.contains($0.phantomID) }.map(\.phantomID) == ["carroll"])

        // Idempotent — marking again keeps the set at one; never deletes the
        // profile (it still exists in the snapshot).
        try db.markPhantomSpouseReviewed(profileID: "gerty")
        #expect(try db.reviewedPhantomSpouseIDs() == ["gerty"])
        #expect(try db.buildSnapshot().profiles["gerty"] != nil)
    }

    // MARK: - Change 5 AC1 — combining reproduces the verified end-state

    @Test func combiningBothPhantomsIntoWallaceLeavesEmmaPlusWallaceNoDuplicate() throws {
        let db = try makeDB(); try seedKeyworth(db)

        // The card's "Combine" action IS ProfileMergeEngine.merge(loser: phantom,
        // winner: chosen wife). Reproduce the manual-verified outcome.
        try ProfileMergeEngine.merge(loserID: "gerty", winnerID: "wallace",
                                     snapshot: try db.buildSnapshot(), db: db)
        try ProfileMergeEngine.merge(loserID: "carroll", winnerID: "wallace",
                                     snapshot: try db.buildSnapshot(), db: db)

        let after = try db.buildSnapshot()
        // Phantoms gone.
        #expect(after.profiles["gerty"] == nil)
        #expect(after.profiles["carroll"] == nil)
        // William has EXACTLY two spouses — Emma + Wallace — no duplicate edge.
        let williamSpouseIDs = Set(after.spousesOf("william").map(\.id))
        #expect(williamSpouseIDs == ["emma", "wallace"])
        let wallaceEdges = after.relationships.filter {
            $0.type == .spouse &&
            (($0.from == "william" && $0.to == "wallace") || ($0.from == "wallace" && $0.to == "william"))
        }
        #expect(wallaceEdges.count == 1)
        // No phantoms remain to detect.
        #expect(PhantomSpouseDetector.candidates(in: after).isEmpty)
    }

    // MARK: - Option A — merge salvages cited records, drops bare provenance

    @Test func mergeSalvagesCitedRecordsAndDropsBareProvenance() throws {
        let db = try makeDB(); try seedKeyworth(db)
        // Gerty carries two field_sources: a bare GEDCOM name provenance (no
        // citation — the unwanted "Gerty" fragment) and a real cited record
        // (a christening URL). Only the cited one should survive the merge.
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES ('gerty','profile','firstName','gedcom','Gerty', ?)
                """, arguments: [Date()])
            try d.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at, citation_json)
                VALUES ('gerty','profile','firstName','freereg','Gertrude', ?, ?)
                """, arguments: [Date(), #"{"url":"https://freereg/christening"}"#])
        }

        // Mirror AppState.performProfileMerge: salvage, then structural merge.
        try db.salvageCitedFieldSources(fromProfileID: "gerty", toProfileID: "wallace")
        try ProfileMergeEngine.merge(loserID: "gerty", winnerID: "wallace",
                                     snapshot: try db.buildSnapshot(), db: db)

        let (citedOnWinner, bareRemaining) = try db.dbQueue.read { d -> (Int, Int) in
            let cited = try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM field_sources
                WHERE entity_id='wallace' AND citation_json IS NOT NULL AND raw='Gertrude'
                """) ?? 0
            let bare = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM field_sources WHERE raw='Gerty'") ?? 0
            return (cited, bare)
        }
        // The cited christening record is preserved on Elizabeth Wallace…
        #expect(citedOnWinner == 1)
        // …and the bare "Gerty" name provenance is gone (deleted with the phantom).
        #expect(bareRemaining == 0)
    }
}
