import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// LOCATION_MODEL_SPEC Slice 0 — the geography gate resolves PARISH-level
/// district names against the REAL bundled catalogue.
///
/// `PlaceResolver.resolveDistrict` only matches nodes whose kind is
/// `.registrationDistrict` (`PlaceAuthority+Resolution.swift:162`), but a census
/// prints the civil parish in its district column. So a name the catalogue
/// genuinely contained could never resolve, and the gate answered
/// "unknown district".
///
/// Driver (owner dogfood 2026-08-17): `Wensley And Snitterton` — the subject
/// family's home township for two censuses — scored "unknown district" against a
/// catalogue that ships it as `Wensley &amp; Snitterton` under DBY/Bakewell
/// (from 1839) and DBY/Matlock (to 1838). Two defects stacked: the parish list
/// kept its scraped HTML entities while the record side unescapes
/// (`FreeCenSource.swift:847`), and the gate never consulted the parish tier.
///
/// These tests run against the SHIPPED data deliberately — the synthetic-seed
/// derivation is covered in `PlaceAuthorityRegistryTests`; what is proved here
/// is that the real catalogue now answers.
@MainActor
struct GeographyParishTierTests {

    private func subject(chapman: String, county: String) -> ResearchSubject {
        ResearchSubject(
            surname: "Stevenson", givenName: "Amos",
            birthYearFrom: 1824, birthYearTo: 1828,
            gender: .male,
            region: .county(county),
            mode: .extend,
            homeChapmanCode: chapman
        )
    }

    private func census(district: String, year: Int) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "c-\(district)-\(year)", sourceID: "freecen",
                name: "Amos Stevenson", surname: "Stevenson", givenName: "Amos",
                rawFields: [:]
            ),
            censusYear: year, age: 33, birthYear: 1828,
            birthPlace: "Darley Bridge", district: district
        ))
    }

    private func geography(_ result: ScoredRecord) -> GateResult? {
        result.gates.first { $0.gate == .geography }
    }

    // MARK: - The driving case

    @Test func compoundParishDistrictResolvesToTheSubjectsCounty() {
        let result = RecordScorer.classify(
            record: census(district: "Wensley And Snitterton", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        let geo = geography(result)
        #expect(geo?.outcome == .pass,
                "Wensley And Snitterton is a DBY parish — got \(String(describing: geo?.outcome)): \(geo?.reason ?? "-")")
        #expect(!(geo?.reason.hasPrefix("unknown district") ?? false),
                "must no longer answer 'unknown district' for a parish the catalogue holds")
    }

    /// The ampersand spelling must work too — the record side unescapes, so both
    /// forms arrive in practice.
    @Test func ampersandSpellingResolvesIdentically() {
        let result = RecordScorer.classify(
            record: census(district: "Wensley & Snitterton", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        #expect(geography(result)?.outcome == .pass)
    }

    /// Generalisation, not a Derbyshire special case: Warslow is a Staffordshire
    /// parish and must resolve for an STS subject with no county-specific code.
    @Test func aStaffordshireParishResolvesForAStaffordshireSubject() {
        let result = RecordScorer.classify(
            record: census(district: "Warslow", year: 1861),
            subject: subject(chapman: "STS", county: "Staffordshire"),
            searchType: .census
        )
        let geo = geography(result)
        #expect(geo?.outcome == .pass,
                "Warslow is an STS parish — got \(String(describing: geo?.outcome)): \(geo?.reason ?? "-")")
    }

    // MARK: - The guards

    /// A parish that is unambiguously in ANOTHER county must soft-fail with a
    /// real reason, not pass and not answer "unknown".
    @Test func anOutOfCountyParishSoftFailsWithAReason() {
        let result = RecordScorer.classify(
            record: census(district: "Warslow", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        let geo = geography(result)
        #expect(geo?.outcome == .softFail)
        #expect(geo?.reason.contains("outside the subject's counties") ?? false,
                "expected an out-of-county reason, got: \(geo?.reason ?? "-")")
    }

    /// The anti-homework-marking guard. Bare "Wensley" is a real parish in BOTH
    /// Derbyshire (via the compound alias) and the North Riding (Leyburn,
    /// Wensleydale). Resolution is deliberately NOT scoped to the subject's own
    /// county, so an ambiguous name must decline to the pre-existing behaviour
    /// rather than conveniently landing in-area.
    @Test func anAmbiguousParishDoesNotSilentlyResolveInTheSubjectsFavour() {
        let result = RecordScorer.classify(
            record: census(district: "Wensley", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        let geo = geography(result)
        #expect(geo?.outcome != .pass,
                "bare Wensley spans DBY and NRY — passing it would be the gate marking its own homework")
    }

    /// Era-awareness survives the parish route. Wensley & Snitterton sat in
    /// Matlock to 1838 and Bakewell from 1839; both are DBY, so the county
    /// verdict holds either side of the boundary.
    @Test func theParishRouteIsEraAwareAcrossADistrictBoundary() {
        for year in [1835, 1861] {
            let result = RecordScorer.classify(
                record: census(district: "Wensley And Snitterton", year: year),
                subject: subject(chapman: "DBY", county: "Derbyshire"),
                searchType: .census
            )
            #expect(geography(result)?.outcome == .pass,
                    "should resolve in \(year) — Matlock to 1838, Bakewell from 1839")
        }
    }

    /// Prose rows in UKBMD's parish column are not places and must never
    /// resolve as one.
    @Test func aFootnoteRowNeverResolvesAsAPlace() {
        let result = RecordScorer.classify(
            record: census(district: "abolished 1.4.1935 and added to the parish of Ashwellthorpe.",
                           year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        #expect(geography(result)?.outcome != .pass)
    }

    // MARK: - Counties filed under their subdivisions

    /// Every English registration district sits under a riding (WRY/ERY/NRY),
    /// never under YKS. Scoping "Sheffield, Yorkshire" to YKS matched nothing:
    /// a string that said MORE about where it was resolved to LESS.
    @Test func aCountyFiledUnderRidingsExpandsToThem() {
        #expect(RegistrationDistrictResolver.subdivisions(of: "YKS") == ["ERY", "NRY", "WRY"])
        #expect(RegistrationDistrictResolver.statedChapmanScope(in: "Sheffield, Yorkshire")
                == ["ERY", "NRY", "WRY"])
    }

    /// A county that owns districts directly is not expanded — Derbyshire must
    /// stay exactly DBY.
    @Test func anOrdinaryCountyIsNotExpanded() {
        #expect(RegistrationDistrictResolver.statedChapmanScope(in: "Bonsall, Derbyshire") == ["DBY"])
        #expect(RegistrationDistrictResolver.subdivisions(of: "DBY").isEmpty)
    }

    @Test func sheffieldResolvesWithinYorkshire() {
        let id = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Sheffield, Yorkshire", chapman: nil, year: 1861)
        #expect(id?.hasPrefix("WRY:") == true, "got \(id ?? "nil")")
    }

    /// The expansion must stay a CONSTRAINT, not a licence to search nationally.
    /// Dropping the county instead resolved a Yorkshire "Clayton" into
    /// Staffordshire and Sussex — a wrong county is the one geography error the
    /// gate cannot recover from, so declining is the correct answer here.
    @Test func expandingACountyNeverEscapesIt() {
        let id = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Clayton, Yorkshire", chapman: nil, year: 1861)
        #expect(id == nil || id?.hasPrefix("WRY:") == true || id?.hasPrefix("NRY:") == true
                || id?.hasPrefix("ERY:") == true,
                "resolved outside Yorkshire: \(id ?? "nil")")
    }

    // MARK: - #31 GRO abbreviation tolerance (owner dogfood 2026-08-24:
    // "unknown district: Chapel le F." on Kezia Wheeldon's 1897 marriage)

    @Test func groAbbreviatedDistrictResolves() {
        let result = RecordScorer.classify(
            record: census(district: "Chapel le F.", year: 1901),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        let gate = geography(result)
        #expect(gate?.outcome == .pass, "got \(gate?.reason ?? "no gate")")
        #expect(gate?.reason.contains("Derbyshire") == true)
    }

    @Test func hyphenatedDistrictVariantResolves() {
        let result = RecordScorer.classify(
            record: census(district: "Chapel-en-le-Frith", year: 1901),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        #expect(geography(result)?.outcome == .pass,
                "got \(geography(result)?.reason ?? "no gate")")
    }

    @Test func dataDerivedAliasResolves() {
        // "Ashborne" is FreeBMD's recurring variant of Ashbourne — carried in
        // freebmd-districts.json's aliases (migrated from the last hardcoded
        // alias map), never in code.
        let result = RecordScorer.classify(
            record: census(district: "Ashborne", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        #expect(geography(result)?.outcome == .pass,
                "got \(geography(result)?.reason ?? "no gate")")
    }

    @Test func subDistrictQualifierFallsBackToTheDistrict() {
        // "Derby St Alkmund" = Derby district + sub-district qualifier; the
        // leading-prefix retry resolves the district uniquely.
        let result = RecordScorer.classify(
            record: census(district: "Derby St Alkmund", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        let gate = geography(result)
        #expect(gate?.outcome == .pass, "got \(gate?.reason ?? "no gate")")
    }

    @Test func ambiguousAbbreviationStillDeclines() {
        // A bare sub-district with an ambiguous stem must NOT resolve —
        // "when in doubt, split".
        let result = RecordScorer.classify(
            record: census(district: "St Peter", year: 1861),
            subject: subject(chapman: "DBY", county: "Derbyshire"),
            searchType: .census
        )
        #expect(geography(result)?.outcome == .softFail)
    }

    @Test func abbreviationMatcherStaysTight() {
        #expect(PlaceAuthority.abbreviatedNameMatches(
            query: "chapel le f.", candidate: "Chapel en le Frith"))
        #expect(PlaceAuthority.abbreviatedNameMatches(
            query: "ashton u. lyne", candidate: "Ashton under Lyne"))
        #expect(PlaceAuthority.abbreviatedNameMatches(
            query: "w. ham", candidate: "West Ham"))
        #expect(!PlaceAuthority.abbreviatedNameMatches(
            query: "chapel", candidate: "Chapel en le Frith"),
            "a bare leading word is a prefix, not an abbreviation")
        #expect(!PlaceAuthority.abbreviatedNameMatches(
            query: "ham", candidate: "West Ham"),
            "first tokens must align")
    }
}
