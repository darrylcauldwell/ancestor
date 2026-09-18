import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Subject place model Slice 1.5 — the corpus replay diff.
///
/// The spec's central invariant could not be written as an assertion:
///
/// > "more place data may widen what is SEARCHED; it must never widen what the
/// > scorer ACCEPTS"
///
/// — because no such firewall exists. `applyExclusivity` demotes a stored `.fact`
/// as soon as a second undiscriminated `.fact` lands in the same slot, and
/// searching one more county for a death is exactly how one arrives. So a
/// widening can take facts AWAY, days later, in a Health audit, on a record the
/// user already applied.
///
/// A diff over the real corpus is the only proof available. These tests prove
/// the diff itself is trustworthy: silent when nothing moved, loud when
/// something did, and — the one that matters — not quiet on the demotion, which
/// is not a property of any single record and which a per-record replay would
/// miss entirely.
@MainActor
struct ScoreReplayTests {

    // MARK: - Fixtures

    private func makeDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func subjectProfile() -> Profile {
        Profile(id: "@P1@", firstName: "Harry", lastName: "Marshall", gender: .male,
                birthDate: GenealogicalDate(parsing: "1869"),
                birthLocation: "Wirksworth, Derbyshire",
                deathDate: nil, deathLocation: nil,
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func snapshot(_ p: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [p.id: p], relationships: [], lifeEvents: [:])
    }

    /// Two 1891 households for one man. Each passes all four gates alone — a
    /// person can only be in one household on census night, so the pair is only
    /// resolvable across records. This is the shape the harness exists for.
    private func census(_ id: String, district: String, year: Int = 1891) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: nil,
                                 surname: "MARSHALL", givenName: "HARRY",
                                 detailURL: nil, rawFields: [:]),
            censusYear: year, age: year - 1869, birthYear: 1869, district: district))
    }

    private func row(
        _ recordID: String, record: SourceRecord, verdict: RecordVerdict,
        userStatus: UserReviewStatus = .unreviewed,
        gates: [GateResult] = [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")]
    ) -> EvidenceRecord {
        EvidenceRecord(
            id: "@P1@|\(recordID)", profileID: "@P1@", sourceID: "freecen",
            sourceRecordID: recordID, recordType: record.recordType,
            verdict: verdict, record: record,
            citationFull: nil, citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: userStatus,
            gates: gates, summary: "test row")
    }

    private func replay(_ evidence: [EvidenceRecord], home: String = "DBY") -> [ScoreReplay.Row] {
        let p = subjectProfile()
        return ScoreReplay.replay(profileID: p.id, evidence: evidence,
                                  profile: p, snapshot: snapshot(p), homeChapmanCode: home)
    }

    private func contested() -> [EvidenceRecord] {
        [row("cA", record: census("cA", district: "Belper"), verdict: .fact),
         row("cB", record: census("cB", district: "Bakewell"), verdict: .fact)]
    }

    // MARK: - The fingerprint

    @Test func everyStoredRecordProducesExactlyOneRow() {
        let rows = replay(contested())
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.recordID)) == ["cA", "cB"])
        #expect(rows.allSatisfy { $0.profileID == "@P1@" })
    }

    /// Order is stable regardless of how the store hands the rows over —
    /// otherwise every diff is full of phantom moves.
    @Test func rowOrderDoesNotDependOnInputOrder() {
        let e = contested()
        #expect(ScoreReplay.report(replay(e)) == ScoreReplay.report(replay(e.reversed())))
    }

    /// Re-scoring the same corpus twice with the same code must be identical.
    /// If this is ever flaky the harness proves nothing at all.
    @Test func replayIsDeterministic() {
        let e = contested()
        #expect(ScoreReplay.diff(before: replay(e), after: replay(e)).isEmpty)
    }

    @Test func emptyEvidenceProducesNoRows() {
        #expect(replay([]).isEmpty)
    }

    // MARK: - The stage a per-record replay would miss

    /// THE POINT OF THE HARNESS. Both 1891 households pass the four gates on
    /// their own — `classify` says `fact` to each. Only the cross-record pass
    /// demotes them. A replay that stopped at `classify` would fingerprint two
    /// facts and report "no change" straight through the regression the spec
    /// calls dangerous.
    @Test func theExclusivityDemotionIsInTheFingerprint() {
        // First: prove the premise, so this test cannot pass by everything
        // simply failing a gate.
        let subject = ResearchSubject.fromProfile(
            subjectProfile(), snapshot: snapshot(subjectProfile()),
            mode: .extend, homeChapmanCode: "DBY")
        let alone = RecordScorer.classify(
            record: census("cA", district: "Belper"), subject: subject, searchType: .census)
        #expect(alone.verdict == .fact, "each household is a fact when scored alone")

        let rows = replay(contested())
        #expect(rows.allSatisfy { $0.verdict == "lead" },
                "together they demote — a man is in one household on census night")
        #expect(rows.allSatisfy { $0.gates.contains { $0.hasPrefix("exclusivity:softFail:") } },
                "and the pass's own gate is fingerprinted, reason included")
    }

    /// A single household has no rival, so the pass leaves it alone. Without
    /// this the test above could pass for the wrong reason.
    @Test func anUncontestedFactStaysAFact() {
        let rows = replay([row("cA", record: census("cA", district: "Belper"), verdict: .fact)])
        #expect(rows.count == 1)
        #expect(rows[0].verdict == "fact")
        #expect(!rows[0].gates.contains { $0.hasPrefix("exclusivity:") })
    }

    /// Different census years are different slots — 1891 and 1901 do not
    /// compete, and a replay that demoted them would be reporting a conflict
    /// the app does not see.
    @Test func differentCensusYearsAreNotRivals() {
        let rows = replay([
            row("cA", record: census("cA", district: "Belper"), verdict: .fact),
            row("cC", record: census("cC", district: "Belper", year: 1901), verdict: .fact),
        ])
        #expect(rows.allSatisfy { $0.verdict == "fact" })
    }

    /// "Not them" resolves the contest. A discarded rival must not demote the
    /// survivor, or the diff would show a demotion the live app never performs.
    @Test func aUserDiscardedRivalDoesNotDemoteTheSurvivor() {
        let rows = replay([
            row("cA", record: census("cA", district: "Belper"), verdict: .fact),
            row("cB", record: census("cB", district: "Bakewell"), verdict: .fact,
                userStatus: .discarded),
        ])
        #expect(rows.first { $0.recordID == "cA" }?.verdict == "fact")
    }

    // MARK: - Rows scored against a subject the replay cannot rebuild

    /// `ResearchPipeline`'s child-gap probe scores deaths against a MUTATED
    /// copy of the subject — no given name, no birth window, family surname —
    /// to sweep for infant deaths in a birth gap. The replay rebuilds one
    /// subject per profile and cannot reconstruct that, so those rows compare
    /// different inputs. They were a large share of the apparent drift when
    /// measured; quoting them as "the store disagrees with the rules" is wrong.
    private func probeRow(_ recordID: String) -> EvidenceRecord {
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: recordID, sourceID: "freebmd", name: nil,
                                 surname: "MARSHALL", givenName: nil,
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1871, quarter: "Mar", district: "Belper",
            volume: "7b", page: "1"))
        return EvidenceRecord(
            id: "@P1@|\(recordID)", profileID: "@P1@", sourceID: "freebmd",
            sourceRecordID: recordID, recordType: .death,
            verdict: .lead, record: record,
            citationFull: nil, citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: .unreviewed,
            gates: [
                GateResult(gate: .name, outcome: .softFail,
                           reason: "surname=1.00 but subject given name unknown — cannot confirm identity on surname alone, review"),
                GateResult(gate: .date, outcome: .fail, reason: "insufficient date information"),
            ],
            summary: "gap probe row")
    }

    private func diagnose(_ evidence: [EvidenceRecord], profile p: Profile) -> [ScoreReplay.Detail] {
        ScoreReplay.diagnose(profileID: p.id, evidence: evidence,
                             profile: p, snapshot: snapshot(p), homeChapmanCode: "DBY")
    }

    @Test func aGapProbeRowIsFlaggedAndExcludedFromMeaningfulDrift() {
        let d = diagnose([probeRow("g1")], profile: subjectProfile()).first
        #expect(d?.scoredAgainstUnreconstructableSubject == true)
        #expect(d?.drifted == true, "it did move — the raw figure still counts it…")
        #expect(d?.driftedMeaningfully == false, "…but it is not a claim about the store")
    }

    /// THE CROSS-CHECK. An unnamed placeholder profile produces the very same
    /// gate reason from its OWN subject, and its rows are real drift. Excusing
    /// them would hide the " Bown"-shaped cases the married-surname floor
    /// exists to fix.
    @Test func anUnnamedProfilesOwnRowsAreNotExcusedAsProbeRows() {
        let nameless = Profile(
            id: "@P1@", firstName: nil, lastName: "Marshall", gender: .female,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            isDeleted: false, sources: [:], disputes: [:])
        let d = diagnose([probeRow("g1")], profile: nameless).first
        #expect(d?.scoredAgainstUnreconstructableSubject == false,
                "the profile really has no given name — this is its own scoring, not a probe's")
    }

    /// The probe asks for deaths only, so a census row carrying the same gate
    /// reasons is something else and must not be excused.
    @Test func aNonDeathRowIsNeverExcusedAsAProbeRow() {
        let census = row("cA", record: self.census("cA", district: "Belper"), verdict: .lead,
                         gates: [
                            GateResult(gate: .name, outcome: .softFail,
                                       reason: "surname=1.00 but subject given name unknown — cannot confirm identity on surname alone, review"),
                            GateResult(gate: .date, outcome: .fail,
                                       reason: "insufficient date information"),
                         ])
        let d = diagnose([census], profile: subjectProfile()).first
        #expect(d?.scoredAgainstUnreconstructableSubject == false)
    }

    /// An ordinary row with real gates is never excused.
    @Test func anOrdinaryRowIsNotFlagged() {
        let d = diagnose(contested(), profile: subjectProfile())
        #expect(d.allSatisfy { !$0.scoredAgainstUnreconstructableSubject })
    }

    /// The fingerprint needs BOTH signatures — a missing given name alone is
    /// not enough, or every thin subject's rows would be excused.
    @Test func oneSignatureAloneIsNotEnough() {
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: nil,
                                 surname: "MARSHALL", givenName: nil,
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1871, quarter: "Mar", district: "Belper", volume: "7b", page: "1"))
        let onlyName = EvidenceRecord(
            id: "@P1@|d1", profileID: "@P1@", sourceID: "freebmd",
            sourceRecordID: "d1", recordType: .death, verdict: .lead, record: record,
            citationFull: nil, citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: .unreviewed,
            gates: [GateResult(gate: .name, outcome: .softFail,
                               reason: "surname=1.00 but subject given name unknown — cannot confirm identity on surname alone, review")],
            summary: "")
        #expect(diagnose([onlyName], profile: subjectProfile())
            .first?.scoredAgainstUnreconstructableSubject == false)
    }

    /// The BEFORE/AFTER gate is unaffected — both captures rebuild the subject
    /// the same way, so a probe row still diffs like-with-like and must still
    /// appear in the fingerprint.
    @Test func probeRowsStillAppearInTheFingerprint() {
        let rows = ScoreReplay.rows(from: diagnose([probeRow("g1")], profile: subjectProfile()))
        #expect(rows.count == 1, "excluded from the drift STATISTIC, not from the diff")
    }

    // MARK: - The diff

    @Test func anIdenticalCorpusDiffsToNothing() {
        let rows = replay(contested())
        #expect(ScoreReplay.diff(before: rows, after: rows).isEmpty)
    }

    /// The whole reason gate reasons are in the fingerprint: a verdict can
    /// survive while the route to it changes, and that is drift worth seeing.
    @Test func aChangedReasonIsAChangeEvenWhenTheVerdictHolds() {
        let before = [ScoreReplay.Row(profileID: "@P1@", recordID: "r", verdict: "fact",
                                      gates: ["geography:pass:home county DBY"])]
        let after = [ScoreReplay.Row(profileID: "@P1@", recordID: "r", verdict: "fact",
                                     gates: ["geography:pass:residence county STS"])]
        let changes = ScoreReplay.diff(before: before, after: after)
        #expect(changes.count == 1)
        #expect(changes[0].kind == "reasons")
    }

    /// Invariant (a) — the dangerous narrowing. It must be detected AND sorted
    /// to the top, because it is the one that blocks a ship.
    @Test func aDemotionIsFlaggedAsANarrowingAndSortsFirst() {
        let before = [
            ScoreReplay.Row(profileID: "@P1@", recordID: "a", verdict: "fact", gates: []),
            ScoreReplay.Row(profileID: "@P1@", recordID: "b", verdict: "lead", gates: []),
        ]
        let after = [
            ScoreReplay.Row(profileID: "@P1@", recordID: "a", verdict: "lead", gates: []),
            ScoreReplay.Row(profileID: "@P1@", recordID: "b", verdict: "fact", gates: []),
        ]
        let changes = ScoreReplay.diff(before: before, after: after)
        #expect(changes.count == 2)
        #expect(changes[0].kind == "demoted", "the narrowing is reported first")
        #expect(changes[1].kind == "promoted")
        #expect(ScoreReplay.narrowings(changes).map(\.recordID) == ["a"])
    }

    @Test func aRecordThatVanishesOrArrivesIsReported() {
        let a = ScoreReplay.Row(profileID: "@P1@", recordID: "a", verdict: "fact", gates: [])
        let b = ScoreReplay.Row(profileID: "@P1@", recordID: "b", verdict: "fact", gates: [])
        let changes = ScoreReplay.diff(before: [a], after: [b])
        #expect(Set(changes.map(\.kind)) == ["disappeared", "appeared"])
    }

    /// A record that stops being scored at all is a narrowing too — "no verdict"
    /// is not "still accepted".
    @Test func aDisappearedFactCountsAsANarrowing() {
        let a = ScoreReplay.Row(profileID: "@P1@", recordID: "a", verdict: "fact", gates: [])
        #expect(ScoreReplay.narrowings(ScoreReplay.diff(before: [a], after: [])).count == 1)
    }

    /// Two profiles can hold the same record id. Keying the diff on the record
    /// alone would collapse them and hide one of the two changes.
    @Test func theSameRecordUnderTwoProfilesDiffsIndependently() {
        let before = [
            ScoreReplay.Row(profileID: "@P1@", recordID: "r", verdict: "fact", gates: []),
            ScoreReplay.Row(profileID: "@P2@", recordID: "r", verdict: "fact", gates: []),
        ]
        let after = [
            ScoreReplay.Row(profileID: "@P1@", recordID: "r", verdict: "lead", gates: []),
            ScoreReplay.Row(profileID: "@P2@", recordID: "r", verdict: "fact", gates: []),
        ]
        let changes = ScoreReplay.diff(before: before, after: after)
        #expect(changes.map(\.profileID) == ["@P1@"])
    }

    // MARK: - Capture round-trip

    /// Captures are written to disk and diffed with ordinary tools, so the text
    /// form has to survive the trip.
    @Test func aCaptureRoundTrips() {
        let rows = replay(contested())
        #expect(ScoreReplay.parse(ScoreReplay.report(rows)) == rows)
    }

    /// Gate reasons are prose written for humans and DO contain punctuation —
    /// the live geography reason already carries a comma and an apostrophe.
    /// Unescaped, a reason holding the field delimiter would split into a bogus
    /// row and the capture would silently disagree with the live diff.
    @Test func aReasonContainingDelimitersStillRoundTrips() {
        let rows = [ScoreReplay.Row(
            profileID: "@P1@", recordID: "r", verdict: "lead",
            gates: ["geography:softFail:district Belper/Wirksworth, boundary moved"])]
        #expect(ScoreReplay.parse(ScoreReplay.report(rows)) == rows)
    }

    @Test func anEmptyReplayCapturesAsEmptyAndParsesBack() {
        #expect(ScoreReplay.report([]).isEmpty)
        #expect(ScoreReplay.parse("").isEmpty)
    }

    // MARK: - Against a real store

    /// End to end through `ProjectDatabase`, because the harness's whole job is
    /// to run over a real project — including reading the home county from
    /// project meta the way `CampaignReviewService` does.
    @Test func replayAllReadsTheWholeStore() throws {
        let db = try makeDB()
        let profile = subjectProfile()
        _ = try db.addProfile(profile, source: .manual)

        for (id, district) in [("cA", "Belper"), ("cB", "Bakewell")] {
            let record = census(id, district: district)
            try db.saveEvidence(
                profileID: profile.id,
                scored: ScoredRecord(id: record.id, record: record, verdict: .fact,
                                     gates: [], summary: "seeded"),
                citationFull: nil, citationURL: nil)
        }

        let rows = ScoreReplay.replayAll(in: db, snapshot: try db.buildSnapshot())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.verdict == "lead" },
                "the same demotion the audit reports, reached from the database")
        #expect(rows == rows.sorted(), "replayAll must emit in diffable order")
    }

    /// The harness must never write. It is run against the owner's live project,
    /// so a replay that mutated the store would be worse than no harness.
    @Test func replayingDoesNotTouchTheStore() throws {
        let db = try makeDB()
        let profile = subjectProfile()
        _ = try db.addProfile(profile, source: .manual)
        for (id, district) in [("cA", "Belper"), ("cB", "Bakewell")] {
            let record = census(id, district: district)
            try db.saveEvidence(
                profileID: profile.id,
                scored: ScoredRecord(id: record.id, record: record, verdict: .fact,
                                     gates: [], summary: "seeded"),
                citationFull: nil, citationURL: nil)
        }

        let transactionsBefore = try db.loadTransactions().count
        let rows = ScoreReplay.replayAll(in: db, snapshot: try db.buildSnapshot())
        #expect(rows.allSatisfy { $0.verdict == "lead" }, "the replay DID demote…")

        #expect(try db.loadEvidenceForProfile(profile.id).allSatisfy { $0.verdict == .fact },
                "…and the stored verdicts are untouched — only the replay's copy moved")
        #expect(try db.loadTransactions().count == transactionsBefore)
    }
}
