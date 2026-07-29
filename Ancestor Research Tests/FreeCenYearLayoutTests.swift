import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Header-keyed census household parsing (FREEREG_INTEGRATION_SPEC recon
/// 2026-07-29). The member table's columns vary by census year — 1841 has
/// 7, 1851–1891 E&W has 11, 1911 E&W has 20 (fertility block) — and the
/// FreeCEN2 CSV render path stacks THREE tables (census header, address,
/// members) where the VLD path has two. The old fixed-position 11-column
/// parse silently mis-read all of these; columns are now resolved by
/// header name and the member table is identified by its headers.
@MainActor
struct FreeCenYearLayoutTests {

    static let detailURL = "https://www.freecen.org.uk/search_records/64test123"

    /// 1911 E&W — full 20-column layout incl. the fertility block and an
    /// infant age ("3m") that must survive as rawAge.
    static let household1911HTML = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Ecclesiastical Parish</th><th>Piece</th><th>Enumeration District</th><th>Folio</th><th>Page</th><th>Schedule</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>1911</td><td>Derbyshire</td><td>Belper</td><td>Heage</td><td>St Luke</td><td>RG14/20912</td><td>3</td><td>44</td><td>9</td><td>112</td><td>4</td><td>Spanker Lane</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Years Married</th><th>Children Born Alive</th><th>Children Living</th><th>Children Deceased</th><th>Occupation</th><th>Occ Category</th><th>Industry</th><th>Works At Home</th><th>Nationality</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Disability Notes</th><th>Notes</th></tr>
    <tr><td>MARSHALL</td><td>Harry</td><td>Head</td><td>M</td><td>M</td><td>34</td><td></td><td></td><td></td><td></td><td>Coal Miner</td><td>M</td><td>Coal Mine</td><td></td><td>British</td><td>Derbyshire</td><td>Heage</td><td></td><td></td><td></td></tr>
    <tr><td>MARSHALL</td><td>Sarah
    the person found in your search</td><td>Wife</td><td>M</td><td>F</td><td>32</td><td>11</td><td>5</td><td>4</td><td>1</td><td></td><td></td><td></td><td></td><td>British</td><td>Derbyshire</td><td>Ripley</td><td></td><td></td><td></td></tr>
    <tr><td>MARSHALL</td><td>Margaret</td><td>Dau</td><td></td><td>F</td><td>3m</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td>Derbyshire</td><td>Heage</td><td></td><td></td><td></td></tr>
    </table>
    """

    /// 1841 E&W — seven member columns, no Relationship / Marital Status,
    /// no Birth Place (county only), and a reduced dwelling header.
    static let household1841HTML = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Piece</th><th>Enumeration District</th><th>Folio</th><th>Page</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>1841</td><td>Derbyshire</td><td>Belper</td><td>Duffield</td><td>HO107/197</td><td>2</td><td>12</td><td>6</td><td>3</td><td>Town Street</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Notes</th></tr>
    <tr><td>WHEELDON</td><td>Samuel</td><td>M</td><td>45</td><td>Farmer</td><td>Derbyshire</td><td></td></tr>
    <tr><td>WHEELDON</td><td>Ruth</td><td>F</td><td>40</td><td></td><td>Derbyshire</td><td></td></tr>
    </table>
    """

    /// FreeCEN2 CSV path — THREE stacked tables (census header, address,
    /// members). A position-based parse reads the address table as the
    /// roster; header identification must find the real member table.
    static let csvPathHTML = """
    <table>
    <tr><th>Census Year</th><th>County</th><th>Census District</th><th>Enumeration District</th><th>Civil Parish</th><th>Ecclesiastical Parish</th><th>Where Census Taken</th><th>Piece</th><th>Ward</th><th>Constituency</th></tr>
    <tr><td>1901</td><td>Derbyshire</td><td>Belper</td><td>5</td><td>Heage</td><td>St Luke</td><td>Heage</td><td>RG13/3238</td><td></td><td>Mid Derbyshire</td></tr>
    </table>
    <table>
    <tr><th>Folio</th><th>Page</th><th>Dwelling Number</th><th>Schedule</th><th>House Number</th><th>House or Street Name</th></tr>
    <tr><td>101</td><td>17</td><td>88</td><td>134</td><td></td><td>Dungeley Hill</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Nationality</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>CAULDWELL</td><td>John</td><td>Head</td><td>M</td><td>M</td><td>62</td><td>Farm Labourer</td><td></td><td>Derbyshire</td><td>Heage</td><td></td><td></td></tr>
    <tr><td>BARKER</td><td>Martha</td><td>Ma-Law</td><td>W</td><td>F</td><td>80</td><td></td><td></td><td>Derbyshire</td><td>Pentrich</td><td></td><td></td></tr>
    </table>
    """

    /// ERB-FAITHFUL fixture (verify findings 2026-07-29): the live VLD
    /// partials render `<thead>` header cells with NO wrapping `<tr>`,
    /// pad every cell with template newlines, HTML-encode values
    /// (`&amp;`, `&#39;`), and put the search-target marker in an
    /// accessibility span followed by a newline. The idealized fixtures
    /// above masked ALL of that — this one must parse identically.
    static let erbShapedVLDHTML = """
    <table class='table--data'>
    <thead>
    <th>
      Census
    </th><th>
      County
    </th><th>
      District
    </th><th>
      Civil Parish
    </th><th>
      Piece
    </th><th>
      Folio
    </th><th>
      Page
    </th>
    </thead>
    <tbody>
    <tr><td>
      1891
    </td><td>
      Derbyshire
    </td><td>
      Belper
    </td><td>
      Duffield
    </td><td>
      RG12/2717
    </td><td>
      88
    </td><td>
      12
    </td></tr>
    </tbody>
    </table>
    <table class='table--data'>
    <thead>
    <th>
      Surname
    </th><th>
      Forenames
    </th><th>
      Relationship
    </th><th>
      Marital Status
    </th><th>
      Sex
    </th><th>
      Age
    </th><th>
      Occupation
    </th><th>
      Birth County
    </th><th>
      Birth Place
    </th><th>
      Disability
    </th><th>
      Notes
    </th>
    </thead>
    <tbody>
    <tr class="weight--semibold"><td>
      <span class="accessibility">the person found in your search</span>
      O&#39;BRIEN
    </td><td>
      William
    </td><td>
      Head
    </td><td>
      M
    </td><td>
      M
    </td><td>
      45
    </td><td>
      Coal Miner &amp; Hewer
    </td><td>
      Derbyshire
    </td><td>
      Duffield
    </td><td>
    </td><td>
    </td></tr>
    </tbody>
    </table>
    """

    private func household(_ html: String) -> CensusRecord? {
        guard case .census(let census)? = FreeCenSource.parseHouseholdDetail(html, recordURL: Self.detailURL) else { return nil }
        return census
    }

    // MARK: - ERB-shaped reality (the two masked criticals)

    @Test func erbShapedPageParsesEndToEnd() {
        guard let census = household(Self.erbShapedVLDHTML) else {
            Issue.record("live-shaped page (bare-th thead + newline-padded cells) must parse")
            return
        }
        #expect(census.censusYear == 1891)
        #expect(census.household?.count == 1)
        let william = census.household?.first
        #expect(william?.isTarget == true, "marker span + newline before the value still resolves the target")
        #expect(william?.name == "William O'BRIEN", "entity &#39; decodes")
        #expect(william?.occupation == "Coal Miner & Hewer", "entity &amp; decodes")
        #expect(william?.age == 45)
        #expect(census.common.rawFields["parish"] == "Duffield")
        #expect(census.common.rawFields["folio"] == "88", "bare-th thead headers key the dwelling table")
    }

    // MARK: - 1911

    @Test func fertilityBlockIsTyped() {
        guard let census = household(Self.household1911HTML) else { Issue.record("no record"); return }
        let sarah = census.household?.first { $0.name.contains("Sarah") }
        #expect(sarah?.isTarget == true, "marker row is the search target")
        #expect(sarah?.yearsMarried == "11")
        #expect(sarah?.childrenBornAlive == 5)
        #expect(sarah?.childrenLiving == 4)
        #expect(sarah?.childrenDeceased == 1, "born-alive minus living: the missing-child signal is typed")
    }

    @Test func infantAgeSurvivesAsRawAge() {
        guard let census = household(Self.household1911HTML) else { Issue.record("no record"); return }
        let margaret = census.household?.first { $0.name.contains("Margaret") }
        #expect(margaret?.age == nil, "\"3m\" is not a year-age")
        #expect(margaret?.birthYear == nil, "no fabricated birth year from a months-age")
        #expect(margaret?.rawAge == "3m", "the transcribed infant age is preserved")
    }

    @Test func nineteenElevenExtrasAreTyped() {
        guard let census = household(Self.household1911HTML) else { Issue.record("no record"); return }
        let harry = census.household?.first { $0.name.contains("Harry") }
        #expect(harry?.industry == "Coal Mine")
        #expect(harry?.nationality == "British")
        #expect(harry?.occupation == "Coal Miner")
        #expect(census.censusYear == 1911)
    }

    // MARK: - 1841

    @Test func sevenColumn1841ParsesWithoutRelationship() {
        guard let census = household(Self.household1841HTML) else { Issue.record("no record"); return }
        #expect(census.censusYear == 1841)
        #expect(census.household?.count == 2)
        let samuel = census.household?.first { $0.name.contains("Samuel") }
        #expect(samuel?.relationship == "", "1841 has no relationship column — empty, never guessed")
        #expect(samuel?.age == 45)
        #expect(samuel?.birthYear == 1841 - 45)
        #expect(samuel?.occupation == "Farmer")
        #expect(samuel?.birthCounty == "Derbyshire")
        #expect(samuel?.birthPlace == nil, "1841 records county only")
    }

    // MARK: - FreeCEN2 CSV three-table path

    @Test func csvPathFindsMemberTableByHeaders() {
        guard let census = household(Self.csvPathHTML) else { Issue.record("no record"); return }
        #expect(census.censusYear == 1901, "\"Census Year\" header maps to census_year")
        #expect(census.household?.count == 2, "the address table must NOT be parsed as the roster")
        let martha = census.household?.first { $0.name.contains("Martha") }
        #expect(martha?.relationship == "Ma-Law")
        #expect(martha?.maritalStatus == "W")
        #expect(census.common.rawFields["district"] == "Belper", "\"Census District\" maps to district")
        #expect(census.common.rawFields["address"] == "Dungeley Hill")
        #expect(census.common.rawFields["folio"] == "101", "address-table metadata merges into dwelling fields")
    }
}
