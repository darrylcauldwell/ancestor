import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV22 (2026-08-26) — the FreeCEN household parser silently yielded census
/// year 0 and dropped every age.
///
/// OBSERVED LIVE: applying a FreeCEN 1891 household produced a census life
/// event dated "0" with no location, and EVERY member came back with no age
/// and no birth year. An 1861 household from the same source parsed
/// perfectly. The difference: the 1891 render path writes ages with a
/// trailing unit letter ("57y", "54y", "22y", "12y", "7y") where the 1861
/// path uses bare integers, and the dwelling table on that page carried no
/// census-year cell. Three silent defaults compounded:
///
///   let censusYear = Int(dwelling["census_year"] ?? "") ?? 0   // silent 0
///   let ageInt = Int(ageText)                                   // nil on "57y"
///   birthYear: (censusYear > 0) ? ageInt.map { censusYear - $0 } : nil
///
/// The fix has three halves and one refusal:
///  1. `parseAge` reads a leading integer plus an optional unit suffix —
///     and treats sub-year units as age 0, NOT as the leading integer.
///  2. `resolveCensusYear` runs a ladder (stated cell → queried year →
///     record slug) instead of defaulting to 0.
///  3. A record whose year cannot be established at all is REFUSED. A
///     census with no year is not a census.
///
/// The infant cases below are the regression guard against the naive fix:
/// reading "3m" as age 3 would silently age a three-month-old into a
/// toddler and corrupt every birth-year derivation downstream.

// MARK: - Shared fixtures

private nonisolated enum EV22Fixtures {

    /// The live 1891 shape: unit-suffixed ages. Names/place taken from the
    /// record that surfaced EV22 (the Gladwin 1891 Beighton household).
    static let household1891UnitAges = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Piece</th><th>Folio</th><th>Page</th></tr>
    <tr><td>1891</td><td>Derbyshire</td><td>Chesterfield</td><td>Beighton</td><td>RG12/2624</td><td>44</td><td>9</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>GLADWIN</td><td>George</td><td>Head</td><td>M</td><td>M</td><td>57y</td><td>Coal Miner</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td><span class="accessibility">the person found in your search</span>
    GLADWIN</td><td>Hannah</td><td>Wife</td><td>M</td><td>F</td><td>54y</td><td></td><td>Derbyshire</td><td>Chesterfield</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Emma</td><td>Dau</td><td>S</td><td>F</td><td>22y</td><td>Dressmaker</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Arthur</td><td>Son</td><td>-</td><td>M</td><td>12y</td><td>Scholar</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Lily</td><td>Dau</td><td>-</td><td>F</td><td>7y</td><td>Scholar</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    </table>
    """

    /// The 1861 shape: bare integers. Must be byte-for-byte unaffected by
    /// the unit-suffix work.
    static let household1861BareAges = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Piece</th><th>Folio</th><th>Page</th></tr>
    <tr><td>1861</td><td>Derbyshire</td><td>Chesterfield</td><td>Beighton</td><td>RG9/2542</td><td>31</td><td>4</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>GLADWIN</td><td>George</td><td>Head</td><td>M</td><td>M</td><td>27</td><td>Coal Miner</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Hannah</td><td>Wife</td><td>M</td><td>F</td><td>24</td><td></td><td>Derbyshire</td><td>Chesterfield</td><td></td><td></td></tr>
    </table>
    """

    /// Every sub-year unit FreeCEN transcribers use, on one page. Reading
    /// the leading integer alone would make these 3, 2, 11 and 5 years old.
    static let household1891InfantAges = """
    <table>
    <tr><th>Census</th><th>County</th><th>District</th><th>Civil Parish</th><th>Piece</th><th>Folio</th><th>Page</th></tr>
    <tr><td>1891</td><td>Derbyshire</td><td>Chesterfield</td><td>Beighton</td><td>RG12/2624</td><td>44</td><td>9</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>GLADWIN</td><td>George</td><td>Head</td><td>M</td><td>M</td><td>37y</td><td>Coal Miner</td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Alice</td><td>Dau</td><td>-</td><td>F</td><td>3m</td><td></td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Bertha</td><td>Dau</td><td>-</td><td>F</td><td>2w</td><td></td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Clara</td><td>Dau</td><td>-</td><td>F</td><td>11m</td><td></td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    <tr><td>GLADWIN</td><td>Dora</td><td>Dau</td><td>-</td><td>F</td><td>5d</td><td></td><td>Derbyshire</td><td>Beighton</td><td></td><td></td></tr>
    </table>
    """

    /// The EV22 page as it actually failed: the dwelling table carries NO
    /// census-year column at all, so `dwelling["census_year"]` is absent and
    /// the old code fell straight to 0.
    static let householdNoStatedYear = """
    <table>
    <tr><th>County</th><th>District</th><th>Civil Parish</th><th>Piece</th><th>Folio</th><th>Page</th></tr>
    <tr><td>Derbyshire</td><td>Chesterfield</td><td>Beighton</td><td>RG12/2624</td><td>44</td><td>9</td></tr>
    </table>
    <table>
    <tr><th>Surname</th><th>Forenames</th><th>Relationship</th><th>Marital Status</th><th>Sex</th><th>Age</th><th>Occupation</th><th>Birth County</th><th>Birth Place</th><th>Disability</th><th>Notes</th></tr>
    <tr><td>GLADWIN</td><td>Hannah</td><td>Wife</td><td>M</td><td>F</td><td>54y</td><td></td><td>Derbyshire</td><td>Chesterfield</td><td></td><td></td></tr>
    </table>
    """

    /// The live URL shape: a Mongo-style entry id, then a slug carrying BOTH
    /// the census year (1891) and the subject's birth year (1837).
    static let slugURL = "https://www.freecen.org.uk/search_records/64ab12cd34ef56/hannah-gladwin-1891-derbyshire-beighton-1837-"
    /// Same record, entry id only — no slug, so no year anywhere in the URL.
    static let bareURL = "https://www.freecen.org.uk/search_records/64ab12cd34ef56"

    static func census(_ record: SourceRecord?) -> CensusRecord? {
        guard case .census(let census)? = record else { return nil }
        return census
    }
}

// MARK: - 1. Age parsing

nonisolated struct FreeCenAgeParsingTests {

    /// The EV22 headline: the 1891 page's unit-suffixed ages parse, and the
    /// birth years derive off 1891. Before the fix every one of these was nil.
    @Test func unitSuffixedAgesParseAndDeriveBirthYears() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.household1891UnitAges, recordURL: EV22Fixtures.slugURL)
        ))
        let household = try #require(record.household)
        #expect(household.map(\.age) == [57, 54, 22, 12, 7])
        #expect(household.map(\.birthYear) == [1834, 1837, 1869, 1879, 1884])
    }

    /// Sub-year units are the regression guard against the naive fix.
    /// "3m" is three MONTHS. Reading the leading integer would make a
    /// three-month-old a three-year-old and shift her birth year by three.
    ///
    /// Verification pass 2026-08-26: a sub-year cell yields NO year-age and
    /// NO birth year — the contract documented on `HouseholdMember.rawAge`,
    /// and the precondition of `CensusRelationshipReconciler.matchesTreeWide`,
    /// which names "3w" / "7m" and falls back to birthplace corroboration
    /// precisely because such a row cannot be dated. An age of 0 would make
    /// the row dateable and silently retire that guard.
    @Test func subYearUnitsYieldNoAgeAndNeverTheLeadingInteger() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.household1891InfantAges, recordURL: EV22Fixtures.slugURL)
        ))
        let household = try #require(record.household)
        let infants = household.filter { $0.relationship == "Dau" }
        #expect(infants.map(\.name) == [
            "Alice GLADWIN", "Bertha GLADWIN", "Clara GLADWIN", "Dora GLADWIN",
        ])
        // 3m, 2w, 11m, 5d — every one under a year old, so none of them
        // carries a year-age, and no birth year is fabricated from one.
        let infantAges: [Int?] = infants.map(\.age)
        #expect(infantAges == [nil, nil, nil, nil])
        // Stated the other way round: the leading integer must never be read
        // as a year-age when a sub-year unit follows it.
        #expect(infantAges != [3, 2, 11, 5])
        let infantBirthYears: [Int?] = infants.map(\.birthYear)
        #expect(infantBirthYears == [nil, nil, nil, nil])
        // The evidence is not dropped, only left un-derived — the
        // transcription survives so the infant is still visible as an infant.
        #expect(infants.map(\.rawAge) == ["3m", "2w", "11m", "5d"])
    }

    /// The 1861-style page (bare integers) must be untouched by the
    /// unit-suffix work — it was the half of the source that already worked.
    @Test func bareIntegerAgesUnchanged() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.household1861BareAges, recordURL: EV22Fixtures.bareURL)
        ))
        let household = try #require(record.household)
        #expect(household.map(\.age) == [27, 24])
        #expect(household.map(\.birthYear) == [1834, 1837])
        let rawAges: [String?] = household.map(\.rawAge)
        #expect(rawAges == [nil, nil], "a clean integer is fully carried by `age`; no raw text needed")
    }

    // MARK: parseAge unit-level

    @Test func parseAgeReadsYearUnitsLiberally() {
        #expect(FreeCenSource.parseAge("57y").years == 57)
        #expect(FreeCenSource.parseAge("57Y").years == 57)
        #expect(FreeCenSource.parseAge("57 y").years == 57)
        #expect(FreeCenSource.parseAge(" 57 Y ").years == 57)
        #expect(FreeCenSource.parseAge("57").years == 57)
        #expect(FreeCenSource.parseAge("0").years == 0)
    }

    /// Every sub-year unit yields no year-age, and — the part that actually
    /// matters — never the leading integer. The transcription is kept so the
    /// row still reads as an infant downstream.
    @Test func parseAgeTreatsEverySubYearUnitAsUndateable() {
        for cell in ["3m", "11m", "3 mo", "6 months", "2w", "5d", "2h"] {
            #expect(FreeCenSource.parseAge(cell).years == nil, "\(cell) is not a year-age")
            #expect(FreeCenSource.parseAge(cell).rawText == cell, "\(cell) keeps its transcription")
        }
        // The naive fix, stated explicitly.
        #expect(FreeCenSource.parseAge("3m").years != 3)
        #expect(FreeCenSource.parseAge("11m").years != 11)
    }

    @Test func parseAgePreservesTranscriptionWheneverItIsNotACleanInteger() {
        #expect(FreeCenSource.parseAge("57y").rawText == "57y")
        #expect(FreeCenSource.parseAge("3m").rawText == "3m")
        #expect(FreeCenSource.parseAge("57").rawText == nil)
        #expect(FreeCenSource.parseAge("").rawText == nil)
    }

    /// No leading integer at all, or an unrecognised unit: assert no age
    /// rather than guess. "unk" is the VLD rendering of the unknown-age
    /// sentinel; 999 is that sentinel leaking through numerically, and
    /// believing it would derive a birth year ~900 years early.
    @Test func unusableAgeCellsYieldNoAge() {
        #expect(FreeCenSource.parseAge("unk").years == nil)
        #expect(FreeCenSource.parseAge("unk").rawText == "unk")
        #expect(FreeCenSource.parseAge("-").years == nil)
        #expect(FreeCenSource.parseAge("999").years == nil)
        #expect(FreeCenSource.parseAge("999").rawText == "999")
        #expect(FreeCenSource.parseAge("12q").years == nil, "unrecognised unit — never guess its scale")
        #expect(FreeCenSource.parseAge("").years == nil)
    }
}

// MARK: - 2 & 3. Census-year resolution and refusal

nonisolated struct FreeCenCensusYearResolutionTests {

    /// The page's own stated year wins over everything else.
    @Test func statedYearWins() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.household1891UnitAges,
                recordURL: EV22Fixtures.slugURL,
                queryYear: 1861)
        ))
        #expect(record.censusYear == 1891, "the page states 1891; a stale query hint must not override it")
    }

    /// EV22 rung 2 — no stated year, but the search asked for one. Same
    /// fallback the search-results path has always had.
    @Test func queriedYearFillsAMissingStatedYear() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.householdNoStatedYear,
                recordURL: EV22Fixtures.bareURL,
                queryYear: 1891)
        ))
        #expect(record.censusYear == 1891)
        #expect(record.household?.first?.birthYear == 1837, "1891 − 54")
    }

    /// EV22 rung 3 — no stated year and no query hint, but the record slug
    /// carries the census year. This is the exact live case.
    @Test func slugYearFillsAMissingStatedYear() throws {
        let record = try #require(EV22Fixtures.census(
            FreeCenSource.parseHouseholdDetail(
                EV22Fixtures.householdNoStatedYear, recordURL: EV22Fixtures.slugURL)
        ))
        #expect(record.censusYear == 1891, "…/hannah-gladwin-1891-derbyshire-beighton-1837- → 1891")
        #expect(record.censusYear != 0, "the whole point of EV22: never a silent 0")
    }

    /// The slug carries TWO four-digit years. 1837 is Hannah's BIRTH year —
    /// picking it would date the census 54 years early. Only a year FreeCen
    /// actually holds can be the census year.
    @Test func slugBirthYearIsNotMistakenForTheCensusYear() {
        #expect(FreeCenSource.censusYearFromSlug(EV22Fixtures.slugURL) == 1891)
        #expect(FreeCenSource.censusYearFromSlug(EV22Fixtures.slugURL) != 1837)
    }

    /// A four-digit run buried inside an alphanumeric entry id is not a
    /// year token and must not be read as one.
    @Test func digitsInsideARecordIDAreNotAYear() {
        #expect(FreeCenSource.censusYearFromSlug("https://www.freecen.org.uk/search_records/64ab1861cd34ef") == nil)
        #expect(FreeCenSource.censusYearFromSlug("https://www.freecen.org.uk/search_records/64ab12cd34ef56") == nil)
    }

    /// The refusal. A census with no year is not a census: no stated year,
    /// no query hint, no slug year → no record, rather than a record dated 0.
    @Test func householdWithNoDeterminableYearIsRefused() {
        let record = FreeCenSource.parseHouseholdDetail(
            EV22Fixtures.householdNoStatedYear, recordURL: EV22Fixtures.bareURL)
        #expect(record == nil, "refuse the record; never emit censusYear 0")
    }

    /// The ladder itself, exercised directly.
    @Test func resolveCensusYearLadderOrder() {
        // 1. stated
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: "1861", queryYear: 1891, recordURL: EV22Fixtures.slugURL) == 1861)
        // The stated cell is read liberally — some render paths append copy.
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: "1861 Census", queryYear: nil, recordURL: nil) == 1861)
        // 2. queried
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: nil, queryYear: 1871, recordURL: EV22Fixtures.bareURL) == 1871)
        // 3. slug
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: nil, queryYear: nil, recordURL: EV22Fixtures.slugURL) == 1891)
        // …then nothing.
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: nil, queryYear: nil, recordURL: EV22Fixtures.bareURL) == nil)
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: "", queryYear: nil, recordURL: nil) == nil)
    }

    /// An out-of-coverage stated year is not believed, and an out-of-set
    /// hint (there was no 1900 census) is not promoted to a census year.
    @Test func implausibleYearsAreNotBelieved() {
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: "1066", queryYear: nil, recordURL: nil) == nil)
        #expect(FreeCenSource.resolveCensusYear(
            statedYear: nil, queryYear: 1900, recordURL: nil) == nil)
    }
}

// MARK: - The search-results path (same ladder, same refusal)

nonisolated struct FreeCenSearchRowCensusYearTests {

    private static func searchHTML(censusYearCell: String, href: String?) -> String {
        let link = href.map { "<a href=\"\($0)\">View</a>" } ?? ""
        return """
        We found 1 Results
        <table>
        <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
        <tr><td>\(link)</td><td>Hannah Gladwin</td><td>Derbyshire</td><td>Chesterfield</td><td>1837</td><td>\(censusYearCell)</td><td>Derbyshire</td><td>Chesterfield</td></tr>
        </table>
        """
    }

    @Test func statedRowYearParsesAsBefore() throws {
        let records = FreeCenSource.parseSearchResults(
            Self.searchHTML(censusYearCell: "1891", href: "/search_records/64ab12cd34ef56"),
            censusYear: nil)
        let census = try #require(EV22Fixtures.census(records.first))
        #expect(census.censusYear == 1891)
    }

    @Test func emptyRowYearFallsBackToTheQueriedYear() throws {
        let records = FreeCenSource.parseSearchResults(
            Self.searchHTML(censusYearCell: "", href: "/search_records/64ab12cd34ef56"),
            censusYear: 1891)
        let census = try #require(EV22Fixtures.census(records.first))
        #expect(census.censusYear == 1891, "the pre-existing `Int(cells[5]) ?? censusYear` fallback still applies")
    }

    @Test func emptyRowYearFallsBackToTheSlug() throws {
        let records = FreeCenSource.parseSearchResults(
            Self.searchHTML(
                censusYearCell: "",
                href: "/search_records/64ab12cd34ef56/hannah-gladwin-1891-derbyshire-beighton-1837-"),
            censusYear: nil)
        let census = try #require(EV22Fixtures.census(records.first))
        #expect(census.censusYear == 1891)
    }

    /// Nothing left to try → skip the row rather than emit `censusYear: 0`.
    @Test func rowWithNoDeterminableYearIsSkipped() {
        let records = FreeCenSource.parseSearchResults(
            Self.searchHTML(censusYearCell: "", href: "/search_records/64ab12cd34ef56"),
            censusYear: nil)
        #expect(records.isEmpty, "a census row with no year is not a census row")
        let zeroYearRows = records.filter { EV22Fixtures.census($0)?.censusYear == 0 }
        #expect(zeroYearRows.isEmpty, "never emit a row dated 0 — that is the EV22 corruption")
    }
}
