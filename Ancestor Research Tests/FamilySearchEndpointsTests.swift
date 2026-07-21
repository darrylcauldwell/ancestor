import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch client — Slice 1. Endpoint URL builders are pinned against the
/// verbatim paths from FamilySearch's official API reference + Bruno example
/// collection, so a drifted host/path or a mis-attached collection value fails
/// loudly before any live call.
struct FamilySearchEndpointsTests {

    private func comps(_ url: URL) -> URLComponents {
        URLComponents(url: url, resolvingAgainstBaseURL: false)!
    }
    private func query(_ url: URL) -> [String: String] {
        Dictionary((comps(url).queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    @Test func recordsPersonaSearchPathAndHostSwap() {
        var q = FamilySearchQuery()
        q.surname = "Cauldwell"
        let beta = FamilySearchEndpoints.recordsPersonaSearch(.beta, q)
        #expect(beta.absoluteString.hasPrefix("https://apibeta.familysearch.org/platform/records/personas?"))
        #expect(query(beta)["q.surname"] == "Cauldwell")
        let prod = FamilySearchEndpoints.recordsPersonaSearch(.production, q)
        #expect(prod.absoluteString.hasPrefix("https://api.familysearch.org/platform/records/personas?"))
    }

    @Test func treeSearchUsesStructuredGrammarNotFreeText() {
        var q = FamilySearchQuery()
        q.givenName = "William"
        q.surname = "Heaton"
        q.treeId = "T1"
        let url = FamilySearchEndpoints.treeSearch(.beta, q)
        #expect(comps(url).path == "/platform/tree/search")
        let m = query(url)
        #expect(m["q.givenName"] == "William")
        #expect(m["q.surname"] == "Heaton")
        #expect(m["f.treeId"] == "T1")
        #expect(m["q"] == nil)   // never the retired q= free-text form
    }

    @Test func personMatchesRecordsCollectionValue() {
        let url = FamilySearchEndpoints.personMatches(.beta, pid: "LZ8X-ABC", collection: .records)
        #expect(comps(url).path == "/platform/tree/persons/LZ8X-ABC/matches")
        #expect(query(url)["collection"] == "https://familysearch.org/platform/collections/records")
    }

    @Test func personMatchesDuplicatesOmitsCollection() {
        let url = FamilySearchEndpoints.personMatches(.beta, pid: "LZ8X-ABC", collection: .duplicates)
        #expect(comps(url).queryItems == nil)
        #expect(url.absoluteString == "https://apibeta.familysearch.org/platform/tree/persons/LZ8X-ABC/matches")
    }

    @Test func batchReadPersonsJoinsPids() {
        let url = FamilySearchEndpoints.readPersons(.beta, pids: ["A", "B", "C"])
        #expect(comps(url).path == "/platform/tree/persons")
        #expect(query(url)["pids"] == "A,B,C")
    }

    @Test func readPersonAndMemoriesAndCurrentUserPaths() {
        #expect(comps(FamilySearchEndpoints.readPerson(.beta, pid: "PID9")).path == "/platform/tree/persons/PID9")
        #expect(comps(FamilySearchEndpoints.personMemories(.beta, pid: "PID9")).path == "/platform/tree/persons/PID9/memories")
        #expect(comps(FamilySearchEndpoints.currentUser(.beta)).path == "/platform/users/current")
    }
}
