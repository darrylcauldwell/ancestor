import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch enrichment spike (owner 2026-07-21): the Tree-API probe. The
/// network calls are a diagnostic (not unit-tested), but the URL builders and
/// the response summariser are pure and pinned — a drifted endpoint host or a
/// mis-encoded query would silently probe the wrong thing.
struct FamilySearchTreeProbeTests {

    @Test func treeSearchURLTargetsApiBetaWithEncodedQuery() {
        let url = FamilySearchTreeProbe.treeSearchURL(
            environment: .beta, givenName: "Ernest", surname: "Cauldwell", birthYear: 1887)
        #expect(url.absoluteString.hasPrefix("https://apibeta.familysearch.org/platform/tree/search?"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = comps?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "givenName:\"Ernest\" surname:\"Cauldwell\" birthLikeDate:\"1887\"")
    }

    @Test func treeSearchURLOmitsBirthWhenNil() {
        let url = FamilySearchTreeProbe.treeSearchURL(
            environment: .beta, givenName: "Ada", surname: "Smith", birthYear: nil)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        #expect(q == "givenName:\"Ada\" surname:\"Smith\"")
    }

    @Test func recordHintsURLUsesPersonMatchesPath() {
        let url = FamilySearchTreeProbe.recordHintsURL(environment: .beta, personID: "LZ8X-ABC")
        #expect(url.absoluteString == "https://apibeta.familysearch.org/platform/tree/persons/LZ8X-ABC/matches")
        // Production host swaps too.
        let prod = FamilySearchTreeProbe.recordHintsURL(environment: .production, personID: "LZ8X-ABC")
        #expect(prod.absoluteString == "https://api.familysearch.org/platform/tree/persons/LZ8X-ABC/matches")
    }

    @Test func summarizeCountsGedcomxEntries() {
        let json = """
        {"entries":[{"id":"a"},{"id":"b"},{"id":"c"}]}
        """
        #expect(FamilySearchTreeProbe.summarize(status: 200, data: Data(json.utf8))
                == "HTTP 200 — 3 tree entries (see raw)")
    }

    @Test func summarizeSingularAndEmpty() {
        #expect(FamilySearchTreeProbe.summarize(status: 200, data: Data("{\"entries\":[{\"id\":\"a\"}]}".utf8))
                == "HTTP 200 — 1 tree entry (see raw)")
        #expect(FamilySearchTreeProbe.summarize(status: 200, data: Data("{\"entries\":[]}".utf8))
                == "HTTP 200 — 0 tree entries (see raw)")
    }

    /// A non-GEDCOMx body (e.g. a 400 error page) defers to the raw response
    /// rather than misreporting a count.
    @Test func summarizeDefersToRawOnUnexpectedShape() {
        #expect(FamilySearchTreeProbe.summarize(status: 400, data: Data("{\"errors\":[]}".utf8))
                == "HTTP 400 — see raw response")
        #expect(FamilySearchTreeProbe.summarize(status: nil, data: Data("boom".utf8))
                == "no response — see raw response")
    }
}
