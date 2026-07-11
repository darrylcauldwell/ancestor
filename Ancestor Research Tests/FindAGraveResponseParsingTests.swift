import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit §6.3 response-side parsing fixes —
/// CONNECTOR_AUDIT_2026-07.md:
///
/// - T1-23 (response side): structured name keys (firstName /
///   middleName / lastName / maidenName) beat the last-token
///   display-name split; suffix-aware fallback; ambiguous splits
///   flagged for the name gate.
/// - T1-27 (FAG half): records without a valid memorialId are skipped,
///   never collapsed to "findagrave_0".
/// - T1-22 (in-scope slice): "(aged NN)" captured into rawFields
///   before the display-date strip discards it.
/// - T1-19 (in-scope slice): cemetery page URL extracted from the
///   detail page (Python parity, findagrave.py:268-270).
/// - T1-20: Family Members block parsed into structured
///   (relation, name, memorialID, years) tuples — record fields ONLY,
///   per the Evidence Firewall; never relationship writes.
struct FindAGraveResponseParsingTests {

    // MARK: - Fixture helpers

    private func searchBody(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "responseCode": 200,
            "records": records,
        ])
    }

    private func parseOne(_ record: [String: Any]) throws -> BurialRecord? {
        let results = FindAGraveSource.parseSearchResults(try searchBody([record]))
        guard case .burial(let burial)? = results.first else { return nil }
        return burial
    }

    private func memorialHTML(
        title: String = "Ernest Cauldwell (1919 - 2017) - Find a Grave Memorial",
        body: String
    ) -> String {
        """
        <html>
          <head><title>\(title)</title></head>
          <body>
            \(body)
          </body>
        </html>
        """
    }

    // MARK: - T1-23 — structured name keys beat the display-name split

    @Test func structuredNameKeysPreferredOverDisplaySplit() throws {
        // The audit's fixture-corpus example: a compound lastName plus a
        // discrete maidenName. The old last-token split would have
        // yielded surname "Brook-Cauldwell" only by luck of hyphenation;
        // maiden-in-display-name variants mangled entirely.
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Mary Rollins Brook-Cauldwell",
            "firstName": "Mary",
            "lastName": "Brook-Cauldwell",
            "maidenName": "Rollins",
        ])
        #expect(burial?.common.surname == "Brook-Cauldwell")
        #expect(burial?.common.givenName == "Mary")
        // Full display name preserved for the record header.
        #expect(burial?.common.name == "Mary Rollins Brook-Cauldwell")
        // No fallback split happened — nothing ambiguous to flag.
        #expect(burial?.common.rawFields["nameSplitAmbiguous"] == nil)
    }

    @Test func middleNameJoinsGivenName() throws {
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Ernest Victor Cauldwell",
            "firstName": "Ernest",
            "middleName": "Victor",
            "lastName": "Cauldwell",
        ])
        #expect(burial?.common.surname == "Cauldwell")
        #expect(burial?.common.givenName == "Ernest Victor")
    }

    @Test func maidenNameSurvivesInRawFields() throws {
        // The name gate's alternate-surname seam: the stringified
        // payload keeps maidenName verbatim in rawFields.
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Mary Rollins Brook-Cauldwell",
            "firstName": "Mary",
            "lastName": "Brook-Cauldwell",
            "maidenName": "Rollins",
        ])
        #expect(burial?.common.rawFields["maidenName"] == "Rollins")
    }

    @Test func fallbackSuffixNeverBecomesSurname() throws {
        // 'John Smith Jr.' previously yielded surname 'Jr.' — the exact
        // mis-split the audit cites.
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "John Smith Jr.",
        ])
        #expect(burial?.common.surname == "Smith")
        #expect(burial?.common.givenName == "John")
    }

    @Test func fallbackAmbiguousSplitFlagged() throws {
        // Three tokens, no structured keys: middle name, compound
        // surname, and FAG's maiden-in-display-name convention are
        // indistinguishable — flag so the name gate can widen rather
        // than hard-fail.
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Mary Rollins Smith",
        ])
        #expect(burial?.common.surname == "Smith")
        #expect(burial?.common.givenName == "Mary Rollins")
        #expect(burial?.common.rawFields["nameSplitAmbiguous"] == "true")
    }

    @Test func twoTokenFallbackUnflagged() throws {
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Robert Cauldwell",
        ])
        #expect(burial?.common.surname == "Cauldwell")
        #expect(burial?.common.givenName == "Robert")
        #expect(burial?.common.rawFields["nameSplitAmbiguous"] == nil)
    }

    @Test func emptyStructuredKeysFallBackToSplit() throws {
        // Empty-string structured fields must not shadow the display
        // name — treat them as absent.
        let burial = try parseOne([
            "memorialId": 12345,
            "titleName": "Robert Cauldwell",
            "firstName": "",
            "lastName": "  ",
        ])
        #expect(burial?.common.surname == "Cauldwell")
        #expect(burial?.common.givenName == "Robert")
    }

    // MARK: - T1-27 — no stable identity, no record

    @Test func missingMemorialIdSkippedNotZero() throws {
        let results = FindAGraveSource.parseSearchResults(try searchBody([
            ["titleName": "Ghost Entry"],
            ["memorialId": 12345, "titleName": "Robert Cauldwell"],
        ]))
        #expect(results.count == 1)
        #expect(results.allSatisfy { $0.common.id != "findagrave_0" })
        #expect(results.first?.common.id == "findagrave_12345")
    }

    @Test func zeroMemorialIdSkipped() throws {
        let results = FindAGraveSource.parseSearchResults(try searchBody([
            ["memorialId": 0, "titleName": "Ghost Entry"],
        ]))
        #expect(results.isEmpty)
    }

    @Test func numericStringMemorialIdAccepted() throws {
        let results = FindAGraveSource.parseSearchResults(try searchBody([
            ["memorialId": "678", "titleName": "Robert Cauldwell"],
        ]))
        #expect(results.first?.common.id == "findagrave_678")
    }

    // MARK: - T1-22 (slice) — aged captured before the strip

    @Test func agedCapturedIntoRawFieldsAndDateStillStripped() {
        let html = memorialHTML(body: """
            <span itemprop="birthDate">18 Aug 1919</span>
            <span itemprop="deathDate">6 Jan 2017 (aged 97)</span>
            """)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.deathDate == "6 Jan 2017")
        #expect(burial.common.rawFields["aged"] == "97")
    }

    @Test func noAgedSuffixNoRawKey() {
        let html = memorialHTML(body: """
            <span itemprop="birthDate">18 Aug 1919</span>
            <span itemprop="deathDate">6 Jan 2017</span>
            """)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.common.rawFields["aged"] == nil)
    }

    // MARK: - T1-19 (slice) — cemetery URL

    @Test func cemeteryURLExtractedPythonParity() {
        let html = memorialHTML(body: """
            <span itemprop="deathDate">6 Jan 2017</span>
            <a href="/cemetery/2143567/oakwood-cemetery" class="cem-link" itemprop="url"><span itemprop="name">Oakwood Cemetery</span></a>
            """)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.common.rawFields["cemeteryURL"] == "https://www.findagrave.com/cemetery/2143567/oakwood-cemetery")
        // The cemetery NAME path is unchanged.
        #expect(burial.cemetery == "Oakwood Cemetery")
    }

    @Test func noCemeteryAnchorNoURLKey() {
        let html = memorialHTML(body: """
            <span itemprop="deathDate">6 Jan 2017</span>
            """)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.common.rawFields["cemeteryURL"] == nil)
    }

    // MARK: - T1-23 (detail half) — title-name split is suffix-aware

    @Test func detailTitleSuffixStripped() {
        let html = memorialHTML(
            title: "John Smith Jr. (1850 - 1920) - Find a Grave Memorial",
            body: #"<span itemprop="deathDate">1920</span>"#
        )
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.common.surname == "Smith")
        #expect(burial.common.givenName == "John")
    }

    // MARK: - T1-20 — Family Members block

    private var familySectionHTML: String {
        """
        <section id="family-members">
          <h2>Family Members</h2>
          <ul>
            <li><b>Parents</b>
              <a href="/memorial/111/john-smith"><span itemprop="name">John Smith</span> <span>1850&ndash;1920</span></a>
              <a href="/memorial/222/mary-ann-smith"><span itemprop="name">Mary Ann Smith</span> <span>1855–1930</span></a>
            </li>
            <li><b>Spouse</b>
              <a href="/memorial/333/jane-smith"><span itemprop="name">Jane Smith</span> <span>1882–1960</span></a>
            </li>
            <li><b>Children</b>
              <a href="/memorial/444/robert-smith">Robert Smith 1905–1980</a>
            </li>
          </ul>
        </section>
        """
    }

    @Test func familyLinksParsedByGroup() {
        let links = FindAGraveSource.parseFamilyLinks(familySectionHTML)
        #expect(links.count == 4)
        #expect(links.map(\.relation) == ["parent", "parent", "spouse", "child"])
        #expect(links.map(\.memorialID) == [111, 222, 333, 444])
        #expect(links.first?.name == "John Smith")
        // Entity-encoded dash captured verbatim (FAG markup is not
        // consistent about character vs entity).
        #expect(links.first?.years == "1850&ndash;1920")
        #expect(links[1].years == "1855–1930")
        // Fallback (no itemprop) anchor: tag-stripped text minus the span.
        #expect(links[3].name == "Robert Smith")
        #expect(links[3].years == "1905–1980")
    }

    @Test func halfSiblingsDistinctFromSiblings() {
        let html = """
        <section>
          <h2>Family Members</h2>
          <b>Siblings</b>
          <a href="/memorial/555/amy-smith"><span itemprop="name">Amy Smith</span></a>
          <b>Half Siblings</b>
          <a href="/memorial/666/ben-jones"><span itemprop="name">Ben Jones</span></a>
        </section>
        """
        let links = FindAGraveSource.parseFamilyLinks(html)
        #expect(links.map(\.relation) == ["sibling", "halfSibling"])
        // No years shown → nil, not empty string.
        #expect(links.allSatisfy { $0.years == nil })
    }

    @Test func linksBeforeFirstGroupLabelIgnored() {
        let html = """
        <section>
          <h2>Family Members</h2>
          <a href="/memorial/999/sponsored">Sponsored Memorial</a>
          <b>Parents</b>
          <a href="/memorial/111/john-smith"><span itemprop="name">John Smith</span></a>
        </section>
        """
        let links = FindAGraveSource.parseFamilyLinks(html)
        #expect(links.map(\.memorialID) == [111])
    }

    @Test func noFamilySectionYieldsEmpty() {
        let html = memorialHTML(body: #"<span itemprop="deathDate">2017</span>"#)
        #expect(FindAGraveSource.parseFamilyLinks(html).isEmpty)
    }

    @Test func scanBoundedAtSectionClose() {
        // Memorial links elsewhere on the page (suggestion modules,
        // sponsor blocks) must not bleed into the last family group.
        let html = familySectionHTML + """
        <div class="suggestions">
          <a href="/memorial/888/unrelated-person">Unrelated Person 1900–1990</a>
        </div>
        """
        let links = FindAGraveSource.parseFamilyLinks(html)
        #expect(!links.contains { $0.memorialID == 888 })
        #expect(links.count == 4)
    }

    @Test func unknownYearSpanKeptVerbatim() {
        let html = """
        <section>
          <h2>Family Members</h2>
          <b>Children</b>
          <a href="/memorial/777/infant-smith"><span itemprop="name">Infant Smith</span> <span>unknown–1944</span></a>
        </section>
        """
        let links = FindAGraveSource.parseFamilyLinks(html)
        #expect(links.first?.years == "unknown–1944")
        #expect(links.first?.name == "Infant Smith")
    }

    @Test func familyLinksLandInRawFieldsAsJSON() throws {
        // End-to-end through parseMemorialDetail: the block serialises
        // into rawFields["familyLinks"] — record fields only, firewall
        // intact (no relationship writes anywhere in the connector).
        let html = memorialHTML(body: """
            <span itemprop="birthDate">18 Aug 1919</span>
            <span itemprop="deathDate">6 Jan 2017</span>
            \(familySectionHTML)
            """)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        guard let encoded = burial.common.rawFields["familyLinks"] else {
            Issue.record("Expected familyLinks in rawFields")
            return
        }
        let decoded = try JSONDecoder().decode(
            [FindAGraveSource.FamilyLink].self,
            from: Data(encoded.utf8)
        )
        #expect(decoded.count == 4)
        #expect(decoded.map(\.memorialID) == [111, 222, 333, 444])
        #expect(decoded.map(\.relation) == ["parent", "parent", "spouse", "child"])
    }

    @Test func noFamilySectionNoRawFieldsKey() {
        let html = memorialHTML(body: #"<span itemprop="deathDate">2017</span>"#)
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.common.rawFields["familyLinks"] == nil)
    }
}
