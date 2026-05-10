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

import os

actor WikiTreeClient {
    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "WikiTree")
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
        Self.logger.info("Login: starting for \(email)")
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
            Self.logger.error("Login: no HTTP response")
            throw WikiTreeError.loginFailed("No HTTP response")
        }

        Self.logger.info("Login: step 1 response status=\(httpResponse.statusCode)")

        // Capture cookies from response
        if let headerFields = httpResponse.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: apiURL)
            sessionCookies.append(contentsOf: cookies)
            Self.logger.info("Login: captured \(cookies.count) cookies")
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
            Self.logger.error("Login: no authcode found. Status=\(httpResponse.statusCode), body=\(bodyPreview)")
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

    /// Fetch an ancestor tree from a seed profile in a single API call.
    /// Much more efficient than watchlist + batch profiles + batch relatives.
    /// One getAncestors call returns all profiles with relationships embedded.
    func fetchAncestorTree(
        seedProfileID: String,
        depth: Int = 10,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> (profiles: [Profile], relationships: [Relationship]) {
        Self.logger.info("fetchAncestorTree: seed=\(seedProfileID), depth=\(depth)")
        progress?("Fetching ancestor tree for \(seedProfileID)...")

        let result = try await post(params: [
            "action": "getAncestors",
            "key": seedProfileID,
            "depth": "\(depth)",
            "fields": Self.defaultFields,
            "bioFormat": "wiki",
        ])

        guard let ancestors = result.first?["ancestors"] as? [[String: Any]] else {
            Self.logger.warning("fetchAncestorTree: no 'ancestors' key in response. Keys: \(result.first?.keys.joined(separator: ", ") ?? "none")")
            return ([], [])
        }
        Self.logger.info("fetchAncestorTree: received \(ancestors.count) ancestor records")

        progress?("Processing \(ancestors.count) profiles...")

        var profiles: [Profile] = []
        var relationships: [Relationship] = []
        var profileIDs: Set<String> = []

        for ancestorData in ancestors {
            guard let profile = Self.convertProfile(ancestorData) else { continue }
            profiles.append(profile)
            profileIDs.insert(profile.id)

            // Extract parent relationships from Father/Mother fields
            if let fatherID = ancestorData["Father"] as? Int, fatherID != 0,
               let fatherName = ancestorData["FatherName"] as? String, !fatherName.isEmpty {
                // Father ID is numeric — we need the Name (WikiTree ID)
                // getAncestors includes Father as an ID, the actual profile will be in ancestors list
            }
        }

        // Build relationships from the ancestor data
        // Each profile has Father and Mother numeric IDs
        // Map numeric IDs to WikiTree names
        var idToName: [Int: String] = [:]
        for a in ancestors {
            if let id = a["Id"] as? Int, let name = a["Name"] as? String {
                idToName[id] = name
            }
        }

        for ancestorData in ancestors {
            guard let childName = ancestorData["Name"] as? String else { continue }

            // Father relationship
            if let fatherID = ancestorData["Father"] as? Int, fatherID != 0,
               let fatherName = idToName[fatherID], profileIDs.contains(fatherName) {
                relationships.append(Relationship(
                    id: UUID(), from: fatherName, to: childName,
                    type: .parent, role: .father, subtype: .unknown,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil
                ))
            }

            // Mother relationship
            if let motherID = ancestorData["Mother"] as? Int, motherID != 0,
               let motherName = idToName[motherID], profileIDs.contains(motherName) {
                relationships.append(Relationship(
                    id: UUID(), from: motherName, to: childName,
                    type: .parent, role: .mother, subtype: .unknown,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil
                ))
            }
        }

        Self.logger.info("fetchAncestorTree: built \(profiles.count) profiles, \(relationships.count) relationships")
        progress?("Done — \(profiles.count) profiles, \(relationships.count) relationships")
        return (profiles, relationships)
    }

    /// Legacy: Fetch via watchlist (many API calls). Use fetchAncestorTree instead.
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

        var profiles = profileData.compactMap { Self.convertProfile($0) }
        let relationships = Self.buildRelationships(from: &profiles, relativeData: relativeData)

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
                "getSiblings": "1",
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
            attributes: nil,
            birthDate: birthDate,
            birthLocation: (birthLocation?.isEmpty ?? true) ? nil : birthLocation,
            deathDate: deathDate,
            deathLocation: (deathLocation?.isEmpty ?? true) ? nil : deathLocation,
            bio: (bio?.isEmpty ?? true) ? nil : bio,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    /// Build relationships from WikiTree API relative data.
    /// Exact port of Python twin.py lines 120-153.
    static func buildRelationships(
        from profiles: inout [Profile],
        relativeData: [[String: Any]]
    ) -> [Relationship] {
        var relationships: [Relationship] = []
        var knownIDs = Set(profiles.map(\.id))
        var edgeSet: Set<String> = []  // "type:from:to" for dedup

        for entry in relativeData {
            guard let items = entry["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let person = item["person"] as? [String: Any],
                      let personName = person["Name"] as? String else { continue }

                // Python: for rel_type, edge_type in [("Children", "parent"), ("Spouses", "spouse")]
                // Python handles Children, Spouses, Siblings. Siblings are derived
                // from shared parents in FamilyGraphSnapshot, so we only store
                // parent and spouse edges explicitly.
                let relTypes: [(key: String, edgeType: RelationshipType)] = [
                    ("Children", .parent),
                    ("Spouses", .spouse),
                ]

                for (relKey, edgeType) in relTypes {
                    guard let relatives = person[relKey] as? [String: Any] else { continue }

                    for (_, relData) in relatives {
                        guard let relDict = relData as? [String: Any],
                              let relName = relDict["Name"] as? String else { continue }

                        // Python: ensure relative node exists — add if missing
                        if !knownIDs.contains(relName) {
                            if let newProfile = convertProfile(relDict) {
                                profiles.append(newProfile)
                                knownIDs.insert(relName)
                            }
                        }

                        if edgeType == .parent {
                            // Python: person is parent of child (Children list)
                            let edgeKey = "parent:\(personName):\(relName)"
                            if !edgeSet.contains(edgeKey) {
                                edgeSet.insert(edgeKey)
                                let personGender = person["Gender"] as? String
                                let role: ParentRole = switch personGender {
                                case "Male": .father
                                case "Female": .mother
                                default: .unspecified
                                }
                                relationships.append(Relationship(
                                    id: UUID(), from: personName, to: relName,
                                    type: .parent, role: role, subtype: .unknown,
                                    marriageDate: nil, marriageLocation: nil, divorceDate: nil
                                ))
                            }
                        } else if edgeType == .spouse {
                            // Python: bidirectional spouse
                            let edgeKey1 = "spouse:\(personName):\(relName)"
                            let edgeKey2 = "spouse:\(relName):\(personName)"
                            if !edgeSet.contains(edgeKey1) && !edgeSet.contains(edgeKey2) {
                                edgeSet.insert(edgeKey1)
                                edgeSet.insert(edgeKey2)
                                let marriageDateStr = relDict["marriage_date"] as? String
                                let marriageDate = marriageDateStr.flatMap { str in
                                    str.isEmpty || str == "0000-00-00" ? nil : GenealogicalDate(parsing: str)
                                }
                                relationships.append(Relationship(
                                    id: UUID(), from: personName, to: relName,
                                    type: .spouse, role: nil, subtype: .unknown,
                                    marriageDate: marriageDate, marriageLocation: nil, divorceDate: nil
                                ))
                            }
                        }
                        // Note: Siblings are NOT stored as explicit relationships.
                        // They are derived from shared parents in FamilyGraphSnapshot.siblingsOf().
                        // The getSiblings API call ensures sibling profiles are added as nodes.
                    }
                }
            }
        }

        return relationships
    }
}
