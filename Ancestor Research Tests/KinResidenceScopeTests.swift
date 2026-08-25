import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Owner dogfood 2026-08-25, run FB03A519 (EV8 + EV7b).
///
/// EV8 — William Gladwin was born Teversall, Nottinghamshire, and that
/// birthplace was his only place fact, so every FreeCEN probe went to NTT on
/// both axes while he spent his whole adult life in Derbyshire and the West
/// Riding. Seven of eight census years came back empty. The evidence needed to
/// break the loop was one edge away: his wife was born Unstone, Derbyshire and
/// his daughter Whittington, Derbyshire, both already on the tree.
///
/// EV7b — the same family's parents' marriage was searched on FreeBMD twice
/// under the surname "Wheatman", a GEDCOM-only value with no citation and
/// wrong. Both empties were banked as durable negatives, so the app went on
/// suppressing the search that found the real Gladwin × HEWKIN marriage at
/// 7b/741 the moment the surname was corrected.
@MainActor
struct KinResidenceScopeTests {

    // MARK: - Helpers

    private func person(
        _ id: String, given: String, surname: String,
        birthYear: String? = nil, birthPlace: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, lastName: surname,
            gender: nil, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthPlace,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: sources, disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent,
                     role: nil, subtype: .biological,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    private func spouseEdge(
        _ a: String, _ b: String, place: String? = nil, code: String? = nil
    ) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse,
                     role: nil, subtype: .unknown,
                     marriageDate: nil, marriageLocation: place,
                     marriageLocationCode: code, divorceDate: nil)
    }

    private func gedcomSource(_ raw: String) -> FieldSource {
        FieldSource(origin: .gedcom, raw: raw, addedAt: Date())
    }

    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func source(_ dispatcher: SearchDispatcher, _ id: String) -> (any RecordSource)? {
        dispatcher.registry.allSources().first { $0.sourceID == id }
    }

    /// The Gladwin shape: subject anchored in one county, every relative
    /// evidenced in another.
    private func gladwinSnapshot() -> (Profile, FamilyGraphSnapshot) {
        let william = person("w", given: "William", surname: "Gladwin",
                             birthYear: "1836", birthPlace: "Teversall, Nottinghamshire")
        let hannah = person("h", given: "Hannah", surname: "Hewkin",
                            birthYear: "1838", birthPlace: "Unstone, Derbyshire")
        let sarah = person("s", given: "Sarah", surname: "Gladwin",
                           birthYear: "1862", birthPlace: "Whittington, Derbyshire")
        let snapshot = FamilyGraphSnapshot(
            profiles: [william.id: william, hannah.id: hannah, sarah.id: sarah],
            relationships: [spouseEdge("w", "h"), parentEdge("w", "s"), parentEdge("h", "s")])
        return (william, snapshot)
    }

    // MARK: - EV8: kin places become residence axes

    /// The headline: a subject whose birthplace county differs from every
    /// relative's place produces FreeCEN queries in the RELATIVES' county too,
    /// not only in the birth county — at the default County scope, with no
    /// widening of the picker.
    @Test func censusProbesReachTheCountyTheFamilyLivedIn() {
        let (william, snapshot) = gladwinSnapshot()
        let subject = ResearchSubject.fromProfile(william, snapshot: snapshot)
        #expect(subject.homeChapmanCode == "NTT",
                "the anchor is still a fact about HIM — kin evidence never moves it")
        #expect(subject.kinResidenceAxes.map(\.chapmanCode) == ["DBY"])
        #expect(subject.kinResidenceAxes.first?.support == 2,
                "wife's birthplace + daughter's birthplace both name Derbyshire")

        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        let queries = dispatcher.buildQueriesForTest(
            source: cen, subject: subject, recordType: .census, scope: .county)
        var codes: Set<String> = []
        for q in queries {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            if let single = p.chapmanCode { codes.insert(single) }
            for c in p.chapmanCodes ?? [] { codes.insert(c) }
        }
        #expect(codes.contains("DBY"), "the county the wife and daughter place him in is searched")
        #expect(codes.contains("NTT"), "additive — the birth county is never dropped")
    }

    /// A subject whose kin are in the SAME county as their birthplace gets the
    /// pre-existing single-county fan-out, byte for byte.
    @Test func kinInTheHomeCountyChangeNothing() {
        let john = person("j", given: "John", surname: "Wheeldon",
                          birthYear: "1836", birthPlace: "Cromford, Derbyshire")
        let ruth = person("r", given: "Ruth", surname: "Lee",
                          birthYear: "1838", birthPlace: "Holloway, Derbyshire")
        let snapshot = FamilyGraphSnapshot(
            profiles: [john.id: john, ruth.id: ruth],
            relationships: [spouseEdge("j", "r")])
        let subject = ResearchSubject.fromProfile(john, snapshot: snapshot)
        #expect(subject.kinResidenceAxes.isEmpty, "the home county is not its own extra axis")

        let dispatcher = makeDispatcher()
        guard let cen = source(dispatcher, "freecen") else {
            Issue.record("freecen not registered"); return
        }
        for q in dispatcher.buildQueriesForTest(
            source: cen, subject: subject, recordType: .census, scope: .county) {
            guard case .freeCen(let p) = q.sourceParams else { continue }
            #expect(p.chapmanCode == "DBY" && p.chapmanCodes == nil)
        }
    }

    /// A child's census page is the strongest residence signal on the tree —
    /// a household enumerated together IS the family's address that year.
    @Test func childCensusPlaceCountsAsResidenceEvidence() {
        let father = person("f", given: "William", surname: "Gladwin",
                            birthYear: "1836", birthPlace: "Teversall, Nottinghamshire")
        let child = person("c", given: "Sarah", surname: "Gladwin", birthYear: "1862")
        let census = LifeEvent(
            id: UUID(), profileID: "c", type: .census,
            date: GenealogicalDate(parsing: "1881"),
            location: "Handsworth, Yorkshire")
        let snapshot = FamilyGraphSnapshot(
            profiles: [father.id: father, child.id: child],
            relationships: [parentEdge("f", "c")],
            lifeEvents: ["c": [census]])
        let subject = ResearchSubject.fromProfile(father, snapshot: snapshot)
        let codes = subject.kinResidenceAxes.map(\.chapmanCode)
        #expect(codes.contains("WRY"), "umbrella counties expand to codes the forms actually tag")
        #expect(!codes.contains("YKS"), "the umbrella literal is a code no form tags")
    }

    /// Sensitive events must never leave the app — the same rule the subject's
    /// own residence axes apply, enforced one edge away too.
    @Test func sensitiveChildCensusIsExcluded() {
        let father = person("f", given: "William", surname: "Gladwin",
                            birthYear: "1836", birthPlace: "Teversall, Nottinghamshire")
        let child = person("c", given: "Sarah", surname: "Gladwin", birthYear: "1862")
        let census = LifeEvent(
            id: UUID(), profileID: "c", type: .census,
            date: GenealogicalDate(parsing: "1881"),
            location: "Chesterfield, Derbyshire", sensitive: true)
        let snapshot = FamilyGraphSnapshot(
            profiles: [father.id: father, child.id: child],
            relationships: [parentEdge("f", "c")],
            lifeEvents: ["c": [census]])
        #expect(ResearchSubject.fromProfile(father, snapshot: snapshot).kinResidenceAxes.isEmpty)
    }

    /// Ranked by how many kin facts back each county, capped so a wide family
    /// cannot turn one subject's census sweep into a national one. Each extra
    /// code costs one request per census YEAR against a volunteer server.
    @Test func kinCountiesAreRankedAndCapped() {
        let subject = person("x", given: "William", surname: "Gladwin",
                             birthYear: "1836", birthPlace: "Teversall, Nottinghamshire")
        // DBY: 3 facts. STS: 2. KEN: 1. Cap keeps the head of the list.
        var profiles: [String: Profile] = [subject.id: subject]
        var edges: [Relationship] = []
        let kin: [(String, String)] = [
            ("k1", "Unstone, Derbyshire"), ("k2", "Whittington, Derbyshire"),
            ("k3", "Bolsover, Derbyshire"), ("k4", "Leek, Staffordshire"),
            ("k5", "Cheadle, Staffordshire"), ("k6", "Maidstone, Kent"),
        ]
        for (id, place) in kin {
            profiles[id] = person(id, given: "Kin", surname: "Gladwin",
                                  birthYear: "1862", birthPlace: place)
            edges.append(parentEdge(subject.id, id))
        }
        let ranked = ResearchSubject.rankKinResidenceCounties(
            for: subject,
            snapshot: FamilyGraphSnapshot(profiles: profiles, relationships: edges),
            home: "NTT")
        #expect(ranked.map(\.chapmanCode) == ["DBY", "STS"])
        #expect(ranked.map(\.support) == [3, 2])
        #expect(ranked.count <= ResearchSubject.maxKinResidenceCounties)
    }

    /// A marriage place is a family place too.
    @Test func marriagePlaceCountsAsKinEvidence() {
        let groom = person("g", given: "William", surname: "Gladwin",
                           birthYear: "1836", birthPlace: "Teversall, Nottinghamshire")
        let bride = person("b", given: "Hannah", surname: "Hewkin")
        let snapshot = FamilyGraphSnapshot(
            profiles: [groom.id: groom, bride.id: bride],
            relationships: [spouseEdge("g", "b", place: "Chesterfield, Derbyshire")])
        let subject = ResearchSubject.fromProfile(groom, snapshot: snapshot)
        #expect(subject.kinResidenceAxes.map(\.chapmanCode) == ["DBY"])
    }

    // MARK: - EV8: the same evidence, the same ceiling, on every source

    /// FreeREG and FreeBMD take kin counties through the SAME `.adjacent`
    /// ceiling their existing extra-county arms use (2026-08-23 ruling: a
    /// County search reaches exactly the county the picker names). A county
    /// inferred from a relative is a weaker reason to cross a county line than
    /// the subject's own recorded death place, not a stronger one.
    @Test func kinCountiesRideTheAdjacentCeilingOnFreeREGAndFreeBMD() {
        let dispatcher = makeDispatcher()
        guard let reg = source(dispatcher, "freereg"), let bmd = source(dispatcher, "freebmd") else {
            Issue.record("freereg/freebmd not registered"); return
        }
        // Kent, not a Derbyshire neighbour: at .adjacent it can only arrive
        // through the kin arm, so the assertion proves that arm and nothing else.
        var subject = ResearchSubject(
            surname: "Gladwin", givenName: "William",
            birthYearFrom: 1836, birthYearTo: 1836,
            gender: .male, mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY")
        subject.kinResidenceAxes = [
            KinResidenceAxis(chapmanCode: "KEN", support: 1, evidence: "child born Maidstone, Kent"),
        ]

        func regCodes(_ scope: ResearchScope) -> Set<String> {
            var out: Set<String> = []
            for q in dispatcher.buildQueriesForTest(
                source: reg, subject: subject, recordType: .baptism, scope: scope) {
                guard case .freeREG(let p) = q.sourceParams else { continue }
                if let single = p.chapmanCode { out.insert(single) }
                for c in p.chapmanCodes ?? [] { out.insert(c) }
            }
            return out
        }
        #expect(regCodes(.adjacent).isSuperset(of: ["DBY", "KEN"]))
        #expect(!regCodes(.county).contains("KEN"),
                "County scope must search exactly what the picker says")

        func bmdCounties(_ scope: ResearchScope) -> [String] {
            dispatcher.buildQueriesForTest(
                source: bmd, subject: subject, recordType: .birth, scope: scope,
                freeBMDCountyQueriesEnabled: true
            ).compactMap { q in
                guard case .freeBMD(let p) = q.sourceParams else { return nil }
                return p.countyCode
            }
        }
        #expect(bmdCounties(.adjacent).contains { $0.hasPrefix("KEN") })
        #expect(!bmdCounties(.county).contains { $0.hasPrefix("KEN") })
    }

    // MARK: - EV7b: a negative built on an uncited premise

    @Test func uncitedProvenanceReadsTheProfilesOwnSources() {
        let bare = person("a", given: "Hannah", surname: "Wheatman")
        #expect(ResearchSubject.uncitedProvenance(of: .lastName, on: bare) == "no citation")

        let imported = person("b", given: "Hannah", surname: "Wheatman",
                              sources: [.lastName: [gedcomSource("Wheatman")]])
        #expect(ResearchSubject.uncitedProvenance(of: .lastName, on: imported)
                == "gedcom import, no citation")

        var cited = imported
        cited.sources[.lastName] = [FieldSource(
            origin: .freebmd, raw: "Hewkin", addedAt: Date(),
            citation: Citation(title: "Marriages Jun 1858", url: "https://www.freebmd.org.uk/x"))]
        #expect(ResearchSubject.uncitedProvenance(of: .lastName, on: cited) == nil)

        var handEntered = imported
        handEntered.sources[.lastName] = [FieldSource(
            origin: .manualRecord, raw: "Hewkin", addedAt: Date())]
        #expect(ResearchSubject.uncitedProvenance(of: .lastName, on: handEntered) == nil,
                "a value the user investigated stands on its own")
    }

    /// The premise set is deliberately narrow: a surname OTHER than the
    /// subject's own, on a relative, that the tree cannot cite.
    @Test func onlyUncitedCrossProfileSurnamesBecomePremises() {
        let subject = person("g", given: "John", surname: "Gladwin")
        let wheatman = person("w", given: "Hannah", surname: "Wheatman",
                              sources: [.lastName: [gedcomSource("Wheatman")]])
        let premises = ResearchSubject.unverifiedKinPremises(
            for: subject, spouse: wheatman, mother: nil)
        #expect(premises.map(\.axis) == [.spouseSurname])
        #expect(premises.first?.value == "Wheatman")
        #expect(premises.first?.phrase == "the spouse surname \"Wheatman\" (gedcom import, no citation)")

        // A spouse recorded under the MARRIED surname adds no assumption the
        // subject's own surname did not already carry.
        let sameName = person("s", given: "Hannah", surname: "Gladwin",
                              sources: [.lastName: [gedcomSource("Gladwin")]])
        #expect(ResearchSubject.unverifiedKinPremises(
            for: subject, spouse: sameName, mother: nil).isEmpty)
    }

    /// An MMN recorded on the subject with no linked mother is the classic
    /// shape for early generations — and the exact shape of the failure.
    @Test func subjectRecordedMMNIsAPremiseWhenUncited() {
        var subject = person("g", given: "John", surname: "Gladwin")
        subject.mothersMaidenName = "Wheatman"
        subject.sources[.mothersMaidenName] = [gedcomSource("Wheatman")]
        let premises = ResearchSubject.unverifiedKinPremises(
            for: subject, spouse: nil, mother: nil)
        #expect(premises.map(\.axis) == [.motherSurname])
    }

    /// A premise only counts on the queries that actually PUT IT ON THE WIRE.
    @Test func premiseAppliesOnlyToTheAxisThatCarriesIt() {
        var subject = ResearchSubject(
            surname: "Gladwin", givenName: "John",
            birthYearFrom: 1830, birthYearTo: 1830,
            mode: .extend, familyContext: nil, homeChapmanCode: "DBY")
        subject.unverifiedKinPremises = [
            KinPremise(axis: .spouseSurname, value: "Wheatman", provenance: "no citation"),
        ]
        #expect(SearchDispatcher.unverifiedPremise(
            subject: subject, sourceID: "freebmd", recordType: .marriage) != nil)
        #expect(SearchDispatcher.unverifiedPremise(
            subject: subject, sourceID: "freebmd", recordType: .birth) == nil,
                "FreeBMD's s_surname is a spouse surname on marriages only")
        #expect(SearchDispatcher.unverifiedPremise(
            subject: subject, sourceID: "freecen", recordType: .marriage) == nil,
                "FreeCEN never sends a spouse surname")
    }

    /// The GRO birth index has no mother's-maiden-name column before Sep 1911,
    /// so a Victorian birth cannot be resting on an MMN it never sent.
    @Test func mmnPremiseRespectsTheFreeBMDEraGate() {
        func subject(birthYear: Int) -> ResearchSubject {
            var s = ResearchSubject(
                surname: "Gladwin", givenName: "John",
                birthYearFrom: birthYear, birthYearTo: birthYear,
                mode: .extend, familyContext: nil, homeChapmanCode: "DBY")
            s.unverifiedKinPremises = [
                KinPremise(axis: .motherSurname, value: "Wheatman", provenance: "no citation"),
            ]
            return s
        }
        #expect(SearchDispatcher.unverifiedPremise(
            subject: subject(birthYear: 1858), sourceID: "freebmd", recordType: .birth) == nil)
        #expect(SearchDispatcher.unverifiedPremise(
            subject: subject(birthYear: 1930), sourceID: "freebmd", recordType: .birth) != nil)
    }

    /// The persistence gate: an empty answer to a question we asked wrong is
    /// not evidence of absence, and must never earn a durable row.
    @Test func premiseBearingEmptiesAreNotDurableNegatives() {
        let clean = SearchOutcomeEntry(
            sourceID: "freebmd", recordType: .birth, strictness: .strict,
            queryKey: "freebmd|birth|k1", outcome: SearchOutcome(resultCount: 0))
        let assumed = SearchOutcomeEntry(
            sourceID: "freebmd", recordType: .marriage, strictness: .strict,
            queryKey: "freebmd|marriage|k2", outcome: SearchOutcome(resultCount: 0),
            unverifiedPremise: "the spouse surname \"Wheatman\" (gedcom import, no citation)")

        let keys = NegativeSearchAggregator.genuineNegativeKeys(
            outcomes: [clean, assumed], scoredRecords: [])
        #expect(keys.map(\.queryKey) == ["freebmd|birth|k1"])

        let negatives = NegativeSearchAggregator.genuineNegatives(
            outcomes: [clean, assumed], scoredRecords: [])
        #expect(negatives.map(\.recordType) == [.birth],
                "a pair made only of premise-bearing queries yields no negative at all")

        let assumedRows = NegativeSearchAggregator.assumedNegatives(
            outcomes: [clean, assumed], scoredRecords: [])
        #expect(assumedRows.map(\.queryKey) == ["freebmd|marriage|k2"])
        #expect(assumedRows.first?.caveat
                == "searched, but the query assumed the spouse surname \"Wheatman\" (gedcom import, no citation), which is unverified")
    }
}
