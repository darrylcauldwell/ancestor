import Foundation

/// A DIAGNOSTIC spike for the FamilySearch enrichment pivot (owner 2026-07-21).
/// FamilySearch is not a records source; its value is hints/enrichment and
/// document-image pointers via the Tree API. Before designing that integration
/// we need to see what the API actually returns — so this probe hits the
/// best-guess FS Platform API tree endpoints and captures the RAW response.
/// A 4xx with the API's error body is as useful as a 2xx: both teach us the
/// real contract. Everything here is read-only (GET search + GET matches);
/// nothing is contributed/written.
///
/// The URL builders and the light response summariser are pure and unit-tested;
/// only the `search` / `recordHints` calls touch the network.
nonisolated enum FamilySearchTreeProbe {

    struct Outcome: Sendable, Equatable {
        let status: Int?
        /// One-line human summary for the UI header.
        let summary: String
        /// The raw response body (truncated) — the point of the spike.
        let rawBody: String
    }

    // MARK: - URLs

    /// Search the FamilySearch shared TREE for persons. The `q` query-string
    /// syntax (givenName:/surname:/birthLikeDate:) is the documented FS tree
    /// search style; the raw response confirms or corrects it.
    static func treeSearchURL(
        environment: FamilySearchEnvironment,
        givenName: String, surname: String, birthYear: Int?
    ) -> URL {
        var query = "givenName:\"\(givenName)\" surname:\"\(surname)\""
        if let birthYear { query += " birthLikeDate:\"\(birthYear)\"" }
        var comps = URLComponents(string: "https://\(environment.apiHost)/platform/tree/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps.url!
    }

    /// Record hints (potential source matches) for a tree person — the
    /// enrichment payload we most want to see.
    static func recordHintsURL(environment: FamilySearchEnvironment, personID: String) -> URL {
        URL(string: "https://\(environment.apiHost)/platform/tree/persons/\(personID)/matches")!
    }

    // MARK: - Summarise (pure)

    /// Best-effort one-liner: count GEDCOM X `entries` when the shape matches,
    /// otherwise defer to the raw body.
    static func summarize(status: Int?, data: Data) -> String {
        struct Envelope: Decodable {
            let entries: [Entry]?
            struct Entry: Decodable { let id: String? }
        }
        let statusText = status.map { "HTTP \($0)" } ?? "no response"
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let entries = envelope.entries {
            return "\(statusText) — \(entries.count) tree entr\(entries.count == 1 ? "y" : "ies") (see raw)"
        }
        return "\(statusText) — see raw response"
    }

    // MARK: - Network (never throws → always an Outcome)

    static func search(
        environment: FamilySearchEnvironment = .beta,
        givenName: String, surname: String, birthYear: Int?,
        store: FamilySearchTokenStore = .shared,
        session: URLSession = .shared
    ) async -> Outcome {
        await get(
            url: treeSearchURL(environment: environment, givenName: givenName, surname: surname, birthYear: birthYear),
            environment: environment, store: store, session: session)
    }

    static func recordHints(
        environment: FamilySearchEnvironment = .beta,
        personID: String,
        store: FamilySearchTokenStore = .shared,
        session: URLSession = .shared
    ) async -> Outcome {
        await get(
            url: recordHintsURL(environment: environment, personID: personID),
            environment: environment, store: store, session: session)
    }

    private static func get(
        url: URL, environment: FamilySearchEnvironment,
        store: FamilySearchTokenStore, session: URLSession
    ) async -> Outcome {
        guard let token = await store.validAccessToken(environment: environment) else {
            return Outcome(status: nil, summary: "Not signed in", rawBody: "")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            return Outcome(
                status: status,
                summary: summarize(status: status, data: data),
                rawBody: String(body.prefix(6000)))
        } catch {
            return Outcome(status: nil, summary: "Transport error: \(error.localizedDescription)", rawBody: "")
        }
    }
}
