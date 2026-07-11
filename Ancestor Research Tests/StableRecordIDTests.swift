import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the stable-record-ID behaviour for FreeREG and Wirksworth
/// (connector-audit FT-16).
///
/// Both connectors previously built record IDs from `String.hashValue`
/// (`"freereg_\(name.hashValue)_\(date.hashValue)"` and
/// `"wirksworth_\(key.hashValue)"`). Swift's `hashValue` is SipHash with a
/// per-process random seed, so the same parish record got a different ID on
/// every app launch. Record IDs are load-bearing across runs —
/// `record_rejections` is keyed (profile_id, record_id) and
/// `evidence_records` preserves `user_status` on `"<profile>|<source_record_id>"`
/// — so user discard decisions were silently orphaned every launch.
///
/// The fix mirrors FamilySearchSource's stated rule (stable server ID,
/// never hashValue): prefer the server-stable entry ID from the detail URL,
/// else a deterministic SHA256 content digest. Exact digest values are
/// pinned below so a change to the normalisation scheme (which would orphan
/// rows all over again) fails loudly.
nonisolated struct FreeREGStableIDTests {

    /// Row 1 carries a detail link (server-stable entry ID, plus a query
    /// string that must not leak into the ID). Row 2 has no link and must
    /// fall back to the content digest.
    private static let fixtureHTML = """
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td><a href="/search_records/58a1b2c3d4e5f6a7b8c9?search_query=q123">John Cauldwell</a></td><td>15 Mar 1852</td><td>Wirksworth</td><td>Derbyshire</td><td>Baptism</td></tr>
    <tr><td>Mary Cauldwell</td><td>02 Feb 1855</td><td>Duffield</td><td>Derbyshire</td><td>Baptism</td></tr>
    </table>
    """

    @Test func sameParsedRecordGetsSameIDAcrossParseInvocations() {
        let first = FreeREGSource.parseResults(Self.fixtureHTML, recordType: .baptism)
        let second = FreeREGSource.parseResults(Self.fixtureHTML, recordType: .baptism)
        #expect(first.count == 2)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func distinctRecordsGetDistinctIDs() {
        let records = FreeREGSource.parseResults(Self.fixtureHTML, recordType: .baptism)
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == records.count)
    }

    @Test func urlDerivedIDPreferredWhenDetailURLPresent() {
        let records = FreeREGSource.parseResults(Self.fixtureHTML, recordType: .baptism)
        // Row 1 has /search_records/<id>?query — the ID must be the
        // server-stable path segment, query string stripped.
        #expect(records.first?.id == "freereg_58a1b2c3d4e5f6a7b8c9")
    }

    @Test func csvEntriesURLVariantAlsoYieldsPathSegmentID() {
        let html = """
        <table>
        <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
        <tr><td><a href="/freereg1_csv_entries/abc123def456">Thomas Land</a></td><td>1834</td><td>Wirksworth</td><td>Derbyshire</td><td>Baptism</td></tr>
        </table>
        """
        let records = FreeREGSource.parseResults(html, recordType: .baptism)
        #expect(records.first?.id == "freereg_abc123def456")
    }

    /// The fallback digest is a pure function of normalised record content —
    /// pinned to the exact SHA256-derived value so any change to the
    /// normalisation scheme (which would orphan user_status rows keyed on
    /// old IDs) fails this test rather than shipping silently.
    /// SHA256("mary cauldwell|02 feb 1855|duffield|derbyshire|baptism")
    /// first 16 hex chars = 5fc141b72e581f73.
    @Test func fallbackDigestIsDeterministic() {
        let records = FreeREGSource.parseResults(Self.fixtureHTML, recordType: .baptism)
        #expect(records.count == 2)
        #expect(records.last?.id == "freereg_5fc141b72e581f73")
    }

    @Test func stableRecordIDHelperNormalisesCaseAndWhitespace() {
        let a = FreeREGSource.stableRecordID(
            detailURL: nil,
            name: "Mary Cauldwell", date: "02 Feb 1855", parish: "Duffield",
            county: "Derbyshire", eventType: "Baptism"
        )
        let b = FreeREGSource.stableRecordID(
            detailURL: nil,
            name: "  MARY CAULDWELL ", date: "02 FEB 1855", parish: "duffield ",
            county: " DERBYSHIRE", eventType: "baptism"
        )
        #expect(a == b)
        #expect(a == "freereg_5fc141b72e581f73")
    }

    /// A degenerate href whose last path segment is the route name (no
    /// entry ID) must not be mistaken for a server-stable ID — the content
    /// digest takes over.
    @Test func routeOnlyDetailURLFallsBackToDigest() {
        let id = FreeREGSource.stableRecordID(
            detailURL: "https://www.freereg.org.uk/search_records/?q=1",
            name: "Mary Cauldwell", date: "02 Feb 1855", parish: "Duffield",
            county: "Derbyshire", eventType: "baptism"
        )
        #expect(id == "freereg_5fc141b72e581f73")
    }
}

nonisolated struct WirksworthStableIDTests {

    private static let structuredHTML = """
    <PRE>
    1 John Cauldwell b 1750 m (1775) Mary Smith d 1800
    2 Thomas Cauldwell b 1778 m Elizabeth Jones
    </PRE>
    """
    private static let structuredURL = "http://www.wirksworth.org.uk/X999.htm"

    private static let narrativeHTML = "Mary Cauldwell born 1802 in Wirksworth was a lead miner's daughter."
    private static let narrativeURL = "http://www.wirksworth.org.uk/N001.htm"

    @Test func structuredPedigreeIDsStableAcrossParseInvocations() {
        let first = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: Self.structuredURL)
        let second = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: Self.structuredURL)
        #expect(first.count == 2)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func narrativePedigreeIDsStableAcrossParseInvocations() {
        let first = WirksworthSource.parseNarrativePedigree(
            Self.narrativeHTML, surname: "Cauldwell", url: Self.narrativeURL)
        let second = WirksworthSource.parseNarrativePedigree(
            Self.narrativeHTML, surname: "Cauldwell", url: Self.narrativeURL)
        #expect(first.count == 1)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func distinctRecordsGetDistinctIDs() {
        let records = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: Self.structuredURL)
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == records.count)
    }

    /// Same row content on two different pedigree pages must yield distinct
    /// IDs — they are separate evidence pages on the static site.
    @Test func samePersonOnDifferentPagesGetsDistinctIDs() {
        let pageA = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: "http://www.wirksworth.org.uk/A100.htm")
        let pageB = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: "http://www.wirksworth.org.uk/B200.htm")
        #expect(!pageA.isEmpty && pageA.count == pageB.count)
        #expect(Set(pageA.map(\.id)).isDisjoint(with: pageB.map(\.id)))
    }

    /// Pinned digest values: any change to the ID scheme orphans
    /// record_rejections / evidence_records.user_status rows, so it must
    /// fail loudly here.
    /// SHA256("http://www.wirksworth.org.uk/X999.htm|john cauldwell_1750_1")
    /// first 16 hex = e7bd2bcbf687fd8b;
    /// SHA256("http://www.wirksworth.org.uk/N001.htm|mary cauldwell_1802")
    /// first 16 hex = da5272af4511cf0f.
    @Test func digestIsDeterministicAndPageCodePrefixed() {
        let structured = WirksworthSource.parseStructuredPedigree(
            Self.structuredHTML, surname: "Cauldwell", url: Self.structuredURL)
        #expect(structured.first?.id == "wirksworth_X999_e7bd2bcbf687fd8b")

        let narrative = WirksworthSource.parseNarrativePedigree(
            Self.narrativeHTML, surname: "Cauldwell", url: Self.narrativeURL)
        #expect(narrative.first?.id == "wirksworth_N001_da5272af4511cf0f")
    }
}
