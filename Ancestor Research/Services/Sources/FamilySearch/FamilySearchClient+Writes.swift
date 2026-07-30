import Foundation

// FamilySearch User Tree write methods (WL1 — FAMILYSEARCH_TREES_WRITE_SPEC).
//
// Thin typed wrappers over `execute`: every method takes a pre-encoded JSON
// body (the WL2 encoder owns body shapes) and returns the created entity's ID
// where one is minted. Media types and paths follow FS_WRITE_WIRE_CONTRACTS.md
// verbatim. Creates REQUIRE an entity ID (upload bookkeeping is built on it);
// attaches tolerate a missing ID (the reference was still created).

// MARK: - Trivial context bodies (transport-owned, not WL2's)

/// `{"trees":[{"id":"…"}]}` — the set-current-tree body and the read-current
/// response share this shape.
nonisolated struct FSTreesContextBody: Codable, Sendable {
    struct TreeRef: Codable, Sendable { let id: String }
    let trees: [TreeRef]
}

extension FamilySearchClient {

    // MARK: Group + tree lifecycle

    /// Create the access-managing group — `POST /platform/groups` → group ID.
    func createGroup(body: Data) async throws -> String {
        try await create(at: FamilySearchEndpoints.groups(environment), body: body, contentType: .fsV1)
    }

    /// Create a user tree — `POST /platform/trees` → tree ID. The body's
    /// `groupIds` must contain exactly one group ID.
    func createTree(body: Data) async throws -> String {
        try await create(at: FamilySearchEndpoints.trees(environment), body: body, contentType: .fsV1)
    }

    /// Read the session's current tree ID — `GET /platform/trees/current`
    /// (`"GLOBAL"` = the shared Family Tree).
    func readCurrentTree() async throws -> String? {
        let response = try await execute(FamilySearchRequest(
            url: FamilySearchEndpoints.treesCurrent(environment)))
        guard (200...299).contains(response.statusCode), !response.body.isEmpty else { return nil }
        return (try? response.decode(FSTreesContextBody.self))?.trees.first?.id
    }

    /// Set the session's current tree — `POST /platform/trees/current` → 204.
    /// The ONLY documented mechanism for targeting writes at a user tree.
    /// Session lifetime is undocumented, so callers re-assert before each batch.
    func setCurrentTree(treeID: String) async throws {
        let body = try JSONEncoder().encode(FSTreesContextBody(trees: [.init(id: treeID)]))
        try await post(at: FamilySearchEndpoints.treesCurrent(environment), body: body, contentType: .fsV1)
    }

    /// Finalize/update a tree (startingPersonId, one-way hidden flip, private
    /// flag) — `POST /platform/trees/{tid}` → 204. Content type is
    /// parameterised because the docs are inconsistent (gedcomx-v1 in the
    /// worked example, fs-v1 on create); the orchestrator falls back on a 400.
    func updateTree(treeID: String, body: Data, contentType: FSMediaType = .gedcomxV1) async throws {
        try await post(at: FamilySearchEndpoints.tree(environment, tid: treeID), body: body, contentType: contentType)
    }

    // MARK: Persons + relationships

    /// Create one person in the CURRENT tree — `POST /platform/tree/persons`
    /// → new person ID (pid). One person per call; no `id` fields in the body.
    func createPerson(body: Data) async throws -> String {
        try await create(at: FamilySearchEndpoints.treePersons(environment), body: body, contentType: .fsV1)
    }

    /// Create a Couple or Child-and-Parents relationship —
    /// `POST /platform/tree/relationships` → relationship ID. The body's
    /// top-level key (`relationships` / `childAndParentsRelationships`)
    /// selects the type; both persons must live in the same tree space.
    func createRelationship(body: Data) async throws -> String {
        try await create(at: FamilySearchEndpoints.treeRelationships(environment), body: body, contentType: .fsV1)
    }

    // MARK: Sources

    /// Create a source description — `POST /platform/sources/descriptions`
    /// → description ID (create once, reference from many).
    func createSourceDescription(body: Data) async throws -> String {
        try await create(at: FamilySearchEndpoints.sourceDescriptions(environment), body: body, contentType: .gedcomxV1)
    }

    /// Attach source references to a person — `POST` to the person resource
    /// itself with a `persons[].sources[]` body.
    @discardableResult
    func attachPersonSources(pid: String, body: Data) async throws -> String? {
        try await attach(at: FamilySearchEndpoints.personSourceReferences(environment, pid: pid),
                         body: body, contentType: .gedcomxV1)
    }

    /// Attach source references to a couple relationship.
    @discardableResult
    func attachCoupleSources(relationshipID: String, body: Data) async throws -> String? {
        try await attach(at: FamilySearchEndpoints.coupleSourceReferences(environment, rid: relationshipID),
                         body: body, contentType: .gedcomxV1)
    }

    /// Attach source references to a child-and-parents relationship
    /// (x-fs-v1 — the FS extension resource, unlike the other two).
    @discardableResult
    func attachChildAndParentsSources(relationshipID: String, body: Data) async throws -> String? {
        try await attach(at: FamilySearchEndpoints.childAndParentsSourceReferences(environment, rid: relationshipID),
                         body: body, contentType: .fsV1)
    }

    // MARK: - Shared write plumbing

    /// POST expecting a created entity: any 2xx WITH an ID succeeds; a 2xx
    /// without one is unusable for bookkeeping and fails loudly.
    private func create(at url: URL, body: Data, contentType: FSMediaType) async throws -> String {
        let response = try await executeWrite(url: url, body: body, contentType: contentType)
        guard let id = response.createdEntityID else {
            throw FamilySearchClientError.unexpectedStatus(
                response.statusCode, "create succeeded but no X-entity-id/Location ID")
        }
        return id
    }

    /// POST expecting 2xx with no entity requirement (204-style updates).
    private func post(at url: URL, body: Data, contentType: FSMediaType) async throws {
        _ = try await executeWrite(url: url, body: body, contentType: contentType)
    }

    /// POST for source references: 2xx succeeds; the reference ID is captured
    /// when the server provides one but its absence is not an error.
    private func attach(at url: URL, body: Data, contentType: FSMediaType) async throws -> String? {
        try await executeWrite(url: url, body: body, contentType: contentType).createdEntityID
    }

    private func executeWrite(url: URL, body: Data, contentType: FSMediaType) async throws -> FamilySearchResponse {
        let response = try await execute(FamilySearchRequest(
            url: url, method: "POST", contentType: contentType, body: body))
        guard (200...299).contains(response.statusCode) else {
            let snippet = String(decoding: response.body.prefix(400), as: UTF8.self)
            throw FamilySearchClientError.unexpectedStatus(response.statusCode, snippet)
        }
        return response
    }
}
