import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// A row the SCORER rules out is not a find, and must not stop the strictness
/// ladder.
///
/// Owner dogfood 2026-08-23. Mary Stevenson's strict parish tier returned three
/// rows: one baptism she had discarded by hand, one burial the scorer marked
/// impossible ("died 1825 but the subject is recorded alive in 1861"), and one
/// marriage at "max age ~0". The discard was filtered; the two impossibles
/// counted as finds. The ladder stopped at `.strict`, the `.variant` tier that
/// would have probed the STEPHENSON spelling never ran, and her baptism — the
/// record naming both her parents — was unreachable from inside the app.
///
/// The dispatcher already made this exact argument for human rejections:
/// "counting them made the reviewer's own work narrow the search… for a common
/// name in a big county the strict tier will nearly always return SOMETHING."
/// The machine's rejections were left out of it.
@MainActor
struct ImpossibleRowsDoNotStopTheLadderTests {

    /// Robert Cauldwell, b. 1880, d. 1916–18 — the shared dispatcher fixture.
    private func subject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: 1916, deathYearTo: 1918,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private func dispatcher(stub: VerdictStubSource) -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(stub)
        return SearchDispatcher(registry: registry)
    }

    /// PRECONDITION: the scorer really does rule a 1850 death impossible for a
    /// man born in 1880. If this ever stops holding, the tests below are
    /// asserting nothing.
    @Test func theScorerRulesAPreBirthDeathImpossible() {
        let record = VerdictStubSource.deathRecord(id: "x", sourceID: "s", year: 1850)
        let scored = RecordScorer.classify(
            record: record, subject: subject(), searchType: .death)
        #expect(scored.verdict == .impossible,
                "a death 30 years before the subject's birth must be impossible; got \(scored.verdict)")
    }

    /// THE SPECIMEN: a strict tier returning ONLY impossible rows must broaden.
    @Test func aTierOfOnlyImpossibleRowsBroadens() async {
        let stub = VerdictStubSource(impossibleAt: [.strict], plausibleAt: [])
        _ = await dispatcher(stub: stub).dispatch(
            subject: subject(), recordTypes: [.death], scope: .county, mode: .extend)
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose],
                "impossible rows are not a find — the ladder must broaden past them; got \(calls)")
    }

    /// CONTROL, and the more important half: a tier with a genuinely plausible
    /// row still STOPS. Without this the fix would just broaden everything and
    /// hammer the volunteer sources.
    @Test func aTierWithAPlausibleRowStillStops() async {
        let stub = VerdictStubSource(impossibleAt: [], plausibleAt: [.strict])
        _ = await dispatcher(stub: stub).dispatch(
            subject: subject(), recordTypes: [.death], scope: .county, mode: .extend)
        let calls = await stub.tierCalls
        #expect(calls == [.strict], "a real find must still stop the ladder; got \(calls)")
    }

    /// A tier mixing one impossible row with one plausible row stops — the
    /// plausible one is a find regardless of what sits beside it.
    @Test func onePlausibleRowAmongImpossiblesStillStops() async {
        let stub = VerdictStubSource(impossibleAt: [.strict], plausibleAt: [.strict])
        _ = await dispatcher(stub: stub).dispatch(
            subject: subject(), recordTypes: [.death], scope: .county, mode: .extend)
        let calls = await stub.tierCalls
        #expect(calls == [.strict])
    }

    /// Discarded AND impossible compose: a tier holding one of each is empty of
    /// finds and broadens. This is Mary's shape exactly.
    @Test func discardedPlusImpossibleIsStillEmptyOfFinds() async {
        let stub = VerdictStubSource(impossibleAt: [.strict], plausibleAt: [.strict])
        var d = dispatcher(stub: stub)
        d.discardedSourceRecordIDs = ["plausible-strict"]   // the only real find, rejected by hand
        _ = await d.dispatch(
            subject: subject(), recordTypes: [.death], scope: .county, mode: .extend)
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose],
                "one hand-discarded row + one impossible row = no finds; got \(calls)")
    }
}

/// Stub source returning rows of a chosen VERDICT per tier, so the ladder's
/// stop condition can be tested against the real `RecordScorer`.
actor VerdictStubSource: RecordSource {
    nonisolated let sourceID = "verdict-stub"
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Verdict Stub"
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    let impossibleAt: Set<SearchStrictness>
    let plausibleAt: Set<SearchStrictness>
    private(set) var tierCalls: [SearchStrictness] = []

    init(impossibleAt: Set<SearchStrictness>, plausibleAt: Set<SearchStrictness>) {
        self.impossibleAt = impossibleAt
        self.plausibleAt = plausibleAt
    }

    /// A death record for the given year. 1850 against a subject born 1880 is
    /// impossible; 1917 sits inside their recorded death window. Carries a
    /// home-county district so the plausible variant is FACT-grade — since
    /// 2026-08-23 only facts stop the ladder (a lead is a namesake needing
    /// review, not an answer), so a stop-asserting stub must clear every gate.
    nonisolated static func deathRecord(id: String, sourceID: String, year: Int) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(id: id, sourceID: sourceID, name: "Robert Cauldwell",
                                 surname: "Cauldwell", givenName: "Robert",
                                 detailURL: nil, rawFields: [:]),
            deathYear: year, district: "Bakewell"))
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        tierCalls.append(query.strictness)
        var out: [SourceRecord] = []
        if impossibleAt.contains(query.strictness) {
            out.append(Self.deathRecord(
                id: "impossible-\(query.strictness.rawValue)", sourceID: sourceID, year: 1850))
        }
        if plausibleAt.contains(query.strictness) {
            out.append(Self.deathRecord(
                id: "plausible-\(query.strictness.rawValue)", sourceID: sourceID, year: 1917))
        }
        return .results(out)
    }
}

/// Since 2026-08-23: only FACT-grade records stop the ladder. A lead is a
/// namesake needing review, not an answer — and once the parish window
/// widened to a whole life, every common-surname strict tier returns SOME
/// plausible lead, which under the old rule suppressed the variant tier
/// permanently ("86674fd defeats 5ab7b2a", confirmed by the adversarial
/// sweep). These pin the new doctrine from both sides.
@MainActor
struct LeadsDoNotStopTheLadderTests {

    private func subject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: 1916, deathYearTo: 1918,
            gender: .male, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    /// A tier returning only LEADS broadens — the namesake pile is kept for
    /// review but must not suppress the looser spellings.
    @Test func aTierOfOnlyLeadsBroadens() async {
        // No district → the geography gate cannot corroborate → lead, not fact.
        let stub = LeadStubSource()
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(stub)
        _ = await SearchDispatcher(registry: registry).dispatch(
            subject: subject(), recordTypes: [.death], scope: .county, mode: .extend)
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose],
                "a lead-only tier must broaden; got \(calls)")
    }
}

/// Emits one LEAD-grade record per tier: right name, right year, but no
/// district — so the geography gate withholds corroboration.
actor LeadStubSource: RecordSource {
    nonisolated let sourceID = "lead-stub"
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Lead Stub"
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private(set) var tierCalls: [SearchStrictness] = []

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        tierCalls.append(query.strictness)
        return .results([.death(DeathRecord(
            common: RecordCommon(id: "lead-\(query.strictness.rawValue)", sourceID: sourceID,
                                 name: "Robert Cauldwell", surname: "Cauldwell",
                                 givenName: "Robert", detailURL: nil, rawFields: [:]),
            deathYear: 1917))])
    }
}
