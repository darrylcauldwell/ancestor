import Testing
import Foundation
@testable import Ancestor_Research

/// User Tree write methods (WL1 — FAMILYSEARCH_TREES_WRITE_SPEC). Exercises
/// paths, media types, POST bodies (via the mock's body-stream drain), entity-ID
/// extraction (X-entity-id + Location fallback), and write-rejection surfacing.
/// Serialized: the mock uses process-global state.
@Suite(.serialized)
struct FamilySearchClientWriteTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FSMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func client() -> FamilySearchClient {
        FamilySearchClient(environment: .beta,
                           tokenSource: WriteFakeTokenSource(bearer: "T"),
                           session: mockSession(), sleeper: { _ in })
    }

    // MARK: Group + tree

    @Test func createGroupPostsFsV1BodyAndReturnsEntityID() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "9MMN-C68"])
        let body = Data(#"{"groups":[{"name":"Test"}]}"#.utf8)
        let id = try await client().createGroup(body: body)
        #expect(id == "9MMN-C68")
        let request = FSMockURLProtocol.lastRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.path == "/platform/groups")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/x-fs-v1+json")
        #expect(FSMockURLProtocol.lastRequestBody == body)   // body actually went on the wire
    }

    @Test func createTreeTargetsTreesCollection() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "9NMM-9D6C"])
        let id = try await client().createTree(body: Data(#"{"trees":[{"name":"T","groupIds":["G"]}]}"#.utf8))
        #expect(id == "9NMM-9D6C")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/trees")
    }

    @Test func setCurrentTreePostsTreeIDAndAccepts204() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)
        try await client().setCurrentTree(treeID: "9NMM-9D6C")
        let request = FSMockURLProtocol.lastRequest
        #expect(request?.url?.path == "/platform/trees/current")
        #expect(request?.httpMethod == "POST")
        let sent = FSMockURLProtocol.lastRequestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(sent.contains(#""id":"9NMM-9D6C""#))
    }

    @Test func readCurrentTreeParsesTreeID() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"{"trees":[{"id":"GLOBAL"}]}"#.utf8))
        let id = try await client().readCurrentTree()
        #expect(id == "GLOBAL")
        #expect(FSMockURLProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test func updateTreeDefaultsToGedcomxV1AndAccepts204() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)
        let body = Data(#"{"trees":[{"startingPersonId":"P1","hidden":false}]}"#.utf8)
        try await client().updateTree(treeID: "9NMM-9D6C", body: body)
        let request = FSMockURLProtocol.lastRequest
        #expect(request?.url?.path == "/platform/trees/9NMM-9D6C")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/x-gedcomx-v1+json")
    }

    @Test func updateTreeContentTypeIsOverridableForTheFsV1Fallback() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)
        try await client().updateTree(treeID: "T", body: Data("{}".utf8), contentType: .fsV1)
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-fs-v1+json")
    }

    // MARK: Persons + relationships

    @Test func createPersonFallsBackToLocationHeaderForID() async throws {
        // The beta reference documents only Location on person create —
        // the fallback is load-bearing.
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: [
            "Location": "https://api.familysearch.org/platform/tree/persons/ABCD-123",
        ])
        let pid = try await client().createPerson(body: Data(#"{"persons":[{}]}"#.utf8))
        #expect(pid == "ABCD-123")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/persons")
    }

    @Test func createWithoutAnyEntityIDFailsLoudly() async {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201)   // 2xx but no usable ID
        await #expect(throws: FamilySearchClientError.self) {
            _ = try await self.client().createPerson(body: Data("{}".utf8))
        }
    }

    @Test func createRelationshipTargetsGenericRelationshipsCollection() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "PPPX-PP0"])
        let body = Data(#"{"childAndParentsRelationships":[{}]}"#.utf8)
        let rid = try await client().createRelationship(body: body)
        #expect(rid == "PPPX-PP0")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/relationships")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-fs-v1+json")
    }

    // MARK: Sources

    @Test func createSourceDescriptionUsesGedcomxV1() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "QDS-NBVC"])
        let id = try await client().createSourceDescription(body: Data(#"{"sourceDescriptions":[{}]}"#.utf8))
        #expect(id == "QDS-NBVC")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/sources/descriptions")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-gedcomx-v1+json")
    }

    @Test func attachPersonSourcesPostsToThePersonResourceItself() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SRSR-R01"])
        let refID = try await client().attachPersonSources(pid: "PPPP-PPP", body: Data(#"{"persons":[{"sources":[]}]}"#.utf8))
        #expect(refID == "SRSR-R01")
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/persons/PPPP-PPP")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-gedcomx-v1+json")
    }

    @Test func attachToleratesAMissingReferenceID() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)   // attach succeeded, no ID minted
        let refID = try await client().attachCoupleSources(relationshipID: "RRRR-RRR", body: Data("{}".utf8))
        #expect(refID == nil)
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/couple-relationships/RRRR-RRR/source-references")
    }

    @Test func attachChildAndParentsSourcesUsesFsV1ExtensionType() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 201, headers: ["X-entity-id": "SRSR-R02"])
        _ = try await client().attachChildAndParentsSources(relationshipID: "RRRR-RRR", body: Data("{}".utf8))
        #expect(FSMockURLProtocol.lastRequest?.url?.path == "/platform/tree/child-and-parents-relationships/RRRR-RRR/source-references")
        #expect(FSMockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-fs-v1+json")
    }

    // MARK: Rejection surfacing

    @Test func writeRejectionSurfacesStatusAndBodySnippet() async {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 400, body: Data(#"{"errors":[{"message":"groupIds is required"}]}"#.utf8))
        do {
            _ = try await client().createTree(body: Data("{}".utf8))
            Issue.record("expected unexpectedStatus")
        } catch let FamilySearchClientError.unexpectedStatus(status, snippet) {
            #expect(status == 400)
            #expect(snippet.contains("groupIds is required"))   // FS's diagnostic survives
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

/// In-memory token source (private to this suite; the sibling suite's fake is
/// file-private there).
private final class WriteFakeTokenSource: FamilySearchTokenSource, @unchecked Sendable {
    private let bearer: String?
    init(bearer: String?) { self.bearer = bearer }
    func currentBearer() async -> String? { bearer }
    func refreshBearer() async -> String? { nil }
}
