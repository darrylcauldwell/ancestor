import Foundation

/// Verifies a live FamilySearch OAuth session by calling the authenticated
/// `/platform/users/current` endpoint — the smallest authenticated read that
/// proves the Bearer token works against the API. This is the live-handshake
/// check for the FamilySearch pivot (owner 2026-07-21): once sign-in +
/// verify pass on Beta, the enrichment/Tree-API integration is built on top of
/// the same OAuth foundation.
///
/// The URL build and response parse are pure and unit-tested; only `verify`
/// touches the network.
nonisolated enum FamilySearchConnection {

    struct CurrentUser: Sendable, Equatable {
        let id: String
        let displayName: String
    }

    enum ProbeResult: Sendable, Equatable {
        /// No valid (non-expired) token — the user must sign in first.
        case notSignedIn
        /// The token authenticated and the API returned the current user.
        case connected(CurrentUser)
        /// The call reached the API but failed (auth rejected, HTTP error,
        /// unexpected shape, or a transport error when `status` is nil).
        case failed(status: Int?, detail: String)
    }

    /// The authenticated current-user endpoint for the environment.
    static func currentUserURL(environment: FamilySearchEnvironment) -> URL {
        URL(string: "https://\(environment.apiHost)/platform/users/current")!
    }

    /// Parse the `/platform/users/current` JSON into the first user. FamilySearch
    /// returns `{ "users": [{ "id", "contactName", "displayName", … }] }`.
    /// nil on shape mismatch (the caller reports a parse failure).
    static func parseCurrentUser(_ data: Data) -> CurrentUser? {
        struct Envelope: Decodable {
            let users: [User]?
            struct User: Decodable {
                let id: String?
                let contactName: String?
                let displayName: String?
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let user = envelope.users?.first else { return nil }
        let name = [user.contactName, user.displayName, user.id]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "FamilySearch user"
        return CurrentUser(id: user.id ?? "", displayName: name)
    }

    /// Live check: load the stored token for `environment` and GET the current
    /// user. Never throws — every outcome is a `ProbeResult` for the UI.
    static func verify(
        environment: FamilySearchEnvironment = .beta,
        store: FamilySearchTokenStore = .shared,
        session: URLSession = .shared
    ) async -> ProbeResult {
        guard let token = await store.validAccessToken(environment: environment) else {
            return .notSignedIn
        }
        var request = URLRequest(url: currentUserURL(environment: environment))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                return .failed(status: status, detail: "HTTP \(status.map(String.init) ?? "error")")
            }
            guard let user = parseCurrentUser(data) else {
                return .failed(status: 200, detail: "Unexpected response shape")
            }
            return .connected(user)
        } catch {
            return .failed(status: nil, detail: error.localizedDescription)
        }
    }
}
