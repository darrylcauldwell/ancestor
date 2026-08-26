import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Owner dogfood 2026-08-26 (EV19) — a DISPUTED birthplace silently selects
/// the search region for BOTH the parish and the BMD axes, so the family's own
/// registration district is never searched.
///
/// William Gladwin (@I332233296774@) carries SIX FreeBMD *marriage*
/// negative-searches: the app looked six times and found nothing. The owner
/// found it by hand in ONE search — FreeBMD Marriages, Jun quarter 1858,
/// surname GLADWIN, district CHESTERFIELD → "Gladwin, William, Chesterfield,
/// 7b 741", verified against the GRO register scans. It was in the subject's
/// own registration district the whole time.
///
/// Every one of those six went to Nottinghamshire because his birthplace
/// "Teversall, Nottinghamshire" — the 1881 census value — selected the region,
/// and that value is under an OPEN `birthLocation` dispute against Ashover
/// (1861), Bolsover (1871) and Nottinghamshire (1891). One disputed value won
/// region selection unopposed and silently. The same anchor is why
/// `get_scored_records` returned 42 FreeREG parish rows of Nottinghamshire
/// namesake noise (GOULDING, GOLDING, GILDING at Gringley on the Hill,
/// Walkeringham, Misterton, Worksop, Mansfield…) while Dronfield, Unstone,
/// Whittington, Brampton and Chesterfield RD were never swept.
///
/// EV8 fixed this on the CENSUS axis only, and only for KIN-derived counties.
/// These tests cover the parish and BMD axes, the subject's own residence and
/// census places, and the dispute-blindness underneath all of it.
@MainActor
struct ContestedRegionScopeTests {

    // MARK: - Helpers

    private func censusSource(_ raw: String, year: Int) -> FieldSource {
        FieldSource(
            origin: .freecen, raw: raw,
            addedAt: Date(timeIntervalSince1970: TimeInterval(year)),
            citation: Citation(
                title: "\(year) census", url: "https://www.freecen.org.uk/search_records/\(year)"))
    }

    /// An OPEN dispute: no resolution recorded, so the user has not picked a
    /// winner. Same test `contestedFields` and `narrowBirthWindowFromSources`
    /// apply — "open" means one thing app-wide.
    private func openBirthplaceDispute() -> FieldDispute {
        FieldDispute(
            field: .birthLocation,
            reason: .valueMismatch,
            competingSources: [
                censusSource("Ashover, Derbyshire", year: 1861),
                censusSource("Bolsover, Derbyshire", year: 1871),
                censusSource("Teversall, Nottinghamshire", year: 1881),
                censusSource("Nottinghamshire", year: 1891),
            ],
            detectedAt: Date())
    }

    private func event(
        _ profileID: String, _ type: LifeEventType, at place: String, year: Int
    ) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: profileID, type: type,
            date: GenealogicalDate(parsing: String(year)),
            location: place)
    }

    /// William as the tree actually holds him: anchored on the disputed 1881
    /// birthplace, with his own attested Derbyshire residences and censuses.
    private func williamGladwin(
        disputed: Bool = true, withLifeEvents: Bool = true
    ) -> (Profile, FamilyGraphSnapshot) {
        let william = Profile(
            id: "w", externalIDs: [:], firstName: "William", lastName: "Gladwin",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1836"),
            birthLocation: "Teversall, Nottinghamshire",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:],
            disputes: disputed ? [.birthLocation: openBirthplaceDispute()] : [:])
        let events: [LifeEvent] = withLifeEvents ? [
            event("w", .residence, at: "Dronfield, Derbyshire", year: 1858),
            event("w", .census, at: "Unstone, Derbyshire", year: 1861),
            event("w", .census, at: "Whittington, Derbyshire", year: 1871),
            event("w", .residence, at: "Brampton, Derbyshire", year: 1875),
            event("w", .residence, at: "Chesterfield, Derbyshire", year: 1881),
        ] : []
        let snapshot = FamilyGraphSnapshot(
            profiles: [william.id: william], relationships: [],
            lifeEvents: withLifeEvents ? [william.id: events] : [:])
        return (william, snapshot)
    }

    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func source(_ dispatcher: SearchDispatcher, _ id: String) -> (any RecordSource)? {
        dispatcher.registry.allSources().first { $0.sourceID == id }
    }

    // MARK: - The derivation

    /// The headline. A subject whose region-selecting field is under open
    /// dispute produces a search region covering EVERY competing value's
    /// county plus every county he is attested to have lived in — with the
    /// anchor itself untouched, because kin and rivals never move a fact about
    /// this person.
    @Test func disputedBirthplaceWidensTheRegionToDerbyshire() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)

        #expect(subject.homeChapmanCode == "NTT",
                "the anchor is still a fact about HIM — widening never moves it")
        #expect(subject.contestedRegionFields == [.birthLocation])
        #expect(subject.supplementalRegionCodes.contains("DBY"),
                "Ashover, Bolsover and four Derbyshire residences all name DBY")

        // The residence-derived places must survive as PLACES, not collapse
        // into a bare county code: FreeREG and Find a Grave search by name.
        let places = subject.supplementalRegionPlaces
        for expected in ["Dronfield, Derbyshire", "Unstone, Derbyshire",
                         "Whittington, Derbyshire", "Brampton, Derbyshire",
                         "Chesterfield, Derbyshire"] {
            #expect(places.contains(expected), "\(expected) must reach the search region")
        }
        // …and the rival birthplaces too, which is what makes the union a
        // union rather than a second guess.
        #expect(places.contains("Ashover, Derbyshire"))
        #expect(places.contains("Bolsover, Derbyshire"))

        // The registration district the marriage was actually filed at.
        let districts = subject.supplementalRegionAxes.flatMap(\.districtIDs)
        #expect(districts.contains("DBY:Chesterfield-RD"),
                "Chesterfield RD is where FreeBMD holds Gladwin/1858/7b-741")
    }

    /// The falsification test. A subject with NO dispute and no residence
    /// events derives nothing supplemental at all, so every search the app
    /// already ran is unchanged, byte for byte.
    @Test func anUndisputedSubjectRegionIsUnchanged() {
        let (william, snapshot) = williamGladwin(disputed: false, withLifeEvents: false)
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)

        #expect(subject.homeChapmanCode == "NTT")
        #expect(subject.contestedRegionFields.isEmpty)
        #expect(subject.supplementalRegionAxes.isEmpty)
        #expect(subject.supplementalRegionCodes.isEmpty)
        #expect(subject.regionPremise == nil,
                "no dispute, no premise — the negative cache keeps working normally")
    }

    /// A resolved dispute is not an open one. The user picked a winner, so the
    /// winner selects the region exactly as an undisputed value would.
    @Test func aResolvedDisputeStopsWideningTheRegion() {
        let (william, snapshot) = williamGladwin()
        var resolved = william
        var dispute = openBirthplaceDispute()
        dispute.resolution = .accepted(
            censusSource("Teversall, Nottinghamshire", year: 1881))
        resolved.disputes = [.birthLocation: dispute]
        let subject = ResearchSubject.fromProfile(resolved, snapshot: snapshot)

        #expect(subject.contestedRegionFields.isEmpty)
        #expect(subject.regionPremise == nil)
        // The residences still widen — they are attested facts, not candidates
        // — but no rival birthplace does.
        #expect(!subject.supplementalRegionAxes.contains { $0.origin == .contestedField })
        #expect(subject.supplementalRegionCodes.contains("DBY"),
                "his own Derbyshire residences are evidence whatever the dispute says")
    }

    /// `.deferred` is the user saying "I am not deciding yet", which is an open
    /// dispute for every other consumer in the app and must be one here.
    @Test func aDeferredDisputeStillCountsAsOpen() {
        let (william, snapshot) = williamGladwin()
        var deferred = william
        var dispute = openBirthplaceDispute()
        dispute.resolution = .deferred
        deferred.disputes = [.birthLocation: dispute]
        let subject = ResearchSubject.fromProfile(deferred, snapshot: snapshot)

        #expect(subject.contestedRegionFields == [.birthLocation])
        #expect(subject.regionPremise != nil)
    }

    /// A sensitive life event's text must never reach an outbound query — the
    /// same rule `residenceAxes` applies, enforced at derivation.
    @Test func sensitiveResidencesNeverReachTheSearchRegion() {
        let william = Profile(
            id: "w", externalIDs: [:], firstName: "William", lastName: "Gladwin",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1836"),
            birthLocation: "Teversall, Nottinghamshire",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        var sensitive = event("w", .residence, at: "Brampton, Derbyshire", year: 1875)
        sensitive.sensitive = true
        let snapshot = FamilyGraphSnapshot(
            profiles: [william.id: william], relationships: [],
            lifeEvents: [william.id: [sensitive]])
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)

        #expect(subject.supplementalRegionPlaces.isEmpty)
        #expect(!subject.supplementalRegionCodes.contains("DBY"))
    }

    /// The county cap is a ceiling on requests, not a target — FreeCEN emits
    /// one request per census year per code.
    @Test func theSupplementalCountyCapHolds() {
        let (william, _) = williamGladwin()
        let events = (0..<8).map { i in
            // Eight residences in eight different counties.
            event("w", .residence, at: [
                "Derby, Derbyshire", "Nottingham, Nottinghamshire",
                "Sheffield, Yorkshire", "Leicester, Leicestershire",
                "Stafford, Staffordshire", "Lincoln, Lincolnshire",
                "Chester, Cheshire", "Warwick, Warwickshire",
            ][i], year: 1860 + i)
        }
        let axes = ResearchSubject.deriveSupplementalRegionAxes(
            for: william, lifeEvents: events, home: "NTT")
        // Counties, not codes: an umbrella county spends one slot and then
        // expands, so the code count may exceed the cap by design.
        let countiesRepresented = Set(axes.map(\.evidence))
        #expect(countiesRepresented.count <= ResearchSubject.maxSupplementalRegionCounties)
        #expect(!axes.contains { $0.chapmanCode == "NTT" }, "home is never supplemental")
    }

    // MARK: - The dispatch: every source that takes a region

    /// FreeBMD, at the DEFAULT County scope. This is the exact search that
    /// missed Gladwin/1858/Chesterfield six times.
    @Test func freeBMDMarriageProbeReachesTheDisputedRivalCounty() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        let dispatcher = makeDispatcher()
        guard let bmd = source(dispatcher, "freebmd") else {
            Issue.record("freebmd not registered"); return
        }
        let counties = dispatcher.buildQueriesForTest(
            source: bmd, subject: subject, recordType: .marriage, scope: .county,
            freeBMDCountyQueriesEnabled: true
        ).compactMap { q -> String? in
            guard case .freeBMD(let p) = q.sourceParams else { return nil }
            return p.countyCode
        }
        #expect(counties.contains { $0.hasPrefix("DBY") },
                "Derbyshire — where the marriage is — must be searched at County scope")
        #expect(counties.contains { $0.hasPrefix("NTT") },
                "additive: the anchor county is never dropped")
    }

    /// FreeREG, the parish half of EV19 — same widening, same scope, no
    /// `.adjacent` ceiling. 42 of the 84 scored rows were Nottinghamshire
    /// parish namesakes because this arm only ever saw NTT.
    @Test func freeREGParishProbeReachesTheResidenceCounty() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        let dispatcher = makeDispatcher()
        guard let reg = source(dispatcher, "freereg") else {
            Issue.record("freereg not registered"); return
        }
        var codes: Set<String> = []
        for q in dispatcher.buildQueriesForTest(
            source: reg, subject: subject, recordType: .parish, scope: .county) {
            guard case .freeREG(let p) = q.sourceParams else { continue }
            if let single = p.chapmanCode { codes.insert(single) }
            for c in p.chapmanCodes ?? [] { codes.insert(c) }
        }
        #expect(codes.contains("DBY"), "the parishes he actually lived in are swept")
        #expect(codes.contains("NTT"), "additive: the anchor county is never dropped")
    }

    /// FreeCEN at a bounded scope picks up the same counties, and — new with
    /// EV19 — the subject's own CENSUS places, which no axis read before.
    @Test func freeCenProbeReachesTheSubjectsOwnCensusCounty() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        var codes: Set<String> = []
        for q in dispatcher.buildQueriesForTest(
            source: cen, subject: subject, recordType: .census, scope: .county) {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            if let single = p.chapmanCode { codes.insert(single) }
            for c in p.chapmanCodes ?? [] { codes.insert(c) }
        }
        #expect(codes.contains("DBY"))
        #expect(codes.contains("NTT"))
    }

    /// At `.adjacent`/`.national` FreeCEN's axis is `birth_chapman_codes[]` —
    /// a BIRTH axis. A rival BIRTHPLACE earns one; a place he merely lived
    /// does not, because that would be a wrong axis rather than a wider one.
    @Test func freeCenBirthAxisTakesRivalBirthplacesOnly() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        #expect(subject.contestedBirthRegionCodes == ["DBY"])

        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        var birthCodes: Set<String> = []
        for q in dispatcher.buildQueriesForTest(
            source: cen, subject: subject, recordType: .census, scope: .adjacent) {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            if let birth = p.birthChapmanCode { birthCodes.insert(birth) }
        }
        #expect(birthCodes == ["NTT", "DBY"],
                "one birth axis per candidate birthplace, anchor included")

        // A residence-only widening must NOT reach the birth axis.
        let (plain, plainSnapshot) = williamGladwin(disputed: false)
        let undisputed = ResearchSubject.fromProfile(plain, snapshot: plainSnapshot)
        #expect(undisputed.supplementalRegionCodes.contains("DBY"))
        #expect(undisputed.contestedBirthRegionCodes.isEmpty,
                "a county he lived in is not a county he was born in")
    }

    /// Find a Grave takes ONE `location` per request, so the weakest rung —
    /// the birth-county guess — fans out over the candidate places instead.
    @Test func findAGravePinsFanOutWhenOnlyTheBirthCountyIsAvailable() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        let dispatcher = makeDispatcher()
        guard let fag = source(dispatcher, "findagrave") else {
            Issue.record("findagrave not registered"); return
        }
        let locations = dispatcher.buildQueriesForTest(
            source: fag, subject: subject, recordType: .burial, scope: .county
        ).compactMap { q -> String? in
            guard case .findAGrave(let p) = q.sourceParams else { return nil }
            return p.location
        }
        #expect(locations.contains("Teversall, Nottinghamshire"),
                "the existing pin is never dropped")
        #expect(locations.count > 1, "a disputed anchor earns extra pins")
        #expect(locations.count <= 1 + SearchDispatcher.maxFindAGraveExtraPins,
                "FAG is a scraped page — the cap is a hard request ceiling")
    }

    /// A recorded burial place is a fact about where this person ended up and
    /// needs no help: FAG stays a single pinned query, exactly as before.
    @Test func aRecordedBurialPlaceStopsTheFindAGraveFanOut() {
        let (william, snapshot) = williamGladwin()
        var subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        subject.burialPlace = "St Mary's, Chesterfield"
        let dispatcher = makeDispatcher()
        guard let fag = source(dispatcher, "findagrave") else {
            Issue.record("findagrave not registered"); return
        }
        let locations = dispatcher.buildQueriesForTest(
            source: fag, subject: subject, recordType: .burial, scope: .county
        ).compactMap { q -> String? in
            guard case .findAGrave(let p) = q.sourceParams else { return nil }
            return p.location
        }
        #expect(locations == ["St Mary's, Chesterfield"])
    }

    // MARK: - EV19 item 4: the poisoned negative searches

    /// The half that decides whether the fix looks like it did anything.
    /// `negative_searches` suppresses a re-fire for ~90 days; a DISPUTED value
    /// does not change, so the six Nottinghamshire keys keep matching. The
    /// premise seam is what unsticks them.
    @Test func aContestedRegionDisablesCrossRunSuppression() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)

        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "freebmd", scope: .county) != nil,
                "the exact fan-out that banked six Gladwin marriage negatives")
        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "freereg", scope: .county) != nil)
        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "freecen", scope: .county) != nil)

        // A region-free fan-out is untouched: marking a genuinely conclusive
        // negative "unproven" is the same dishonesty pointed the other way.
        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "freebmd", scope: .national) == nil,
                "national FreeBMD sends districtid=\"\" — no county on the wire")
        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "cwgc", scope: .county) == nil,
                "CWGC takes no region at all")
        #expect(SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "probate", scope: .county) == nil,
                "the Probate Calendar search carries no place axis")
    }

    /// The normal path stays exactly as it was: no dispute, no premise, and
    /// the cross-run negative cache keeps saving the traffic it was built to
    /// save.
    @Test func anUndisputedSubjectKeepsItsNegativeSuppression() {
        let (william, snapshot) = williamGladwin(disputed: false, withLifeEvents: false)
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        for sourceID in ["freebmd", "freereg", "freecen", "familysearch", "findagrave"] {
            #expect(SearchDispatcher.contestedRegionPremise(
                subject: subject, sourceID: sourceID, scope: .county) == nil)
        }
    }

    /// A premise-bearing empty must never earn a durable `negative_searches`
    /// row — otherwise the next run suppresses the corrected search and the
    /// profile stays poisoned for another 90 days.
    @Test func aRegionPremiseBearingEmptyIsNotBanked() {
        let (william, snapshot) = williamGladwin()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        guard let premise = SearchDispatcher.contestedRegionPremise(
            subject: subject, sourceID: "freebmd", scope: .county) else {
            Issue.record("expected a region premise for the Gladwin shape"); return
        }
        let poisoned = SearchOutcomeEntry(
            sourceID: "freebmd", recordType: .marriage, strictness: .strict,
            queryKey: "freebmd|marriage|NTT", outcome: SearchOutcome(resultCount: 0),
            unverifiedPremise: premise)

        let keys = NegativeSearchAggregator.genuineNegativeKeys(
            outcomes: [poisoned], scoredRecords: [])
        #expect(keys.isEmpty, "an empty answer to a question asked in the wrong county")

        let assumed = NegativeSearchAggregator.assumedNegatives(
            outcomes: [poisoned], scoredRecords: [])
        #expect(assumed.count == 1)
        #expect(assumed.first?.caveat.contains("under dispute") == true)
    }

    /// A stored negative still suppresses when the premise holds — the cache's
    /// whole reason for existing survives the fix.
    @Test func aCleanNegativeStillSuppressesWithoutAPremise() {
        let stamped = Date(timeIntervalSince1970: 1_750_000_000)
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "marriage",
                    queryKey: "freebmd|marriage|NTT", date: stamped)],
            window: .days(90),
            now: stamped.addingTimeInterval(60 * 60 * 24 * 10))
        #expect(cache.suppression(forQueryKey: "freebmd|marriage|NTT") != nil)
        #expect(cache.suppression(forQueryKey: "freebmd|marriage|DBY") == nil,
                "the widened county is a NEW key — it was never searched")
    }
}
