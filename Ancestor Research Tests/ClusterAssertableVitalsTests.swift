import Testing
@testable import Ancestor_Research
import AncestorKit

/// #30 — display surfaces must not assert vital years from unapplied
/// lead-verdict records. Owner dogfood 2026-08-24: Kezia Wheeldon's cluster
/// header read "Confirmed · d. ~1891" where the death year came solely from
/// a Find a Grave burial LEAD (date + geography both softFailed) — a
/// Staffordshire namesake later disproven by her 1902 marriage. The
/// verdict-blind `impliedBirthYear`/`impliedDeathYear` stay untouched for
/// clustering internals; `assertable*` is what the human-facing header reads.
struct ClusterAssertableVitalsTests {

    private func censusFact(birthYear: Int) -> ScoredRecord {
        let common = RecordCommon(
            id: "census-\(birthYear)", sourceID: "freecen", name: "Kezia Wheeldon",
            surname: "Wheeldon", givenName: "Kezia", detailURL: nil, rawFields: [:])
        return ScoredRecord(
            id: common.id,
            record: .census(CensusRecord(common: common, censusYear: 1891, birthYear: birthYear)),
            verdict: .fact, gates: [], summary: "census")
    }

    private func burialLead(deathYear: Int) -> ScoredRecord {
        let common = RecordCommon(
            id: "burial-\(deathYear)", sourceID: "findagrave", name: "Keziah Wheeldon",
            surname: "Wheeldon", givenName: "Keziah", detailURL: nil, rawFields: [:])
        return ScoredRecord(
            id: common.id,
            record: .burial(BurialRecord(
                common: common, deathDate: nil, deathYear: deathYear,
                isVeteran: false)),
            verdict: .lead,
            gates: [
                GateResult(gate: .date, outcome: .softFail, reason: "no recorded age"),
                GateResult(gate: .geography, outcome: .softFail, reason: "Leek, Staffordshire"),
            ],
            summary: "burial lead")
    }

    @Test func headerDeathYearIgnoresAnUnappliedBurialLead() {
        let records = [censusFact(birthYear: 1861), burialLead(deathYear: 1891)]
        let cluster = LifeCluster(
            id: "c1", records: records, lifespanStart: 1861, lifespanEnd: 1891)

        // Clustering internals still see the lead-derived death year…
        #expect(cluster.impliedDeathYear == 1891)
        // …but the assertable surface does not.
        #expect(LifeCluster.assertableDeathYear(in: records) == nil)
        #expect(LifeCluster.assertableBirthYear(in: records) == 1861,
                "the fact-verdict census still supplies the birth year")
    }

    @Test func factVerdictBurialStillAssertsItsDeathYear() {
        var burial = burialLead(deathYear: 1881)
        burial = ScoredRecord(
            id: burial.id, record: burial.record, verdict: .fact,
            gates: [], summary: "burial fact")
        #expect(LifeCluster.assertableDeathYear(in: [burial]) == 1881)
    }

    @Test func discardFilteringComposes() {
        // The caller passes an already-discard-filtered list; an empty list
        // asserts nothing.
        #expect(LifeCluster.assertableBirthYear(in: []) == nil)
        #expect(LifeCluster.assertableDeathYear(in: []) == nil)
    }
}
