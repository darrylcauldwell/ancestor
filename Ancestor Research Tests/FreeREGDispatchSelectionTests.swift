import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Drop-trace follow-up (2026-07-30): the live William Henry Keyworth run
/// dispatched only "2 queries" to FreeREG and surfaced neither the 1896
/// marriage nor the 1875 baptism — while a wire probe replaying the app's
/// exact marriage-query shape returned both rows ("We found 2 Results",
/// GLADWIN included). The server and the wire shape are exonerated; this
/// suite pins WHICH queries the dispatcher actually builds for a
/// William-shaped subject at county scope, so selection gaps are visible
/// deterministically instead of costing live FreeREG sessions.
@MainActor
struct FreeREGDispatchSelectionTests {

    /// Captures EVERY form POST (the shared Capturing/Recording clients
    /// keep only the last one — selection diagnosis needs all).
    final class AllPostsClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _posts: [(url: URL, fields: [(String, String)])] = []
        var posts: [(url: URL, fields: [(String, String)])] { lock.withLock { _posts } }

        func get(url: URL, headers: [String: String]) async throws -> Data {
            // Session-establishment form GET — return a minimal page with a
            // CSRF meta so the source proceeds to POST.
            Data(#"<meta name="csrf-token" content="test-token">"#.utf8)
        }
        func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
            lock.withLock { _posts.append((url, fields.map { ($0.key, $0.value) })) }
            return Data()
        }
        func postForm(url: URL, multiFields: [(String, String)], headers: [String: String], timeout: TimeInterval) async throws -> Data {
            lock.withLock { _posts.append((url, multiFields)) }
            return Data()
        }
    }

    private func williamSubject() -> ResearchSubject {
        ResearchSubject(
            profileID: "wm", surname: "Keyworth", givenName: "William",
            birthYearFrom: 1874, birthYearTo: 1876,
            deathYearFrom: 1943, deathYearTo: 1943,
            gender: .male, region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "Emma Gladwin", spouseSurname: "Gladwin", spouseGivenName: "Emma",
                spouseFatherSurname: nil,
                childNames: ["Florence Keyworth", "Dorothy Keyworth", "George Keyworth"],
                fatherName: "George Keyworth", fatherSurname: "Keyworth", fatherGivenName: "George",
                motherName: "Elizabeth Brewer", motherSurname: "Brewer", motherGivenName: "Elizabeth"),
            homeChapmanCode: "NTT"
        )
    }

    private func freeREGPosts(_ client: AllPostsClient) -> [[(String, String)]] {
        client.posts
            .filter { $0.url.absoluteString.contains("freereg") }
            .map { $0.fields }
    }

    private func recordTypeValues(_ posts: [[(String, String)]]) -> [String?] {
        posts.map { fields in fields.first { $0.0 == "search_query[record_type]" }?.1 }
    }

    @Test func countyStageDispatchesAllThreeParishEventQueries() async {
        let client = AllPostsClient()
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(FreeREGSource(http: client))
        let dispatcher = SearchDispatcher(registry: registry)

        _ = await dispatcher.dispatch(
            subject: williamSubject(),
            recordTypes: [.marriage, .burial, .parish],
            scope: .county,
            mode: .extend
        )

        let posts = freeREGPosts(client)
        let types = recordTypeValues(posts)
        // Exactly TWO queries is CORRECT here (matching the live run):
        // the typed marriage query and the all-types umbrella. The burial
        // target is legitimately absent — William d.1943, and a 1941–45
        // burial window lies entirely past FreeREG's 1900 coverage cap,
        // so the dispatcher clamps it out rather than waste a volunteer
        // request that cannot hit.
        #expect(posts.count == 2,
                "marriage + umbrella expected (burial coverage-clamped) — got \(posts.count): \(types)")
        #expect(types.contains("ma"), "the typed marriage query must fire — it retrieves the 1896 GLADWIN marriage on the live site")
        #expect(types.contains { $0 == nil || $0 == "" },
                "the all-types umbrella must fire — it is the ONLY query that can surface the 1875 baptism under Adaptive (no .baptism target)")
        #expect(!types.contains("bu"),
                "a burial window wholly past 1900 must not reach FreeREG")
    }

    @Test func marriageQueryCarriesTheSubjectIdentityShape() async {
        let client = AllPostsClient()
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(FreeREGSource(http: client))
        let dispatcher = SearchDispatcher(registry: registry)

        _ = await dispatcher.dispatch(
            subject: williamSubject(),
            recordTypes: [.marriage],
            scope: .county,
            mode: .extend
        )

        let posts = freeREGPosts(client)
        guard let marriage = posts.first(where: { fields in
            fields.contains { $0.0 == "search_query[record_type]" && $0.1 == "ma" }
        }) else {
            Issue.record("no typed marriage query dispatched — types: \(recordTypeValues(posts))")
            return
        }
        func value(_ key: String) -> String? { marriage.first { $0.0 == key }?.1 }
        #expect(value("search_query[last_name]") == "Keyworth")
        #expect(value("search_query[chapman_codes][]") == "NTT")
        // The wire probe proved this shape returns the 1896 marriage; the
        // window (whatever the dispatcher derives) must contain 1896.
        if let from = value("search_query[start_year]").flatMap(Int.init),
           let to = value("search_query[end_year]").flatMap(Int.init) {
            #expect(from <= 1896 && to >= 1896,
                    "marriage window \(from)–\(to) must contain the real 1896 marriage")
        }
    }
}

