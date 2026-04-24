import Foundation

/// Read-only WikiTree API client using async/await.
/// Implements the two-step clientLogin flow and all read endpoints.
/// All requests include appId per WikiTree App Policies.
/// Rate limited to stay under 200/min, 4000/hour.
/// Sendable wrapper for JSON data crossing actor boundaries.
nonisolated struct JSONPayload: Sendable {
    let data: Data

    func decode() -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = json as? [[String: Any]] { return array }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }
}

actor WikiTreeClient {
    private let apiURL = URL(string: "https://api.wikitree.com/api.php")!
    private let appID = AppConstants.wikiTreeAppID
    private let rateLimitDelay: Duration = .milliseconds(300)
    private var sessionCookies: [HTTPCookie] = []
    private var lastRequestTime: ContinuousClock.Instant?

    static let defaultFields = [
        "Id", "Name", "FirstName", "MiddleName", "LastNameAtBirth",
        "LastNameCurrent", "BirthDate", "BirthDateDecade", "BirthLocation",
        "DeathDate", "DeathDateDecade", "DeathLocation",
        "Gender", "IsLiving",
        "Father", "Mother", "Parents", "Spouses", "Children", "Siblings",
        "Privacy", "Bio",
    ].joined(separator: ",")

    // MARK: - Authentication

    /// Two-step clientLogin: POST credentials → capture authcode → confirm.
    func login(email: String, password: String) async throws -> WikiTreeUser {
        // Step 1: POST credentials — must NOT follow redirects to capture authcode
        let loginParams: [String: String] = [
            "action": "clientLogin",
            "doLogin": "1",
            "wpEmail": email,
            "wpPassword": password,
            "appId": appID,
        ]

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = loginParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        // Use a session that does NOT follow redirects
        let noRedirectDelegate = NoRedirectDelegate()
        let noRedirectSession = URLSession(configuration: .default, delegate: noRedirectDelegate, delegateQueue: nil)
        let (data, response) = try await noRedirectSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WikiTreeError.loginFailed("No HTTP response")
        }

        // Capture cookies from response
        if let headerFields = httpResponse.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: apiURL)
            sessionCookies.append(contentsOf: cookies)
        }

        // Extract authcode — try redirect Location header first, then response body
        var authcode: String?

        // Try Location header (302 redirect)
        if let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            authcode = components.queryItems?.first(where: { $0.name == "authcode" })?.value
        }

        // Try response body (some WikiTree versions return authcode in JSON body)
        if authcode == nil, let bodyStr = String(data: data, encoding: .utf8) {
            // Look for authcode in URL-like string in body
            if let range = bodyStr.range(of: "authcode=") {
                let after = bodyStr[range.upperBound...]
                let code = after.prefix(while: { $0 != "&" && $0 != "\"" && $0 != " " && $0 != "\n" })
                if !code.isEmpty {
                    authcode = String(code)
                }
            }
        }

        guard let authcode else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "empty"
            throw WikiTreeError.loginFailed("No authcode. Status=\(httpResponse.statusCode), Body=\(bodyPreview)")
        }

        // Step 2: Confirm with authcode
        let confirmResult: [[String: Any]] = try await post(params: [
            "action": "clientLogin",
            "authcode": authcode,
        ])

        guard let loginData = confirmResult.first?["clientLogin"] as? [String: Any],
              let result = loginData["result"] as? String,
              result.lowercased() == "success" else {
            throw WikiTreeError.loginFailed("Confirmation failed")
        }

        // Verify with watchlist fetch
        let watchlist = try await getWatchlistRaw(limit: 1)
        guard let first = watchlist.first else {
            throw WikiTreeError.loginFailed("Authenticated but watchlist empty")
        }

        return WikiTreeUser(
            id: first["Id"] as? Int ?? 0,
            name: first["Name"] as? String ?? ""
        )
    }

    // MARK: - High-Level API (returns Sendable model types)

    /// Fetch the full watchlist as Profiles + Relationships, ready for snapshot.
    func fetchWatchlistTree(
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> (profiles: [Profile], relationships: [Relationship]) {
        progress?("Fetching watchlist...")
        let watchlistEntries = try await getWatchlistRaw(
            fields: Self.defaultFields
        )
        let wtIDs = watchlistEntries.compactMap { $0["Name"] as? String }

        progress?("Fetching \(wtIDs.count) profiles...")
        let profileData = try await getProfilesRaw(wtIDs)

        progress?("Fetching relationships...")
        let relativeData = try await getRelativesRaw(wtIDs)

        let profiles = profileData.compactMap { Self.convertProfile($0) }
        let relationships = Self.buildRelationships(from: profiles, relativeData: relativeData)

        return (profiles, relationships)
    }

    // MARK: - Raw API Methods (internal, returns non-Sendable dicts)

    private func getProfileRaw(_ wtID: String) async throws -> [String: Any]? {
        let result = try await post(params: [
            "action": "getProfile",
            "key": wtID,
            "fields": Self.defaultFields,
            "bioFormat": "wiki",
        ])
        return result.first?["profile"] as? [String: Any]
    }

    private func getProfilesRaw(_ wtIDs: [String]) async throws -> [[String: Any]] {
        var allProfiles: [[String: Any]] = []
        for batchStart in stride(from: 0, to: wtIDs.count, by: 1000) {
            let batchEnd = min(batchStart + 1000, wtIDs.count)
            let batch = wtIDs[batchStart..<batchEnd]
            let result = try await post(params: [
                "action": "getPeople",
                "keys": batch.joined(separator: ","),
                "fields": Self.defaultFields,
                "bioFormat": "wiki",
            ])
            if let people = result.first?["people"] as? [String: Any] {
                for (_, value) in people {
                    if let profile = value as? [String: Any], profile["Name"] != nil {
                        allProfiles.append(profile)
                    }
                }
            }
            await rateLimit()
        }
        return allProfiles
    }

    private func getWatchlistRaw(
        limit: Int? = nil,
        fields: String = "Id,Name,FirstName,LastNameAtBirth,BirthDate"
    ) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var offset = 0
        let pageSize = 1000
        while true {
            let result = try await post(params: [
                "action": "getWatchlist",
                "limit": "\(pageSize)",
                "offset": "\(offset)",
                "fields": fields,
                "getPerson": "1",
            ])
            guard let watchlist = result.first?["watchlist"] as? [[String: Any]], !watchlist.isEmpty else { break }
            results.append(contentsOf: watchlist)
            if watchlist.count < pageSize { break }
            offset += pageSize
            if let limit, results.count >= limit { break }
            await rateLimit()
        }
        if let limit { return Array(results.prefix(limit)) }
        return results
    }

    private func getRelativesRaw(_ wtIDs: [String]) async throws -> [[String: Any]] {
        var allResults: [[String: Any]] = []
        // Batch relatives requests to avoid overloading
        for batchStart in stride(from: 0, to: wtIDs.count, by: 100) {
            let batchEnd = min(batchStart + 100, wtIDs.count)
            let batch = Array(wtIDs[batchStart..<batchEnd])
            let result = try await post(params: [
                "action": "getRelatives",
                "keys": batch.joined(separator: ","),
                "getParents": "1",
                "getChildren": "1",
                "getSpouses": "1",
            ])
            allResults.append(contentsOf: result)
            await rateLimit()
        }
        return allResults
    }

    // MARK: - Network

    private func post(params: [String: String]) async throws -> [[String: Any]] {
        var fullParams = params
        fullParams["appId"] = appID
        fullParams["format"] = "json"

        let (data, _) = try await postRaw(params: fullParams)
        let json = try JSONSerialization.jsonObject(with: data)

        if let array = json as? [[String: Any]] {
            return array
        } else if let dict = json as? [String: Any] {
            return [dict]
        }
        return []
    }

    private func postRaw(params: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        // Add session cookies
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: sessionCookies)
        for (key, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        // Capture response cookies
        if let httpResponse = response as? HTTPURLResponse,
           let headerFields = httpResponse.allHeaderFields as? [String: String] {
            let newCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: apiURL)
            for cookie in newCookies {
                sessionCookies.removeAll { $0.name == cookie.name }
                sessionCookies.append(cookie)
            }
        }

        return (data, response)
    }

    private func rateLimit() async {
        if let last = lastRequestTime {
            let elapsed = ContinuousClock.now - last
            if elapsed < rateLimitDelay {
                try? await Task.sleep(for: rateLimitDelay - elapsed)
            }
        }
        lastRequestTime = .now
    }
}

// MARK: - Types

/// Prevents URLSession from following redirects — needed to capture
/// the authcode from WikiTree's clientLogin redirect.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Return nil to stop the redirect — we want the 302 response
        completionHandler(nil)
    }
}

nonisolated struct WikiTreeUser: Sendable {
    let id: Int
    let name: String
}

nonisolated enum WikiTreeError: Error, LocalizedError {
    case loginFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .loginFailed(let detail): "WikiTree login failed: \(detail)"
        case .notAuthenticated: "Not logged in to WikiTree"
        }
    }
}

// MARK: - Profile Conversion

extension WikiTreeClient {

    /// Convert a WikiTree API profile dict into our Profile model.
    static func convertProfile(_ data: [String: Any]) -> Profile? {
        guard let name = data["Name"] as? String else { return nil }

        let firstName = data["FirstName"] as? String
        let lastName = data["LastNameAtBirth"] as? String
        let genderStr = data["Gender"] as? String
        let gender: Gender? = switch genderStr {
        case "Male": .male
        case "Female": .female
        default: nil
        }

        let birthDateStr = data["BirthDate"] as? String
        let birthDate = birthDateStr.flatMap { str in
            str.isEmpty || str == "0000-00-00" ? nil : GenealogicalDate(parsing: str)
        }
        let birthLocation = data["BirthLocation"] as? String
        let deathDateStr = data["DeathDate"] as? String
        let deathDate = deathDateStr.flatMap { str in
            str.isEmpty || str == "0000-00-00" ? nil : GenealogicalDate(parsing: str)
        }
        let deathLocation = data["DeathLocation"] as? String
        let bio = data["Bio"] as? String

        let now = Date()
        var sources: [ProfileField: [FieldSource]] = [:]
        let origin = SourceOrigin.wikitree

        if let fn = firstName {
            sources[.firstName] = [FieldSource(origin: origin, raw: fn, addedAt: now)]
        }
        if let ln = lastName {
            sources[.lastName] = [FieldSource(origin: origin, raw: ln, addedAt: now)]
        }
        if let bd = birthDateStr, !bd.isEmpty, bd != "0000-00-00" {
            sources[.birthDate] = [FieldSource(origin: origin, raw: bd, addedAt: now)]
        }
        if let bl = birthLocation, !bl.isEmpty {
            sources[.birthLocation] = [FieldSource(origin: origin, raw: bl, addedAt: now)]
        }
        if let dd = deathDateStr, !dd.isEmpty, dd != "0000-00-00" {
            sources[.deathDate] = [FieldSource(origin: origin, raw: dd, addedAt: now)]
        }
        if let dl = deathLocation, !dl.isEmpty {
            sources[.deathLocation] = [FieldSource(origin: origin, raw: dl, addedAt: now)]
        }

        return Profile(
            id: name,
            externalIDs: ["wikitree": name],
            firstName: firstName,
            lastName: lastName,
            gender: gender,
            birthDate: birthDate,
            birthLocation: (birthLocation?.isEmpty ?? true) ? nil : birthLocation,
            deathDate: deathDate,
            deathLocation: (deathLocation?.isEmpty ?? true) ? nil : deathLocation,
            bio: (bio?.isEmpty ?? true) ? nil : bio,
            sources: sources,
            disputes: [:]
        )
    }

    /// Build relationships from WikiTree API relative data.
    static func buildRelationships(from profiles: [Profile], relativeData: [[String: Any]]) -> [Relationship] {
        var relationships: [Relationship] = []
        let profileIDs = Set(profiles.map(\.id))

        for entry in relativeData {
            guard let items = entry["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let person = item["person"] as? [String: Any],
                      let personName = person["Name"] as? String,
                      profileIDs.contains(personName) else { continue }

                _ = profiles.first { $0.id == personName } // Available for future use

                // Parents
                if let parents = person["Parents"] as? [String: Any] {
                    for (_, parentData) in parents {
                        guard let parentDict = parentData as? [String: Any],
                              let parentName = parentDict["Name"] as? String,
                              profileIDs.contains(parentName) else { continue }

                        let parentGender = parentDict["Gender"] as? String
                        let role: ParentRole = switch parentGender {
                        case "Male": .father
                        case "Female": .mother
                        default: .unspecified
                        }

                        // Avoid duplicate edges
                        let exists = relationships.contains {
                            $0.type == .parent && $0.from == parentName && $0.to == personName
                        }
                        if !exists {
                            relationships.append(Relationship(
                                id: UUID(), from: parentName, to: personName,
                                type: .parent, role: role, subtype: .unknown,
                                marriageDate: nil, divorceDate: nil
                            ))
                        }
                    }
                }

                // Spouses
                if let spouses = person["Spouses"] as? [String: Any] {
                    for (_, spouseData) in spouses {
                        guard let spouseDict = spouseData as? [String: Any],
                              let spouseName = spouseDict["Name"] as? String,
                              profileIDs.contains(spouseName) else { continue }

                        // Only add one direction
                        let exists = relationships.contains {
                            $0.type == .spouse &&
                            (($0.from == personName && $0.to == spouseName) ||
                             ($0.from == spouseName && $0.to == personName))
                        }
                        if !exists {
                            let marriageDateStr = spouseDict["marriage_date"] as? String
                            let marriageDate = marriageDateStr.flatMap { str in
                                str.isEmpty || str == "0000-00-00" ? nil : GenealogicalDate(parsing: str)
                            }
                            relationships.append(Relationship(
                                id: UUID(), from: personName, to: spouseName,
                                type: .spouse, role: nil, subtype: .unknown,
                                marriageDate: marriageDate, divorceDate: nil
                            ))
                        }
                    }
                }
            }
        }

        return relationships
    }
}
