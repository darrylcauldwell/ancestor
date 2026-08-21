import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// `ContradictoryFactsAudit` had no applied guard.
///
/// `demotions(in:)` filtered on `verdict == .fact && userStatus != .discarded`
/// and never asked whether the record's content was ON the tree. The Health
/// one-click could therefore reduce the evidence backing an applied fact to a
/// lead — days after the apply, from a different surface, with nothing linking
/// the two. `ScoreReplay`'s own header names this as the failure mode the whole
/// replay harness exists to catch, and the audit was committing it.
///
/// The fix does NOT change the exclusivity verdict. The contradiction is real
/// and the user must still see it. What changes is who may act on it: an
/// applied row is reported and held back, because demoting the evidence under a
/// fact that is on the profile asserts the TREE is wrong — a genealogical
/// judgement, not a cleanup.
@MainActor
struct ContradictoryFactsAppliedGuardTests {

    private func probate(_ id: String, year: Int) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(id: id, sourceID: "probate", name: nil,
                                 surname: "MARSHALL", givenName: "HARRY",
                                 detailURL: nil, rawFields: [:]),
            deathYear: year, probateDate: "\(year)", address: "Derbyshire"))
    }

    private func row(
        _ recordID: String, verdict: RecordVerdict = .fact,
        userStatus: UserReviewStatus = .unreviewed,
        appliedAt: Date? = nil, citationURL: String? = nil, year: Int
    ) -> EvidenceRecord {
        EvidenceRecord(
            id: "@P1@|\(recordID)", profileID: "@P1@", sourceID: "probate",
            sourceRecordID: recordID, recordType: .probate,
            verdict: verdict, record: probate(recordID, year: year),
            citationFull: nil, citationURL: citationURL,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: userStatus,
            appliedAt: appliedAt,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "test row")
    }

    /// The founding specimen: two namesake probates, both stored as fact.
    private func contested() -> [EvidenceRecord] {
        [row("p1999", year: 1999), row("p2006", year: 2006)]
    }

    // MARK: - The verdict is unchanged; only who may act on it

    @Test func withNothingAppliedBothAreStillDemotable() {
        let d = ContradictoryFactsAudit.demotions(in: contested(), profile: nil)
        #expect(d.demotable.count == 2)
        #expect(d.appliedHeldBack.isEmpty)
    }

    /// THE GUARD. An applied row is still identified as contradictory — it is
    /// in `all` — but it is not in `demotable`, so the one-click cannot write it.
    @Test func anAppliedFactIsHeldBackNotDemoted() {
        let evidence = [
            row("p1999", appliedAt: Date(timeIntervalSince1970: 100), year: 1999),
            row("p2006", year: 2006),
        ]
        let d = ContradictoryFactsAudit.demotions(in: evidence, profile: nil)

        #expect(d.appliedHeldBack.map(\.id) == ["p1999"])
        #expect(d.demotable.map(\.id) == ["p2006"])
        #expect(d.all.count == 2, "the contradiction is not hidden — both are reported")
    }

    /// The apply paths that never stamp `applied_at` (parent-unlock among them)
    /// are why `wasApplied(to:)` also fingerprints citations. The guard must use
    /// that path, not a bare `appliedAt != nil`, or it under-counts exactly the
    /// applies most likely to be silently damaged.
    @Test func anUnstampedApplyIsCaughtByTheCitationFingerprint() {
        let url = "https://probate.example/p1999"
        let profile = Profile(
            id: "@P1@", firstName: "Harry", lastName: "Marshall", gender: .male,
            birthDate: GenealogicalDate(parsing: "1869"),
            isDeleted: false,
            sources: [.deathDate: [FieldSource(
                origin: .freebmd, raw: "1999", addedAt: Date(),
                citation: Citation(url: url))]],
            disputes: [:])

        let evidence = [
            row("p1999", citationURL: url, year: 1999),   // no appliedAt stamp
            row("p2006", year: 2006),
        ]

        #expect(ContradictoryFactsAudit.demotions(in: evidence, profile: nil)
            .demotable.count == 2, "without the profile the guard cannot see it…")
        let guarded = ContradictoryFactsAudit.demotions(in: evidence, profile: profile)
        #expect(guarded.appliedHeldBack.map(\.id) == ["p1999"],
                "…with the profile in hand, the unstamped apply is caught")
        #expect(guarded.demotable.map(\.id) == ["p2006"])
    }

    /// A user-discarded row is neither a rival nor a candidate — unchanged.
    @Test func aDiscardedRowIsStillNeitherDemotedNorHeldBack() {
        let evidence = [
            row("p1999", year: 1999),
            row("p2006", userStatus: .discarded, year: 2006),
        ]
        let d = ContradictoryFactsAudit.demotions(in: evidence, profile: nil)
        #expect(d.isEmpty, "'not them' resolves the contest — nothing to demote")
    }

    // MARK: - The finding still reports it

    @Test func theFindingMarksAppliedRowsSoTheSurfaceCanSaySo() {
        let evidence = [
            row("p1999", appliedAt: Date(timeIntervalSince1970: 100), year: 1999),
            row("p2006", year: 2006),
        ]
        let finding = ContradictoryFactsAudit.finding(
            profileID: "@P1@", profileName: "Harry Marshall",
            evidence: evidence, profile: nil)

        #expect(finding?.demotions.count == 2, "the user sees the whole contradiction")
        #expect(finding?.appliedHeldBack.map(\.sourceRecordID) == ["p1999"])
        #expect(finding?.demotable.map(\.sourceRecordID) == ["p2006"])
    }

    // MARK: - The pipeline half of the same guard

    /// The audit was only half the exposure. `applyExclusivity` runs during a
    /// research RUN and writes through `saveEvidence`, so a run could demote an
    /// applied fact just as silently. The live case that forced this: teaching
    /// the geography gate to read parish records let six speculative FreeREG
    /// "William Holmes" baptisms reach `.fact` — they had been stuck at `lead`
    /// only because a blind gate soft-failed them — and they then demoted the
    /// APPLIED 7b/747 Bakewell 1882 registration confirmed against the GRO image.
    @Test func theExclusivityPassNeverDemotesAnAppliedRecord() {
        let facts = [
            ScoredRecord(id: "applied", record: probate("applied", year: 1999),
                         verdict: .fact, gates: [], summary: ""),
            ScoredRecord(id: "rival1", record: probate("rival1", year: 2001),
                         verdict: .fact, gates: [], summary: ""),
            ScoredRecord(id: "rival2", record: probate("rival2", year: 2006),
                         verdict: .fact, gates: [], summary: ""),
        ]

        let unguarded = RecordScorer.applyExclusivity(facts)
        #expect(unguarded.allSatisfy { $0.verdict == .lead },
                "without the guard the whole slot demotes — including the applied row")

        let guarded = RecordScorer.applyExclusivity(facts, appliedIDs: ["applied"])
        #expect(guarded.first { $0.id == "applied" }?.verdict == .fact,
                "the user already decided; a later-visible rival must not undo it")
        #expect(guarded.filter { $0.verdict == .lead }.map(\.id) == ["rival1", "rival2"],
                "the undiscriminated rivals still demote")
    }

    /// Two applied records that contradict each other are BOTH left alone —
    /// the pass cannot choose between two human decisions. The audit reports
    /// them instead (`appliedHeldBack`), which is where the user resolves it.
    @Test func twoAppliedRivalsAreBothLeftForTheUser() {
        let facts = [
            ScoredRecord(id: "a", record: probate("a", year: 1999),
                         verdict: .fact, gates: [], summary: ""),
            ScoredRecord(id: "b", record: probate("b", year: 2006),
                         verdict: .fact, gates: [], summary: ""),
        ]
        let guarded = RecordScorer.applyExclusivity(facts, appliedIDs: ["a", "b"])
        #expect(guarded.allSatisfy { $0.verdict == .fact })
    }

    /// The exemption must not leak: with no applied ids the pass behaves
    /// exactly as it always did.
    @Test func withNoAppliedIDsThePassIsUnchanged() {
        let facts = [
            ScoredRecord(id: "a", record: probate("a", year: 1999),
                         verdict: .fact, gates: [], summary: ""),
            ScoredRecord(id: "b", record: probate("b", year: 2006),
                         verdict: .fact, gates: [], summary: ""),
        ]
        #expect(RecordScorer.applyExclusivity(facts, appliedIDs: [])
            .allSatisfy { $0.verdict == .lead })
    }

    /// When EVERY contested fact is applied there is nothing safe to do
    /// automatically — the finding must still appear (the contradiction is
    /// real) with an empty demotable set, so the button disables rather than
    /// silently doing nothing.
    @Test func anAllAppliedContradictionIsReportedWithNothingDemotable() {
        let applied = Date(timeIntervalSince1970: 100)
        let evidence = [
            row("p1999", appliedAt: applied, year: 1999),
            row("p2006", appliedAt: applied, year: 2006),
        ]
        let finding = ContradictoryFactsAudit.finding(
            profileID: "@P1@", profileName: "Harry Marshall",
            evidence: evidence, profile: nil)

        #expect(finding != nil, "the contradiction must not vanish just because it is applied")
        #expect(finding?.demotable.isEmpty == true)
        #expect(finding?.appliedHeldBack.count == 2)
    }
}
