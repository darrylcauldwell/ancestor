import Testing
import Foundation
@testable import AncestorKit

/// Owner dogfood 2026-08-26 — Hannah Hewkin's `lastName` fact "Hewkin" cited the
/// 1841 Dronfield census (HO107 195/20 book 6 p.8 line 21,
/// ark:/61903/1:1:M7SB-YZJ): the evidence that corrected her surname from
/// Wheatman. She had NO 1841 census event, so the citation sat on a field with
/// nothing behind it — the 1841 census was invisible to her timeline, the roster
/// machinery, the family-context gate and completeness. Nothing in the app
/// surfaced it; a human found it by reading citation URLs by eye.
struct CitedCensusWithoutEventRuleTests {

    private static let hannahID = "@I332233296853@"
    private static let hannahsArk1841 = "https://www.familysearch.org/ark:/61903/1:1:M7SB-YZJ"

    // MARK: - Builders

    private func source(
        url: String, collection: String? = nil, title: String? = nil,
        page: String? = nil, notes: String? = nil, raw: String = "field-researcher"
    ) -> FieldSource {
        FieldSource(origin: SourceOrigin(identifier: "field-researcher"),
                    raw: raw, addedAt: Date(),
                    citation: Citation(collection: collection, title: title,
                                       page: page, url: url, notes: notes))
    }

    private func hannah(sources: [ProfileField: [FieldSource]]) -> Profile {
        Profile(id: Self.hannahID, externalIDs: [:], firstName: "Hannah",
                lastName: "Hewkin", gender: .female, attributes: nil,
                birthDate: GenealogicalDate(parsing: "1836"),
                birthLocation: "Holymoorside, Derbyshire",
                deathDate: nil, deathLocation: nil, bio: nil,
                isDeleted: false, sources: sources, disputes: [:])
    }

    /// The exact citation the surname correction carried.
    private var the1841Citation: FieldSource {
        source(url: Self.hannahsArk1841,
               collection: "1841 England Census",
               title: "Census 1841: Hannah Hewkin, Dronfield",
               page: "HO107 195/20 book 6 p.8 line 21",
               raw: "1841 England Census, Dronfield — HO107 195/20 book 6 p.8 line 21")
    }

    private func censusEvent(date: String, url: String? = nil) -> LifeEvent {
        LifeEvent(id: UUID(), profileID: Self.hannahID, type: .census,
                  date: GenealogicalDate(parsing: date), location: "Dronfield",
                  details: .census(CensusDetails(household: [])),
                  sources: url.map {
                      [FieldSource(origin: SourceOrigin(identifier: "field-researcher"),
                                   raw: "field-researcher", addedAt: Date(),
                                   citation: Citation(url: $0))]
                  } ?? [])
    }

    private func snapshot(_ profile: Profile, events: [LifeEvent] = []) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [],
                            lifeEvents: events.isEmpty ? [:] : [profile.id: events])
    }

    private func fire(_ profile: Profile, events: [LifeEvent] = []) -> [AuditResult] {
        CitedCensusWithoutEventRule().evaluate(
            profile: profile, snapshot: snapshot(profile, events: events))
    }

    // MARK: - Hannah's pre-fix state

    @Test func hannahsPreFixStateFires() {
        let subject = hannah(sources: [.lastName: [the1841Citation]])
        let results = fire(subject)
        #expect(results.count == 1)
        #expect(results.first?.ruleID == "citedCensusWithoutEvent")
        #expect(results.first?.category == .gap)
        #expect(results.first?.severity == .info)
        #expect(results.first?.message.contains("1841") == true)
        #expect(results.first?.message.contains("the surname") == true)
    }

    @Test func addingTheEventSilencesIt() {
        let subject = hannah(sources: [.lastName: [the1841Citation]])
        #expect(fire(subject, events: [censusEvent(date: "1841")]).isEmpty)
    }

    @Test func theCheckIsOnTheYearNotTheDateString() {
        // CARE POINT: an event dated "6 Jun 1841" and a citation saying "1841" are
        // the same census. String equality would re-fire on every properly-dated
        // census event in the tree.
        let subject = hannah(sources: [.lastName: [the1841Citation]])
        #expect(fire(subject, events: [censusEvent(date: "6 Jun 1841")]).isEmpty)
        #expect(fire(subject, events: [censusEvent(date: "ABT 1841")]).isEmpty)
    }

    @Test func anEventCitingTheSameRecordSilencesItWhateverYearItCarries() {
        // Belt to the year check's braces: if the very record cited on the field
        // is what backs an existing census event, there IS something behind the
        // citation even when the two dates disagree.
        let subject = hannah(sources: [.lastName: [the1841Citation]])
        #expect(fire(subject, events: [censusEvent(date: "1840", url: Self.hannahsArk1841)]).isEmpty)
    }

    // MARK: - Must not fire on non-census evidence

    @Test func aFreeBMDBirthIndexCitationDoesNotFire() {
        // The URL host is a civil-registration index, which by construction never
        // holds census returns — and the citation text carries "1861", a census
        // year, which a bare four-digit scan would have swallowed.
        let birth = source(
            url: "https://www.freebmd.org.uk/cgi/information.pl?r=99374624:8836&d=bmd_1784770807",
            collection: "England & Wales, Civil Registration Birth Index, 1861",
            title: "Birth: Thomas Gladwin, Dec 1861, Chesterfield",
            page: "vol. 7b, page 513",
            raw: "freebmd")
        #expect(CensusCitationReader.censusYear(of: birth) == nil)
        #expect(fire(hannah(sources: [.birthDate: [birth]])).isEmpty)
    }

    @Test func aBirthIndexOnACensusBearingHostStillDoesNotFire() {
        // Same index text, this time behind a FamilySearch ark. The host allows
        // census, so the SECOND stage has to refuse: nothing says "census".
        let birth = source(url: "https://www.familysearch.org/ark:/61903/1:1:ABCD-123",
                           collection: "England & Wales, Civil Registration Birth Index, 1861",
                           title: "Birth: Thomas Gladwin, Dec 1861, Chesterfield",
                           raw: "field-researcher")
        #expect(CensusCitationReader.censusYear(of: birth) == nil)
        #expect(fire(hannah(sources: [.birthDate: [birth]])).isEmpty)
    }

    @Test func aParishBurialCitationDoesNotFire() {
        let burial = source(
            url: "https://www.freereg.org.uk/search_records/682fcf2a8655746c65258d7b/william-gladwin-burial-derbyshire-elmton-1898-03-04",
            title: "Parish: William GLADWIN, burial 1898", raw: "freereg")
        #expect(CensusCitationReader.censusYear(of: burial) == nil)
    }

    @Test func anUnrecognisedHostIsNotRecognisablyACensus() {
        let vague = source(url: "https://example.com/records/1881-census-transcript",
                           title: "1881 Census transcript", raw: "manual")
        #expect(CensusCitationReader.censusYear(of: vague) == nil)
    }

    @Test func aSourceWithNoURLIsNotRecognisablyACensus() {
        let bare = FieldSource(origin: .manualMemory, raw: "1881 census, from memory",
                               addedAt: Date())
        #expect(CensusCitationReader.censusYear(of: bare) == nil)
    }

    // MARK: - Reading the year

    @Test func aFreeCenCensusCitationIsRead() {
        let freecen = source(
            url: "https://www.freecen.org.uk/search_records/5cffc7c8f4040b58a70bb1ff/hannah-gladwin-1861-derbyshire-dronfield-1836-",
            title: "Census 1861: William GLADWIN, Dronfield",
            notes: "\"1861 England Census,\" FreeCen, William GLADWIN, age 28, Dronfield.",
            raw: "freecen")
        #expect(CensusCitationReader.censusYear(of: freecen) == 1861)
    }

    @Test func theTNAClassPieceCarriesTheYearWhenNoneIsStated() {
        let piece = source(url: "https://www.familysearch.org/ark:/61903/1:1:Q27Y-2JHF",
                           title: "Census, Handsworth — RG11 4669/172 p.20 line 14")
        #expect(CensusCitationReader.censusYear(of: piece) == 1881)
    }

    @Test func the1939RegisterDoesNotReadAsThe1871Census() {
        // RG101 must not collide with RG10. Full digit runs are compared, and
        // nothing in the text says census.
        let register = source(url: "https://www.familysearch.org/ark:/61903/1:1:ZZZZ-999",
                              collection: "1939 England and Wales Register",
                              title: "1939 Register — RG101 5678A/012")
        #expect(CensusCitationReader.censusYear(of: register) == nil)
    }

    @Test func aCitationNamingTwoCensusesStaysSilent() {
        let ambiguous = source(url: "https://www.familysearch.org/ark:/61903/1:1:AAAA-111",
                               title: "Census: compared against the 1881 and 1891 returns")
        #expect(CensusCitationReader.censusYear(of: ambiguous) == nil)
    }

    @Test func aClassPieceContradictingTheStatedYearStaysSilent() {
        let inconsistent = source(url: "https://www.familysearch.org/ark:/61903/1:1:BBBB-222",
                                  title: "1891 England Census — RG11 4669/172")
        #expect(CensusCitationReader.censusYear(of: inconsistent) == nil)
    }

    @Test func anAmbiguousHO107PieceWithNoStatedYearStaysSilent() {
        // HO107 covers both 1841 and 1851 — it proves census-ness but cannot pin
        // the year, and a wrong year would send the user to the wrong census.
        let ho107 = source(url: "https://www.familysearch.org/ark:/61903/1:1:M7SB-YZJ",
                           title: "HO107 195/20 book 6 p.8 line 21")
        #expect(CensusCitationReader.censusYear(of: ho107) == nil)
    }

    @Test func theYearCatalogueIsCensusTypesNotASecondList() {
        #expect(CensusCitationReader.censusYears == Set(CensusType.allCases.compactMap(\.year)))
        #expect(CensusCitationReader.censusYears.contains(1841))
        #expect(!CensusCitationReader.censusYears.contains(1939))
    }

    // MARK: - Interaction with censusUnabsorbed

    @Test func aYearAlreadyCarriedByAnEventIsNeverReported() {
        // `censusUnabsorbed` describes an APPLIED census whose household names
        // relatives not on the tree — it presupposes the census is carried. This
        // rule requires the ABSENCE of a census event for the year, so per
        // (profile, year) the two can never describe the same row.
        let subject = hannah(sources: [
            .lastName: [the1841Citation],
            .birthDate: [source(url: "https://www.familysearch.org/ark:/61903/1:1:CCCC-333",
                                title: "Census 1851: Hannah Hewkin, Dronfield")],
        ])
        let years = CitedCensusWithoutEventRule.missingCensusEventYears(
            for: subject,
            in: snapshot(subject, events: [censusEvent(date: "1851")]))
        #expect(years.map { $0.year } == [1841])
    }

    @Test func severalUncarriedYearsCollapseIntoOneRow() {
        let subject = hannah(sources: [
            .lastName: [the1841Citation],
            .birthLocation: [source(url: "https://www.familysearch.org/ark:/61903/1:1:CCCC-333",
                                    title: "Census 1851: Hannah Hewkin, Dronfield")],
        ])
        let results = fire(subject)
        #expect(results.count == 1, "one row per profile, not one per year")
        #expect(results.first?.message.contains("1841 and 1851") == true)
    }

    // MARK: - Registry

    @Test func theRuleIsRegisteredAsAGap() {
        let rule = AuditRules.builtIn.first { $0.id == "citedCensusWithoutEvent" }
        #expect(rule != nil)
        #expect(rule?.category == .gap)
        #expect(rule?.defaultSeverity == .info)
    }
}
