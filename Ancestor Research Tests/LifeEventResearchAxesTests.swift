import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Stage 2 roadmap — "life events feed research axes". User-entered Residence
/// and Burial LifeEvents become SOFT search axes: FS census queries carry the
/// residence place, FreeCEN adds the residence county per covered census year
/// (additively — home county never dropped), burial-shape queries prefer the
/// burial event's place (FS deathLikePlace, FAG location, FreeREG county).
/// Anchored to the Elsie Twyford case: a user-added Youlgreave Residence
/// event was research-inert.
@MainActor
struct LifeEventResearchAxesTests {

    // MARK: - Helpers

    private func profile(_ id: String = "p1") -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: "Elsie", middleName: nil, lastName: "Twyford",
            gender: .female, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1927"), birthLocation: "Bakewell, Derbyshire",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func snapshot(_ profile: Profile, events: [LifeEvent]) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: [],
            lifeEvents: [profile.id: events])
    }

    private func residenceEvent(
        profileID: String = "p1", location: String?, locationCode: String? = nil,
        date: String? = nil, endDate: String? = nil, sensitive: Bool = false
    ) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: profileID, type: .residence,
            date: date.map { GenealogicalDate(parsing: $0) },
            endDate: endDate.map { GenealogicalDate(parsing: $0) },
            location: location, locationCode: locationCode,
            sensitive: sensitive)
    }

    // MARK: - Derivation (fromProfile reads snapshot.lifeEvents)

    @Test func residenceEventBecomesAxisWithCountyAndWindow() {
        let p = profile()
        let snap = snapshot(p, events: [
            residenceEvent(location: "Youlgreave, Derbyshire", date: "1935", endDate: "1950"),
        ])
        let subject = ResearchSubject.fromProfile(p, snapshot: snap)
        #expect(subject.residenceAxes.count == 1)
        let axis = subject.residenceAxes[0]
        #expect(axis.place == "Youlgreave, Derbyshire")
        #expect(axis.chapmanCode == "DBY", "county suffix runs the same derivation as profile fields")
        #expect(axis.yearFrom == 1935)
        #expect(axis.yearTo == 1950)
    }

    /// The common case: user typed just a place, no dates → open window that
    /// covers every year; bare village → no derivable county (nil, tolerated).
    @Test func undatedBareVillageResidenceIsOpenWindow() {
        let p = profile()
        let snap = snapshot(p, events: [residenceEvent(location: "Youlgreave")])
        let subject = ResearchSubject.fromProfile(p, snapshot: snap)
        let axis = subject.residenceAxes[0]
        #expect(axis.yearFrom == nil && axis.yearTo == nil)
        #expect(axis.covers(1841) && axis.covers(1921))
        #expect(axis.chapmanCode == nil, "bare village without county suffix stays nil — never guessed")
    }

    /// A gazetteer locationCode wins over free-text parsing (tier 1).
    @Test func locationCodeTierSuppliesCounty() {
        let p = profile()
        let snap = snapshot(p, events: [
            residenceEvent(location: "Youlgreave", locationCode: "DBY:Youlgreave"),
        ])
        let subject = ResearchSubject.fromProfile(p, snapshot: snap)
        #expect(subject.residenceAxes[0].chapmanCode == "DBY")
    }

    /// Sensitive events must never leave the app — excluded before any text
    /// could reach an outbound query, for residence AND burial alike.
    @Test func sensitiveEventsAreExcluded() {
        let p = profile()
        let snap = snapshot(p, events: [
            residenceEvent(location: "Youlgreave, Derbyshire", sensitive: true),
            LifeEvent(id: UUID(), profileID: p.id, type: .burial,
                      location: "Bakewell, Derbyshire", sensitive: true),
        ])
        let subject = ResearchSubject.fromProfile(p, snapshot: snap)
        #expect(subject.residenceAxes.isEmpty)
        #expect(subject.burialPlace == nil)
        #expect(subject.burialChapmanCode == nil)
    }

    /// A place-less burial stub must never shadow a located burial event,
    /// whatever the UUID order.
    @Test func locatedBurialEventBeatsPlacelessStub() {
        let p = profile()
        let smallUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let bigUUID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let stub = LifeEvent(id: smallUUID, profileID: p.id, type: .burial, location: nil)
        let located = LifeEvent(id: bigUUID, profileID: p.id, type: .burial,
                                location: "Bakewell, Derbyshire")
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [stub, located]))
        #expect(subject.burialPlace == "Bakewell, Derbyshire")
        #expect(subject.burialChapmanCode == "DBY")
    }

    /// A cemetery-only burial with a gazetteer code composes the county in
    /// ("St. Anne Churchyard, Derbyshire") — a bare cemetery string is a
    /// weak match key for external sources.
    @Test func cemeteryComposesCountyWhenGazetteerCodeKnown() {
        let p = profile()
        let burial = LifeEvent(
            id: UUID(), profileID: p.id, type: .burial,
            location: nil, locationCode: "DBY:Baslow",
            details: .burial(BurialDetails(cemetery: "St. Anne Churchyard")))
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [burial]))
        #expect(subject.burialPlace == "St. Anne Churchyard, Derbyshire")
        #expect(subject.burialChapmanCode == "DBY")
    }

    @Test func residenceWithoutLocationIsSkipped() {
        let p = profile()
        let snap = snapshot(p, events: [residenceEvent(location: "  ")])
        let subject = ResearchSubject.fromProfile(p, snapshot: snap)
        #expect(subject.residenceAxes.isEmpty)
    }

    @Test func burialEventLocationBecomesBurialPlace() {
        let p = profile()
        let burial = LifeEvent(
            id: UUID(), profileID: p.id, type: .burial,
            date: GenealogicalDate(parsing: "2011"),
            location: "Bakewell, Derbyshire")
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [burial]))
        #expect(subject.burialPlace == "Bakewell, Derbyshire")
        #expect(subject.burialChapmanCode == "DBY")
    }

    /// No location on the burial event → the structured cemetery name serves.
    @Test func burialCemeteryDetailIsTheFallback() {
        let p = profile()
        let burial = LifeEvent(
            id: UUID(), profileID: p.id, type: .burial,
            location: nil,
            details: .burial(BurialDetails(cemetery: "St. Anne Churchyard")))
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [burial]))
        #expect(subject.burialPlace == "St. Anne Churchyard")
    }

    /// Regression: no life events → no axes, identical subject shape to before.
    @Test func noEventsMeansNoAxes() {
        let p = profile()
        let subject = ResearchSubject.fromProfile(
            p, snapshot: FamilyGraphSnapshot(profiles: [p.id: p], relationships: []))
        #expect(subject.residenceAxes.isEmpty)
        #expect(subject.burialPlace == nil)
        #expect(subject.burialChapmanCode == nil)
    }

    // MARK: - DS-15: aliveAsOf derived from accepted alive-events

    @Test func censusEventSetsAliveAsOf() {
        let p = profile()
        let census = LifeEvent(id: UUID(), profileID: p.id, type: .census,
                               date: GenealogicalDate(parsing: "1939"),
                               location: "Bakewell, Derbyshire")
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [census]))
        #expect(subject.aliveAsOf == 1939)
    }

    @Test func burialAndProbateNeverImplyAlive() {
        let p = profile()
        let burial = LifeEvent(id: UUID(), profileID: p.id, type: .burial,
                               date: GenealogicalDate(parsing: "2011"), location: "Bakewell")
        let probate = LifeEvent(id: UUID(), profileID: p.id, type: .probate,
                                date: GenealogicalDate(parsing: "2012"), location: nil)
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [burial, probate]))
        #expect(subject.aliveAsOf == nil, "post-death events must never set aliveAsOf")
    }

    @Test func latestAliveEventWins() {
        let p = profile()
        let census = LifeEvent(id: UUID(), profileID: p.id, type: .census,
                               date: GenealogicalDate(parsing: "1939"), location: nil)
        let residence = LifeEvent(id: UUID(), profileID: p.id, type: .residence,
                                  date: GenealogicalDate(parsing: "1961"), location: "Bakewell")
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [census, residence]))
        #expect(subject.aliveAsOf == 1961)
    }

    @Test func sensitiveAliveEventDoesNotSetAliveAsOf() {
        // The derived year surfaces in the scorer's verdict reason, so a
        // sensitive event must not originate it (consistent with the axes).
        let p = profile()
        let census = LifeEvent(id: UUID(), profileID: p.id, type: .census,
                               date: GenealogicalDate(parsing: "1939"), location: nil,
                               sensitive: true)
        let subject = ResearchSubject.fromProfile(p, snapshot: snapshot(p, events: [census]))
        #expect(subject.aliveAsOf == nil)
    }

    // MARK: - ResidenceAxis window semantics

    @Test func axisWindowSemantics() {
        let bounded = ResidenceAxis(place: "X", chapmanCode: nil, yearFrom: 1898, yearTo: 1905)
        #expect(bounded.covers(1901))
        #expect(!bounded.covers(1891) && !bounded.covers(1911))
        #expect(bounded.overlaps(from: 1900, to: 1960))
        #expect(!bounded.overlaps(from: 1906, to: nil))
        #expect(!bounded.overlaps(from: nil, to: 1897))

        let openForward = ResidenceAxis(place: "X", chapmanCode: nil, yearFrom: 1930, yearTo: nil)
        #expect(openForward.covers(1995) && !openForward.covers(1929))
        #expect(openForward.overlaps(from: 1880, to: 1960))
    }

    // MARK: - Dispatcher: query shapes

    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func subject(
        residenceAxes: [ResidenceAxis] = [],
        burialPlace: String? = nil,
        burialChapman: String? = nil,
        deathLocation: String? = nil
    ) -> ResearchSubject {
        ResearchSubject(
            surname: "Marshall",
            givenName: "Harry",
            birthYearFrom: 1880, birthYearTo: 1880,
            gender: .male,
            region: .county("Derbyshire"),
            deathLocation: deathLocation,
            mode: .extend,
            familyContext: nil,
            homeChapmanCode: "DBY",
            residenceAxes: residenceAxes,
            burialPlace: burialPlace,
            burialChapmanCode: burialChapman
        )
    }

    private func source(_ dispatcher: SearchDispatcher, _ id: String) -> (any RecordSource)? {
        dispatcher.registry.allSources().first { $0.sourceID == id }
    }

    // The three FamilySearch residence/burial axis tests were removed with
    // the FS records plugin (owner pivot 2026-07-21 — FS is no longer a data
    // source, so it builds no query axes). The same axis-composition logic
    // (residence place composed with its county; census-year coverage gate;
    // burial-place-over-deathLocation) stays covered by the FreeCEN / FreeREG /
    // FindAGrave axis tests below, which exercise the identical dispatcher path.

    /// FreeCEN: the residence-event county joins the census-year probes ONLY
    /// for years its window covers, ADDITIVELY (the home county's own query
    /// is untouched), and routed through the FT-27 batching gate — with the
    /// gate off (the shipping default; the repeated `chapman_codes[]` wire
    /// idiom is unverified) each county stays its own proven single-code
    /// query rather than an inline batch.
    @Test func freeCenAddsResidenceCountyForCoveredYearsOnly() {
        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        let axis = ResidenceAxis(place: "Mansfield, Nottinghamshire", chapmanCode: "NTT",
                                 yearFrom: 1898, yearTo: 1905)
        let queries = dispatcher.buildQueriesForTest(
            source: cen, subject: subject(residenceAxes: [axis]),
            recordType: .census, scope: .county)

        func shapes(forYear year: Int) -> [(single: String?, batch: [String]?)] {
            queries.compactMap { q in
                guard case .freeCen(let p) = q.sourceParams, p.censusYear == year else { return nil }
                return (p.chapmanCode, p.chapmanCodes)
            }
        }
        let covered = shapes(forYear: 1901)
        #expect(covered.map(\.single) == ["DBY", "NTT"],
                "covered year probes home + residence county as separate single-code queries")
        #expect(covered.allSatisfy { $0.batch == nil },
                "no multi-code batch may reach the wire while the FT-27 gate is off")
        let uncovered = shapes(forYear: 1891)
        #expect(uncovered.map(\.single) == ["DBY"], "uncovered year keeps the home county only")
        #expect(uncovered.allSatisfy { $0.batch == nil })

        // No-axes baseline: byte-identical pre-existing wire shape.
        let baseline = dispatcher.buildQueriesForTest(
            source: cen, subject: subject(), recordType: .census, scope: .county)
        for q in baseline {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            #expect(p.chapmanCode == "DBY" && p.chapmanCodes == nil)
        }
    }

    /// Umbrella counties expand at the append: a Yorkshire residence
    /// contributes the ridings FreeCEN's form actually tags, never a dead
    /// literal "YKS".
    @Test func freeCenExpandsUmbrellaResidenceCounty() {
        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        let axis = ResidenceAxis(place: "Leeds, Yorkshire", chapmanCode: "YKS",
                                 yearFrom: nil, yearTo: nil)
        let queries = dispatcher.buildQueriesForTest(
            source: cen, subject: subject(residenceAxes: [axis]),
            recordType: .census, scope: .county)
        var singles: Set<String> = []
        for q in queries {
            if case .freeCen(let p) = q.sourceParams, let s = p.chapmanCode { singles.insert(s) }
        }
        #expect(singles.isSuperset(of: ["DBY", "WRY", "NRY", "ERY"]))
        #expect(!singles.contains("YKS"), "the umbrella literal is a code the form does not tag")
    }

    /// Residence-event codes never touch the .adjacent/.national axes — the
    /// birth-county axis and anchor-less sweeps already reach residents in
    /// every county, and the sweep must stay byte-identical (cache-key
    /// continuity on a budget-sensitive volunteer source).
    @Test func freeCenResidenceEventsAreBoundedScopeOnly() {
        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        let axis = ResidenceAxis(place: "Mansfield, Nottinghamshire", chapmanCode: "NTT",
                                 yearFrom: nil, yearTo: nil)
        // Anchored subject at .adjacent: birth-axis queries, no residence codes.
        let adjacent = dispatcher.buildQueriesForTest(
            source: cen, subject: subject(residenceAxes: [axis]),
            recordType: .census, scope: .adjacent)
        for q in adjacent {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            #expect(p.chapmanCode == nil && p.chapmanCodes == nil,
                    "adjacent scope rides the birth axis; event codes must not intrude")
            #expect(p.birthChapmanCode == "DBY")
        }
        // Anchor-less subject at .national: the sweep stays single-code.
        var anchorless = subject(residenceAxes: [axis])
        anchorless.homeChapmanCode = ""
        let sweep = dispatcher.buildQueriesForTest(
            source: cen, subject: anchorless, recordType: .census, scope: .national)
        for q in sweep {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            #expect(p.chapmanCodes == nil,
                    "the ~90-code sweep must not grow unverified 2-code batches")
        }
    }

    /// FreeREG burial probes include the burial event's county, additively;
    /// non-burial register types are unaffected.
    @Test func freeREGBurialIncludesBurialCounty() {
        let dispatcher = makeDispatcher()
        guard let reg = source(dispatcher, "freereg") else {
            Issue.record("freereg not registered"); return
        }
        let s = subject(burialPlace: "Mansfield, Nottinghamshire", burialChapman: "NTT")
        func allCodes(_ recordType: RecordType) -> Set<String> {
            var out: Set<String> = []
            for q in dispatcher.buildQueriesForTest(source: reg, subject: s, recordType: recordType, scope: .county) {
                if case .freeREG(let p) = q.sourceParams {
                    if let single = p.chapmanCode { out.insert(single) }
                    for c in p.chapmanCodes ?? [] { out.insert(c) }
                }
            }
            return out
        }
        #expect(allCodes(.burial).isSuperset(of: ["DBY", "NTT"]))
        #expect(!allCodes(.baptism).contains("NTT"), "burial county is gated to burial probes")

        // Umbrella expansion: a Yorkshire burial contributes the ridings
        // FreeREG's form actually tags — never the dead "YKS" literal.
        let yorks = subject(burialPlace: "Leeds, Yorkshire", burialChapman: "YKS")
        var yorksCodes: Set<String> = []
        for q in dispatcher.buildQueriesForTest(source: reg, subject: yorks, recordType: .burial, scope: .county) {
            if case .freeREG(let p) = q.sourceParams {
                if let single = p.chapmanCode { yorksCodes.insert(single) }
                for c in p.chapmanCodes ?? [] { yorksCodes.insert(c) }
            }
        }
        #expect(yorksCodes.isSuperset(of: ["DBY", "WRY", "NRY", "ERY"]))
        #expect(!yorksCodes.contains("YKS"))
    }

    /// FindAGrave's location filter prefers the burial event's place over
    /// deathLocation over the county guess.
    @Test func findAGraveLocationPrefersBurialPlace() {
        let dispatcher = makeDispatcher()
        guard let fag = source(dispatcher, "findagrave") else {
            Issue.record("findagrave not registered"); return
        }
        let s = subject(burialPlace: "Bakewell, Derbyshire", deathLocation: "Derby")
        let queries = dispatcher.buildQueriesForTest(source: fag, subject: s, recordType: .burial, scope: .county)
        guard case .findAGrave(let p)? = queries.first?.sourceParams else {
            Issue.record("no findagrave params"); return
        }
        #expect(p.location == "Bakewell, Derbyshire")
    }
}
