import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Pins the FreeCen integrity cluster from the July 2026 connector audit
/// (FT-12, FT-10, FT-15 — shipped together per audit §3).
///
/// - FT-12: record IDs were neither unique nor stable — the search row used a
///   name composite (`freecen_<year>_<surname>_<given>`, colliding across
///   same-name people) and the household-enriched record used a *different*
///   `freecen_detail_…` scheme, so the same record's ID depended on whether
///   the detail fetch succeeded that run. Both now derive from the
///   server-stable `/search_records/<id>` path segment (same idiom as
///   FreeREGSource.stableRecordID, FT-16), with the legacy composite kept as
///   the no-link fallback.
/// - FT-10: household enrichment took `members.first` (the head — FreeCen
///   lists households head-first) as the subject instead of the member the
///   results page marks as "the person found in your search". Python's
///   `is_target` tracking (sources/freecen.py:297-319) is now ported
///   faithfully: the marker's row position is remembered, that member is
///   selected, and first-member is only the no-marker fallback.
/// - FT-15: the household parser dropped the Marital Status, Birth County,
///   Disability and Notes columns (rows 3/7/9/10 of the 11-column table)
///   plus the is_target flag; `HouseholdMember` now carries all five.

// MARK: - Shared fixtures

private nonisolated enum FreeCenFixtures {
    /// Search-results page: two same-name people (distinct detail links —
    /// under the old composite scheme they collapsed to one ID) plus one
    /// row with no detail link (must fall back to the legacy composite).
    /// Row 1's href carries a query string that must not leak into the ID.
    static let searchHTML = """
    We found 3 Results
    <table>
    <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
    <tr><td><a href="/search_records/64ab12cd34ef56?search_query=q1">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Belper</td><td>1850</td><td>1891</td><td>Derbyshire</td><td>Belper</td></tr>
    <tr><td><a href="/search_records/64ab12cd34ef99">View</a></td><td>John Smith</td><td>Lancashire</td><td>Bolton</td><td>1852</td><td>1891</td><td>Lancashire</td><td>Bolton</td></tr>
    <tr><td></td><td>Mary Jones</td><td>Derbyshire</td><td>Duffield</td><td>1860</td><td>1891</td><td>Derbyshire</td><td>Duffield</td></tr>
    </table>
    """

    /// Household detail page for the first search row. The search target
    /// (John, Son, marked "the person found in your search") is the THIRD
    /// member — the head-first listing is exactly the FT-10 trap. The
    /// marker cell keeps FreeCen's real shape: marker text, newline, surname.
    static let householdHTML = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Ecclesiastical Parish</th><th>Piece</th><th>Enumeration District</th><th>Folio</th><th>Page</th><th>Schedule</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>1891</td><td>Derbyshire</td><td>Belper</td><td>Duffield</td><td>St Alkmund</td><td>RG12/2717</td><td>4</td><td>88</td><td>12</td><td>45</td><td>7</td><td>Chapel Street</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>SMITH</td><td>William</td><td>Head</td><td>M</td><td>M</td><td>45</td><td>Farmer</td><td>Derbyshire</td><td>Duffield</td><td></td><td></td></tr>
    <tr><td>SMITH</td><td>Sarah</td><td>Wife</td><td>M</td><td>F</td><td>43</td><td></td><td>Derbyshire</td><td>Heage</td><td></td><td></td></tr>
    <tr><td>the person found in your search
    SMITH</td><td>John</td><td>Son</td><td>S</td><td>M</td><td>12</td><td>Scholar</td><td>Derbyshire</td><td>Belper</td><td>Deaf</td><td>transcriber note</td></tr>
    </table>
    """

    /// Same household with NO target marker anywhere — the no-marker
    /// fallback must select the first member (the head), matching Python.
    static let markerlessHouseholdHTML = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Ecclesiastical Parish</th><th>Piece</th><th>Enumeration District</th><th>Folio</th><th>Page</th><th>Schedule</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>1891</td><td>Derbyshire</td><td>Belper</td><td>Duffield</td><td>St Alkmund</td><td>RG12/2717</td><td>4</td><td>88</td><td>12</td><td>45</td><td>7</td><td>Chapel Street</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>SMITH</td><td>William</td><td>Head</td><td>M</td><td>M</td><td>45</td><td>Farmer</td><td>Derbyshire</td><td>Duffield</td><td></td><td></td></tr>
    <tr><td>SMITH</td><td>Sarah</td><td>Wife</td><td>M</td><td>F</td><td>43</td><td></td><td>Derbyshire</td><td>Heage</td><td></td><td></td></tr>
    <tr><td>SMITH</td><td>John</td><td>Son</td><td>S</td><td>M</td><td>12</td><td>Scholar</td><td>Derbyshire</td><td>Belper</td><td>Deaf</td><td>transcriber note</td></tr>
    </table>
    """

    /// Real-shape household with TWO same-name members (a father "George
    /// KEYWORTH" Head, and his son "George KEYWORTH" Son) — the exact George
    /// Keyworth 1881 Worksop record. The search marker sits inside a
    /// `<span class="accessibility">` on the head, as on the live page.
    static let sameNameHouseholdHTML = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Ecclesiastical Parish</th><th>Piece</th><th>Enumeration District</th><th>Folio</th><th>Page</th><th>Schedule</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>1881</td><td>Nottinghamshire</td><td>Worksop</td><td>Worksop</td><td></td><td>3306</td><td>10</td><td>37</td><td>39</td><td>191</td><td>137</td><td>Kilton Rd</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td><span class="accessibility">the person found in your search</span>
    KEYWORTH</td><td>George</td><td>Head</td><td>M</td><td>M</td><td>43</td><td>Maltster</td><td>Nottinghamshire</td><td>Farnsfield</td><td></td><td></td></tr>
    <tr><td>KEYWORTH</td><td>Elizabeth</td><td>Wife</td><td>M</td><td>F</td><td>37</td><td></td><td>Nottinghamshire</td><td>Retford</td><td></td><td></td></tr>
    <tr><td>KEYWORTH</td><td>William H</td><td>Son</td><td>-</td><td>M</td><td>6</td><td>Scholar</td><td>Nottinghamshire</td><td>Worksop</td><td></td><td></td></tr>
    <tr><td>KEYWORTH</td><td>George</td><td>Son</td><td>-</td><td>M</td><td>4</td><td>Scholar</td><td>Nottinghamshire</td><td>Worksop</td><td></td><td></td></tr>
    <tr><td>HEDGE</td><td>Alice</td><td>Dau</td><td>S</td><td>F</td><td>16</td><td>Servnt</td><td>County Dublin</td><td>Dublin</td><td></td><td></td></tr>
    </table>
    """

    static let detailURL = "https://www.freecen.org.uk/search_records/64ab12cd34ef56?search_query=q1"

    static func census(_ record: SourceRecord?) -> CensusRecord? {
        guard case .census(let census)? = record else { return nil }
        return census
    }
}

// MARK: - FT-12: stable, unique record IDs

nonisolated struct FreeCenStableIDTests {

    /// The core FT-12 failure: enrichment swapped `freecen_<year>_<name>` for
    /// `freecen_detail_…`, so a rejection saved against one form failed to
    /// suppress the other. Search row and household-enriched record must now
    /// share the server-stable `/search_records/<id>` segment.
    @Test func sameRecordSameIDAcrossSearchAndEnrichedForms() throws {
        let searchRecords = FreeCenSource.parseSearchResults(FreeCenFixtures.searchHTML, censusYear: 1891)
        try #require(searchRecords.count == 3)

        let searchRow = try #require(FreeCenFixtures.census(searchRecords[0]))
        #expect(searchRow.common.detailURL == FreeCenFixtures.detailURL)

        // Enrichment calls fetchDetail with the search row's detailURL —
        // mirror that exact hand-off.
        let enriched = FreeCenSource.parseHouseholdDetail(
            FreeCenFixtures.householdHTML,
            recordURL: try #require(searchRow.common.detailURL)
        )
        #expect(searchRecords[0].id == "freecen_64ab12cd34ef56")
        #expect(enriched?.id == "freecen_64ab12cd34ef56")
    }

    @Test func idsStableAcrossParseInvocations() {
        let first = FreeCenSource.parseSearchResults(FreeCenFixtures.searchHTML, censusYear: 1891)
        let second = FreeCenSource.parseSearchResults(FreeCenFixtures.searchHTML, censusYear: 1891)
        #expect(first.count == 3)
        #expect(first.map(\.id) == second.map(\.id))

        let enrichedFirst = FreeCenSource.parseHouseholdDetail(FreeCenFixtures.householdHTML, recordURL: FreeCenFixtures.detailURL)
        let enrichedSecond = FreeCenSource.parseHouseholdDetail(FreeCenFixtures.householdHTML, recordURL: FreeCenFixtures.detailURL)
        #expect(enrichedFirst?.id != nil)
        #expect(enrichedFirst?.id == enrichedSecond?.id)
    }

    /// Two John Smiths in the same census year collapsed to one composite ID
    /// (`freecen_1891_Smith_John`) and overwrote each other under
    /// evidence_records' `"<profile>|<source_record_id>"` key.
    @Test func distinctSameNamePeopleGetDistinctIDs() throws {
        let records = FreeCenSource.parseSearchResults(FreeCenFixtures.searchHTML, censusYear: 1891)
        try #require(records.count == 3)
        #expect(records[0].id == "freecen_64ab12cd34ef56")
        #expect(records[1].id == "freecen_64ab12cd34ef99")
        #expect(Set(records.map(\.id)).count == records.count)
    }

    /// A row with no detail link keeps the legacy composite — pre-existing
    /// evidence keys for link-less rows stay matched.
    @Test func missingDetailLinkFallsBackToLegacyComposite() throws {
        let records = FreeCenSource.parseSearchResults(FreeCenFixtures.searchHTML, censusYear: 1891)
        try #require(records.count == 3)
        #expect(records[2].id == "freecen_1891_Jones_Mary")
    }

    /// A degenerate href whose last path segment is the route name (no entry
    /// ID) must not be mistaken for a server-stable ID.
    @Test func routeOnlyDetailURLFallsBackToComposite() {
        let id = FreeCenSource.stableRecordID(
            detailURL: "https://www.freecen.org.uk/search_records/?q=1",
            censusYear: 1891, surname: "Jones", givenName: "Mary"
        )
        #expect(id == "freecen_1891_Jones_Mary")
    }
}

// MARK: - FT-10: household target selection (Python is_target port)

nonisolated struct FreeCenHouseholdTargetTests {

    /// The FT-10 failure mode: FreeCen lists households head-first, so
    /// `.first` selected William (Head, 45, Farmer) as the subject whenever
    /// the real target was someone else. The marker row — remembered by
    /// position, exactly as Python's target_row_start — must win.
    @Test func markedMemberNotHeadBecomesTheEnrichedSubject() throws {
        let record = try #require(FreeCenFixtures.census(
            FreeCenSource.parseHouseholdDetail(FreeCenFixtures.householdHTML, recordURL: FreeCenFixtures.detailURL)
        ))
        #expect(record.common.name == "John SMITH")
        #expect(record.age == 12)
        #expect(record.birthYear == 1879)  // 1891 − 12
        #expect(record.relationship == "Son")
        #expect(record.occupation == "Scholar")
        #expect(record.birthPlace == "Belper")
        // And explicitly NOT the head's fields:
        #expect(record.common.name != "William SMITH")
        #expect(record.age != 45)
        #expect(record.occupation != "Farmer")
    }

    /// No marker anywhere → fall back to the first member, matching Python's
    /// behaviour when no row ever sets target_row_start.
    @Test func markerAbsentFallsBackToFirstMember() throws {
        let record = try #require(FreeCenFixtures.census(
            FreeCenSource.parseHouseholdDetail(FreeCenFixtures.markerlessHouseholdHTML, recordURL: FreeCenFixtures.detailURL)
        ))
        #expect(record.common.name == "William SMITH")
        #expect(record.age == 45)
        #expect(record.relationship == "Head")
        #expect(record.occupation == "Farmer")
    }

    /// Selecting the target must not disturb the household roster itself —
    /// all members present, in page order, with computed birth years.
    @Test func fullHouseholdRosterPreservedAroundTargetSelection() throws {
        let record = try #require(FreeCenFixtures.census(
            FreeCenSource.parseHouseholdDetail(FreeCenFixtures.householdHTML, recordURL: FreeCenFixtures.detailURL)
        ))
        let household = try #require(record.household)
        #expect(household.map(\.name) == ["William SMITH", "Sarah SMITH", "John SMITH"])
        #expect(household.map(\.birthYear) == [1846, 1848, 1879])
    }

    /// Two people with the SAME name in one household (father Head + son Son,
    /// both "George KEYWORTH") must stay DISTINCT — never collapse to a
    /// duplicate of the head. Reproduces the George Keyworth 1881 Worksop case.
    @Test func sameNameHouseholdMembersStayDistinct() throws {
        let record = try #require(FreeCenFixtures.census(
            FreeCenSource.parseHouseholdDetail(
                FreeCenFixtures.sameNameHouseholdHTML, recordURL: FreeCenFixtures.detailURL)
        ))
        let household = try #require(record.household)
        #expect(household.count == 5)
        #expect(household.map(\.name) == [
            "George KEYWORTH", "Elizabeth KEYWORTH", "William H KEYWORTH",
            "George KEYWORTH", "Alice HEDGE",
        ])
        // Exactly one Head; the two Georges are father (43) and son (4).
        #expect(household.filter { $0.relationship == "Head" }.count == 1)
        let georges = household.filter { $0.name == "George KEYWORTH" }
        #expect(georges.count == 2)
        #expect(georges.contains { $0.relationship == "Head" && $0.age == 43 })
        #expect(georges.contains { $0.relationship == "Son" && $0.age == 4 })
    }
}

// MARK: - FT-15: previously-dropped household columns

nonisolated struct FreeCenHouseholdColumnTests {

    private func parsedMembers(_ html: String) throws -> [HouseholdMember] {
        let record = try #require(FreeCenFixtures.census(
            FreeCenSource.parseHouseholdDetail(html, recordURL: FreeCenFixtures.detailURL)
        ))
        let household = try #require(record.household)
        try #require(household.count == 3)
        return household
    }

    @Test func maritalStatusAndBirthCountyParsedFromColumns3And7() throws {
        let members = try parsedMembers(FreeCenFixtures.householdHTML)
        #expect(members.map(\.maritalStatus) == ["M", "M", "S"])
        #expect(members.map(\.birthCounty) == ["Derbyshire", "Derbyshire", "Derbyshire"])
    }

    @Test func disabilityAndNotesParsedAsFlatFields() throws {
        let members = try parsedMembers(FreeCenFixtures.householdHTML)
        #expect(members[2].disability == "Deaf")
        #expect(members[2].notes == "transcriber note")
    }

    /// Empty cells become nil, not empty strings — absent data must not
    /// masquerade as a (falsy but present) value downstream.
    @Test func emptyCellsMapToNil() throws {
        let members = try parsedMembers(FreeCenFixtures.householdHTML)
        #expect(members[0].disability == nil)
        #expect(members[0].notes == nil)
        #expect(members[1].notes == nil)
    }

    @Test func isTargetSetOnMarkedRowOnly() throws {
        let members = try parsedMembers(FreeCenFixtures.householdHTML)
        #expect(members.map(\.isTarget) == [false, false, true])
    }

    @Test func isTargetFalseEverywhereWhenMarkerAbsent() throws {
        let members = try parsedMembers(FreeCenFixtures.markerlessHouseholdHTML)
        #expect(members.map(\.isTarget) == [false, false, false])
    }
}
