import Testing
import Foundation
@testable import Ancestor_Research

/// MergeEdit launcher form rendering (WT2 — WIKITREE_MERGEEDIT_SPEC §1/§5):
/// the Bio↔mergeBio invariant, field encoding, escaping, and the
/// human-in-the-loop shape (visible submit button, WikiTree endpoint).
struct WikiTreeMergeEditLauncherTests {

    private func payload(bio: String? = nil) -> WikiTreeMergeEditPayload {
        WikiTreeMergeEditPayload(
            userName: "Cauldwell-171",
            personFields: ["BirthDate": "1887", "BirthLocation": "Crich, Derbyshire"],
            expectedFields: ["BirthDate": "abt 1888", "BirthLocation": ""],
            bioAppend: bio,
            summary: "Sourced update from Ancestor Research: BirthDate, BirthLocation.",
            manualNotes: [])
    }

    @Test func formTargetsMergeEditWithJSONEncodedFields() throws {
        let html = WikiTreeMergeEditLauncher.reviewPageHTML(for: payload())
        #expect(html.contains(#"action="https://www.wikitree.com/wiki/Special:MergeEdit""#))
        #expect(html.contains(#"method="POST""#))
        #expect(html.contains(#"name="user_name" value="Cauldwell-171""#))
        // person/expected are JSON-encoded values (HTML-escaped quotes).
        #expect(html.contains("&quot;BirthDate&quot;:&quot;1887&quot;"))
        #expect(html.contains("&quot;BirthDate&quot;:&quot;abt 1888&quot;"))
        // Human-in-the-loop: a visible submit control plus the auto-submit.
        #expect(html.contains("<button type=\"submit\""))
        #expect(html.contains(#"document.getElementById("mergeedit").submit()"#))
    }

    @Test func bioNeverTravelsWithoutMergeBio() throws {
        // Without a bio: no Bio field, no options.
        let bare = WikiTreeMergeEditLauncher.reviewPageHTML(for: payload())
        #expect(!bare.contains("Bio"))
        #expect(!bare.contains("mergeBio"))

        // With a bio: Bio inside person AND options.mergeBio = 1, always paired
        // (without mergeBio, MergeEdit REPLACES the entire biography).
        let withBio = WikiTreeMergeEditLauncher.reviewPageHTML(
            for: payload(bio: "=== Research notes ===\n* Birth: 1887"))
        #expect(withBio.contains("&quot;Bio&quot;"))
        #expect(withBio.contains("mergeBio&quot;:1"))
    }

    @Test func wikitextAndURLsAreHTMLEscaped() throws {
        let bio = "* Birth: 1887<ref>\"FreeBMD\", https://freebmd.org.uk/x?a=1&b=2</ref>"
        let html = WikiTreeMergeEditLauncher.reviewPageHTML(for: payload(bio: bio))
        #expect(!html.contains("<ref>"))            // raw wikitext never leaks into markup
        #expect(html.contains("&lt;ref&gt;"))
        #expect(html.contains("a=1&amp;b=2") || html.contains("a=1\\u0026b=2"))
    }

    @Test func summaryFieldCarriesTheProvenanceLine() throws {
        let html = WikiTreeMergeEditLauncher.reviewPageHTML(for: payload())
        #expect(html.contains(#"name="summary""#))
        #expect(html.contains("Sourced update from Ancestor Research"))
    }
}
