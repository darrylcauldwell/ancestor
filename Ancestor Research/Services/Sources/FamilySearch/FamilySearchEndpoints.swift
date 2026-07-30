import Foundation

/// Which collection to request from the tree-person matches endpoint.
///
/// `records` returns FamilySearch's historical-record hints (source suggestions
/// carrying ARKs — the enrichment value); omitting the collection (`duplicates`)
/// returns possible-duplicate tree-person matches. The collection value is the
/// full FamilySearch collection URI, per the official Bruno example collection.
nonisolated enum FamilySearchMatchCollection: Sendable, Equatable {
    case records
    case duplicates

    /// The `collection` query value, or nil to omit (duplicate matches is the
    /// endpoint's default when no collection is given).
    var queryValue: String? {
        switch self {
        case .records: "https://familysearch.org/platform/collections/records"
        case .duplicates: nil
        }
    }
}

/// Pure URL builders for the FamilySearch Platform API endpoints we consume.
///
/// Hosts come from `FamilySearchEnvironment` (shared with the OAuth stack); the
/// platform base is `https://<apiHost>/platform`. Paths are grounded in the
/// official API reference and the FamilySearch Bruno example collection — cited
/// per method. Network execution belongs to `FamilySearchClient` (a later
/// slice); these builders are pure so the wire contract is unit-testable
/// without a token. See `AncestorApp/FAMILYSEARCH_CLIENT_SPEC.md`.
nonisolated enum FamilySearchEndpoints {

    private static func base(_ environment: FamilySearchEnvironment) -> URLComponents {
        URLComponents(string: "https://\(environment.apiHost)/platform")!
    }

    private static func url(
        _ environment: FamilySearchEnvironment,
        path: String,
        items: [URLQueryItem] = []
    ) -> URL {
        var comps = base(environment)
        comps.path += path
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url!
    }

    /// Historical-record persona search — `GET /platform/records/personas`
    /// (official *Record Persona Search* resource).
    static func recordsPersonaSearch(_ environment: FamilySearchEnvironment, _ query: FamilySearchQuery) -> URL {
        url(environment, path: "/records/personas", items: query.queryItems())
    }

    /// Family Tree person search — `GET /platform/tree/search`
    /// (FamilySearch Bruno "Search User Tree"; `f.treeId` scopes a user tree).
    static func treeSearch(_ environment: FamilySearchEnvironment, _ query: FamilySearchQuery) -> URL {
        url(environment, path: "/tree/search", items: query.queryItems())
    }

    /// Record/duplicate hints for a tree person —
    /// `GET /platform/tree/persons/{pid}/matches`.
    /// `collection=…/records` ⇒ historical-record hints; omitted ⇒ duplicates.
    static func personMatches(
        _ environment: FamilySearchEnvironment,
        pid: String,
        collection: FamilySearchMatchCollection = .records
    ) -> URL {
        let items = collection.queryValue.map { [URLQueryItem(name: "collection", value: $0)] } ?? []
        return url(environment, path: "/tree/persons/\(pid)/matches", items: items)
    }

    /// Read one tree person — `GET /platform/tree/persons/{pid}`.
    static func readPerson(_ environment: FamilySearchEnvironment, pid: String) -> URL {
        url(environment, path: "/tree/persons/\(pid)")
    }

    /// Batch-read tree persons — `GET /platform/tree/persons?pids=a,b,c`.
    static func readPersons(_ environment: FamilySearchEnvironment, pids: [String]) -> URL {
        url(environment, path: "/tree/persons", items: [URLQueryItem(name: "pids", value: pids.joined(separator: ","))])
    }

    /// Memories attached to a tree person —
    /// `GET /platform/tree/persons/{pid}/memories`. Image POINTERS only; the
    /// app never downloads or stores memory content (link-only citation).
    static func personMemories(_ environment: FamilySearchEnvironment, pid: String) -> URL {
        url(environment, path: "/tree/persons/\(pid)/memories")
    }

    /// The authenticated current user — `GET /platform/users/current`
    /// (the connection check the shipped OAuth UI already exercises).
    static func currentUser(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/users/current")
    }

    // MARK: - User Tree write leg (WL1 — paths per FS_WRITE_WIRE_CONTRACTS.md)

    /// Create a group (prerequisite of tree creation) — `POST /platform/groups`.
    static func groups(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/groups")
    }

    /// Create a user tree — `POST /platform/trees` (tree ID in `X-entity-id`).
    static func trees(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/trees")
    }

    /// Session tree context — `GET`/`POST /platform/trees/current`. The ONLY
    /// documented mechanism for targeting person creation at a user tree;
    /// `"GLOBAL"` restores the shared Family Tree.
    static func treesCurrent(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/trees/current")
    }

    /// Update one tree (finalize: startingPersonId / hidden / private) —
    /// `POST /platform/trees/{tid}`.
    static func tree(_ environment: FamilySearchEnvironment, tid: String) -> URL {
        url(environment, path: "/trees/\(tid)")
    }

    /// Create a person in the CURRENT tree — `POST /platform/tree/persons`
    /// (one person per call; targeting is solely via `treesCurrent`).
    static func treePersons(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/tree/persons")
    }

    /// Create a Couple or Child-and-Parents relationship —
    /// `POST /platform/tree/relationships` (the body's top-level key selects
    /// the type: `relationships` vs `childAndParentsRelationships`).
    static func treeRelationships(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/tree/relationships")
    }

    /// Create a source description — `POST /platform/sources/descriptions`
    /// (create once, reference from many persons/relationships).
    static func sourceDescriptions(_ environment: FamilySearchEnvironment) -> URL {
        url(environment, path: "/sources/descriptions")
    }

    /// Attach source references to a person — `POST` to the person resource
    /// ITSELF (`/platform/tree/persons/{pid}`, body `persons[].sources[]`),
    /// not a `/source-references` subpath.
    static func personSourceReferences(_ environment: FamilySearchEnvironment, pid: String) -> URL {
        url(environment, path: "/tree/persons/\(pid)")
    }

    /// Attach source references to a couple relationship —
    /// `POST /platform/tree/couple-relationships/{rid}/source-references`.
    static func coupleSourceReferences(_ environment: FamilySearchEnvironment, rid: String) -> URL {
        url(environment, path: "/tree/couple-relationships/\(rid)/source-references")
    }

    /// Attach source references to a child-and-parents relationship —
    /// `POST /platform/tree/child-and-parents-relationships/{rid}/source-references`
    /// (x-fs-v1 media type — an FS extension resource, unlike the other two).
    static func childAndParentsSourceReferences(_ environment: FamilySearchEnvironment, rid: String) -> URL {
        url(environment, path: "/tree/child-and-parents-relationships/\(rid)/source-references")
    }
}
