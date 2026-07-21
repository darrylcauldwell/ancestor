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
}
