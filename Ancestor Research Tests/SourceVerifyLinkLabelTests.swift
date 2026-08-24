import Testing
import Foundation
@testable import Ancestor_Research

/// The link label names where the link GOES. An internal producer id must
/// never surface as a destination (owner dogfood 2026-08-24: a button
/// reading "View on FIELD-RESEARCHER" for a FamilySearch citation).
@MainActor
struct SourceVerifyLinkLabelTests {

    @Test func internalProducerLabelsByTheURLHost() throws {
        let info = try #require(SourceVerifyLink.info(
            sourceID: "field-researcher",
            citationURL: "https://www.familysearch.org/ark:/61903/1:1:VBX7-WGP"))
        #expect(info.label == "View on familysearch.org ↗")
    }

    @Test func knownSourcesKeepTheirNames() throws {
        let info = try #require(SourceVerifyLink.info(
            sourceID: "freereg",
            citationURL: "https://www.freereg.org.uk/search_records/abc"))
        #expect(info.label == "View on FreeREG ↗")
    }

    @Test func unknownSourceWithNoURLFallsBackToTheID() {
        #expect(SourceVerifyLink.displayName("field-researcher") == "FIELD-RESEARCHER")
    }
}
