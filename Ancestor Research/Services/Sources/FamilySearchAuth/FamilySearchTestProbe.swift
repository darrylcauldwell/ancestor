import Foundation
import os

/// Developer-only probe used by the Settings "Test session" button to
/// verify that cookies captured by FamilySearchAuthView actually authorise
/// a real search request. This file goes away once FamilySearchSource lands.
enum FamilySearchTestProbe {
    private static let searchURL = URL(string: "https://www.familysearch.org/service/search/hr/v2/personas?q.surname=Cauldwell&count=1")!
    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchTestProbe")

    struct Outcome: Sendable {
        let success: Bool
        let httpStatus: Int?
        let resultCount: Int?
        let totalCount: Int?
        let snippet: String?
        let error: String?
    }

    static func run() async -> Outcome {
        guard let cookieHeader = await FamilySearchCookieStore.shared.cookieHeader() else {
            return Outcome(
                success: false, httpStatus: nil,
                resultCount: nil, totalCount: nil,
                snippet: nil, error: "No stored cookies — sign in first"
            )
        }

        var request = URLRequest(url: searchURL)
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.familysearch.org/en/search/record/results", forHTTPHeaderField: "Referer")
        // Safari UA mirrors what the Python plugin sends; some FamilySearch
        // endpoints reject default URLSession UAs as bots.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("FamilySearch probe: HTTP \(status), \(data.count) bytes")

            if status != 200 {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-text response>"
                return Outcome(
                    success: false, httpStatus: status,
                    resultCount: nil, totalCount: nil,
                    snippet: snippet, error: "HTTP \(status)"
                )
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let entries = json?["entries"] as? [Any]
            let total = json?["results"] as? Int
            let snippet = String(data: data.prefix(200), encoding: .utf8)

            return Outcome(
                success: true, httpStatus: status,
                resultCount: entries?.count,
                totalCount: total,
                snippet: snippet, error: nil
            )
        } catch {
            return Outcome(
                success: false, httpStatus: nil,
                resultCount: nil, totalCount: nil,
                snippet: nil, error: error.localizedDescription
            )
        }
    }
}
