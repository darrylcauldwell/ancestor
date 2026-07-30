import Testing
import Foundation
@testable import Ancestor_Research
@testable import AncestorKit

/// Upload orchestrator (WL4 — FAMILYSEARCH_TREES_WRITE_SPEC §2/§6): the full
/// documented call sequence against the mock transport + a real temp database,
/// resume (pre-linked entities are skipped, not re-created), and fail-soft
/// (per-entity failure captured, run continues, one-way finalize withheld).
/// Serialized: FSMockURLProtocol state is process-global.
@Suite(.serialized)
struct FamilySearchTreeUploadServiceTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FSMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func person(_ id: String, first: String, last: String, gender: Gender, death: String) -> Profile {
        Profile(id: id, firstName: first, lastName: last, gender: gender,
                deathDate: GenealogicalDate(parsing: death),
                isDeleted: false, sources: [:], disputes: [:])
    }

    /// Husband + wife + child, one couple, one two-parent relationship, one
    /// citation on the husband. Profile IDs sort @C@ < @H@ < @W@.
    private func makeFixture(db: ProjectDatabase, withCitation: Bool = true) throws -> FSUploadPlan {
        var husband = person("@H@", first: "William", last: "Keyworth", gender: .male, death: "1930")
        if withCitation {
            husband.sources[.birthDate] = [FieldSource(
                origin: .freebmd, raw: "x", addedAt: Date(),
                citation: Citation(collection: "FreeBMD Birth Index", url: "https://freebmd.org.uk/x"))]
        }
        let wife = person("@W@", first: "Elizabeth", last: "Shaw", gender: .female, death: "1940")
        let child = person("@C@", first: "George", last: "Keyworth", gender: .male, death: "1970")
        for p in [husband, wife, child] { _ = try db.addProfile(p, source: .gedcom) }

        let snapshot = FamilyGraphSnapshot(
            profiles: ["@H@": husband, "@W@": wife, "@C@": child],
            relationships: [
                Relationship(id: UUID(), from: "@H@", to: "@W@", type: .spouse, role: nil,
                             subtype: .unknown, marriageDate: GenealogicalDate(parsing: "1896"),
                             marriageLocation: "Worksop", divorceDate: nil),
                Relationship(id: UUID(), from: "@H@", to: "@C@", type: .parent, role: .father,
                             subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
                Relationship(id: UUID(), from: "@W@", to: "@C@", type: .parent, role: .mother,
                             subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            ])
        return try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
    }

    private let config = FamilySearchTreeEncoder.Config(
        treeName: "Test Tree", treeDescription: "test", environment: .beta, currentYear: 2026)

    private func makeService(db: ProjectDatabase) -> FamilySearchTreeUploadService {
        let client = FamilySearchClient(environment: .beta,
                                        tokenSource: UploadFakeTokenSource(),
                                        session: mockSession(), sleeper: { _ in })
        return FamilySearchTreeUploadService(client: client, database: db, environment: .beta)
    }

    @Test func fullRunExecutesDocumentedSequenceAndFinalizes() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "G1"])    // group
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "T1"])    // tree
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (persons)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-C"])   // person @C@
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-H"])   // person @H@
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-W"])   // person @W@
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (relationships)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "R-COUPLE"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "R-CAP"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SD1"])   // source description
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (source refs)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SR1"])   // attach person sources
        FSMockURLProtocol.enqueue(status: 204)                                    // finalize
        FSMockURLProtocol.enqueue(status: 204)                                    // restore GLOBAL

        let db = try makeTempDB()
        let plan = try makeFixture(db: db)
        let summary = try await makeService(db: db).upload(
            plan: plan, config: config, runID: UUID().uuidString,
            startingProfileID: "@H@", isPrivate: true, progress: { _ in })

        #expect(summary.treeID == "T1")
        #expect(summary.personsCreated == 3)
        #expect(summary.relationshipsCreated == 2)
        #expect(summary.sourceDescriptionsCreated == 1)
        #expect(summary.sourceReferencesAttached == 1)
        #expect(summary.failures.isEmpty)
        #expect(summary.finalized)

        // Bookkeeping recorded for resume:
        #expect(try db.familySearchPersonLinks(fsTreeID: "T1") == ["@C@": "P-C", "@H@": "P-H", "@W@": "P-W"])
        #expect(try db.familySearchEntityLinks(fsTreeID: "T1", kind: "couple").count == 1)
        let run = try #require(try db.latestFamilySearchUploadRun(environment: "beta"))
        #expect(run.phase == "finalized")
        #expect(run.isPrivate == true)

        // Wire shape spot-checks: finalize targeted the tree, then GLOBAL restore.
        let paths = FSMockURLProtocol.recordedRequests.compactMap { $0.url?.path }
        #expect(paths.contains("/platform/trees/T1"))
        #expect(paths.last == "/platform/trees/current")
        let lastBody = FSMockURLProtocol.lastRequestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(lastBody.contains("GLOBAL"))
    }

    @Test func resumeSkipsEverythingAlreadyLinked() async throws {
        let db = try makeTempDB()
        let plan = try makeFixture(db: db, withCitation: false)
        let runID = UUID().uuidString

        // Simulate an interrupted run that already made the tree + all persons
        // + both relationships.
        try db.saveFamilySearchUploadRun(FSTreeUploadRecord(
            id: runID, environment: "beta", fsGroupID: "G1", fsTreeID: "T1",
            treeName: "Test Tree", treeDescription: "test", startingProfileID: "@H@",
            isPrivate: nil, phase: "uploading", startedAt: Date(), finalizedAt: nil,
            personsUploaded: 3, relationshipsUploaded: 2, sourcesUploaded: 0))
        for (profileID, pid) in ["@H@": "P-H", "@W@": "P-W", "@C@": "P-C"] {
            try db.recordFamilySearchPersonLink(profileID: profileID, fsTreeID: "T1", fsPID: pid)
        }
        for couple in plan.couples {
            try db.recordFamilySearchEntityLink(localKey: couple.localKey, fsTreeID: "T1", kind: "couple", fsID: "R1")
        }
        for cap in plan.childAndParents {
            try db.recordFamilySearchEntityLink(localKey: cap.localKey, fsTreeID: "T1", kind: "childAndParents", fsID: "R2")
        }

        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)   // set current (persons batch — nothing to create)
        FSMockURLProtocol.enqueue(status: 204)   // set current (relationships)
        FSMockURLProtocol.enqueue(status: 204)   // set current (source refs)
        FSMockURLProtocol.enqueue(status: 204)   // finalize
        FSMockURLProtocol.enqueue(status: 204)   // restore GLOBAL

        let summary = try await makeService(db: db).upload(
            plan: plan, config: config, runID: runID,
            startingProfileID: "@H@", isPrivate: false, progress: { _ in })

        #expect(summary.personsCreated == 0)
        #expect(summary.personsSkipped == 3)
        #expect(summary.relationshipsCreated == 0)
        #expect(summary.relationshipsSkipped == 2)
        #expect(summary.finalized)
        // No creates went on the wire — only context, finalize, restore.
        #expect(FSMockURLProtocol.recordedRequests.count == 5)
    }

    @Test func requestDrivenUploadNeverReachesFinalize() async throws {
        // MCP-staged uploads pass performFinalize: false — the one-way hidden
        // flip and privacy choice are wizard consents, so the sequence must
        // stop at uploaded-but-hidden even when the upload is clean.
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "G1"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "T1"])
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (persons)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-C"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-H"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-W"])
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (relationships)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "R-COUPLE"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "R-CAP"])
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (source refs; no citations)
        FSMockURLProtocol.enqueue(status: 204)                                    // restore GLOBAL — finalize never fires

        let db = try makeTempDB()
        let plan = try makeFixture(db: db, withCitation: false)
        let summary = try await makeService(db: db).upload(
            plan: plan, config: config, runID: UUID().uuidString,
            startingProfileID: "@H@", isPrivate: true, performFinalize: false, progress: { _ in })

        #expect(summary.personsCreated == 3)
        #expect(summary.failures.isEmpty)
        #expect(!summary.finalized)
        #expect(summary.finalizeNote?.contains("wizard") == true)
        #expect(!FSMockURLProtocol.recordedRequests.contains { $0.url?.path == "/platform/trees/T1" })
        let run = try #require(try db.latestFamilySearchUploadRun(environment: "beta"))
        #expect(run.phase == "uploading")   // still wizard-finalizable
    }

    @Test func personFailureIsCapturedRunContinuesAndFinalizeIsWithheld() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "G1"])
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "T1"])
        FSMockURLProtocol.enqueue(status: 204)                                    // set current
        FSMockURLProtocol.enqueue(status: 400, body: Data(#"{"errors":[{"message":"bad person"}]}"#.utf8))  // @C@ fails
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-H"])   // @H@ ok
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "P-W"])   // @W@ ok
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (relationships)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "R-COUPLE"])  // couple ok
        // cap skipped without a wire call (child pid missing)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SD1"])   // source description
        FSMockURLProtocol.enqueue(status: 204)                                    // set current (source refs)
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SR1"])   // attach
        FSMockURLProtocol.enqueue(status: 204)                                    // restore GLOBAL (no finalize!)

        let db = try makeTempDB()
        let plan = try makeFixture(db: db)
        let summary = try await makeService(db: db).upload(
            plan: plan, config: config, runID: UUID().uuidString,
            startingProfileID: "@H@", isPrivate: true, progress: { _ in })

        #expect(summary.personsCreated == 2)
        #expect(summary.failures.contains { $0.stage == "person" && $0.localKey == "@C@" && $0.message.contains("bad person") })
        #expect(summary.failures.contains { $0.stage == "childAndParents" && $0.message.contains("child person was not created") })
        #expect(!summary.finalized)   // one-way hidden flip withheld on blocking failures
        #expect(summary.finalizeNote?.contains("failure") == true)
        let run = try #require(try db.latestFamilySearchUploadRun(environment: "beta"))
        #expect(run.phase == "uploading")   // resumable, not finalized
        // Finalize never went on the wire:
        #expect(!FSMockURLProtocol.recordedRequests.contains { $0.url?.path == "/platform/trees/T1" })
    }
}

private final class UploadFakeTokenSource: FamilySearchTokenSource, @unchecked Sendable {
    func currentBearer() async -> String? { "T" }
    func refreshBearer() async -> String? { nil }
}
