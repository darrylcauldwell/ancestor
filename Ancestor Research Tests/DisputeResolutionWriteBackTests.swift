import Testing
import Foundation
@testable import Ancestor_Research

/// M16.14 — regression tests for the dispute resolution write-back path.
/// Found INCOMPLETE during the audit (Resolve / Defer buttons in
/// ConflictResolutionView had empty closures). The fix wires
/// AppState.resolveDispute → ProjectDatabase.resolveFieldDispute → an
/// UPDATE on field_disputes.resolution. These tests pin the round-trip
/// so a future regression is caught immediately.
@MainActor
struct DisputeResolutionWriteBackTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// Build an AppState wired to a fresh in-memory project database.
    private func makeAppState() throws -> (AppState, ProjectDatabase, Profile, FieldDispute) {
        let db = try makeTempDB()
        let appState = AppState()
        appState.currentDatabase = db

        // Seed a profile with two competing sources for birthDate.
        let profile = Profile(
            id: "p1", externalIDs: [:],
            firstName: "Jane", lastName: "Doe",
            gender: .female, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1880"),
            birthLocation: "Wirksworth",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)

        let s1 = FieldSource(origin: .gedcom, raw: "1880", addedAt: Date())
        let s2 = FieldSource(origin: .freebmd, raw: "1881", addedAt: Date())
        let dispute = FieldDispute(
            field: .birthDate,
            reason: .valueMismatch,
            competingSources: [s1, s2],
            detectedAt: Date(),
            resolution: nil
        )
        try db.addFieldDispute(profileID: profile.id, dispute: dispute)

        // Refresh the snapshot so AppState sees the dispute.
        appState.snapshot = try db.buildSnapshot()
        return (appState, db, profile, dispute)
    }

    @Test func acceptingSourceUpdatesDisputeResolution() throws {
        let (appState, db, profile, dispute) = try makeAppState()
        let chosenSource = dispute.competingSources[1]   // 1881

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .accepted(chosenSource)
        )

        // Reload from disk to confirm the write hit SQLite.
        let reloaded = try db.buildSnapshot()
        let reloadedProfile = reloaded.profiles[profile.id]
        let resolved = reloadedProfile?.disputes[.birthDate]?.resolution
        guard case .accepted(let storedSource) = resolved else {
            Issue.record("Expected .accepted resolution, got \(String(describing: resolved))")
            return
        }
        #expect(storedSource.raw == "1881")
        #expect(storedSource.origin == .freebmd)
    }

    @Test func manualResolutionPersistsValue() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .manual("1880-1881")
        )

        let reloaded = try db.buildSnapshot()
        let resolution = reloaded.profiles[profile.id]?.disputes[.birthDate]?.resolution
        guard case .manual(let value) = resolution else {
            Issue.record("Expected .manual resolution, got \(String(describing: resolution))")
            return
        }
        #expect(value == "1880-1881")
    }

    @Test func deferredResolutionMarksDisputeDeferred() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .deferred
        )

        let reloaded = try db.buildSnapshot()
        let resolution = reloaded.profiles[profile.id]?.disputes[.birthDate]?.resolution
        #expect(resolution == .deferred)
    }

    @Test func resolveDisputeRecordsTransaction() throws {
        let (appState, db, profile, _) = try makeAppState()

        appState.resolveDispute(
            profileID: profile.id,
            field: .birthDate,
            resolution: .deferred
        )

        // The resolution should write a transaction so undo can replay it.
        let txs = try db.loadTransactions(limit: 5)
        let resolveTx = txs.first {
            if case .resolveDispute = $0.kind { return true }
            return false
        }
        #expect(resolveTx != nil)
    }

    // MARK: - EV35 (2026-08-26): the ruling must re-score what it un-blocks

    /// A FreeBMD death index row whose recorded age is far enough off Jane's
    /// 1880 birth year to trip the date gate's "a different person" escalation
    /// (48 in 1909 implies birth ~1861): `.impossible` against a firm 1880, a
    /// held `.lead` against a disputed one. The district matches her birthplace
    /// so the geography gate is not the variable under test.
    private func janesDeathIndexRow() -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: "freebmd_death_7b_407_1", sourceID: "freebmd",
                surname: "Doe", givenName: "Jane", rawFields: [:]),
            deathYear: 1909, age: 48, quarter: "Jun",
            district: "Wirksworth", volume: "7b", page: "407"))
    }

    /// Score `record` against the profile AS IT STANDS (dispute open) and
    /// persist it exactly as a run would, then mark it kept by the human.
    @discardableResult
    private func seedHeldRecord(
        _ appState: AppState, _ db: ProjectDatabase, _ record: SourceRecord
    ) throws -> ScoredRecord {
        let profile = try #require(appState.snapshot.profiles["p1"])
        let subject = ResearchSubject.fromProfile(profile, snapshot: appState.snapshot)
        #expect(subject.contestedFields.contains(.birthDate))
        let scored = RecordScorer.classify(
            record: record, subject: subject, searchType: record.recordType)
        try db.saveEvidence(profileID: "p1", scored: scored,
                            citationFull: "FreeBMD death index", citationURL: nil)
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: scored.id),
            status: .savedAsLead)
        return scored
    }

    /// EV35 — a record that survived ONLY because the birth date was under
    /// argument must be re-scored the moment the user rules the dispute, not
    /// left in "Researched — not applied" until an unrelated run re-stomps it.
    @Test func resolvingADisputeRescoresTheRecordsItsOpennessHeldBack() throws {
        let (appState, db, _, dispute) = try makeAppState()
        let seeded = try seedHeldRecord(appState, db, janesDeathIndexRow())
        // Precondition: the seed IS the shape under test.
        #expect(seeded.verdict == .lead)
        #expect(RecordScorer.heldByOpenDispute(seeded.gates, field: .birthDate))

        appState.resolveDispute(
            profileID: "p1", field: .birthDate,
            resolution: .accepted(dispute.competingSources[0]))   // 1880

        let row = try #require(
            try db.loadEvidenceForProfile("p1").first { $0.sourceRecordID == seeded.id })
        #expect(row.verdict == .impossible,
                "the dispute is settled, so the exclusion it was hedging must now stand: \(row.gates)")
        #expect(!RecordScorer.heldByOpenDispute(row.gates, field: .birthDate),
                "the stale 'which is itself disputed' reason is still on screen")
        // Only user_status survives a re-stomp — and it MUST.
        #expect(row.userStatus == .savedAsLead)
    }

    /// Deferring is the user explicitly declining to pick a winner, so the
    /// premise is still unsound and the record must stay a reviewable lead.
    @Test func deferringADisputeLeavesTheHeldRecordAsALead() throws {
        let (appState, db, _, _) = try makeAppState()
        let seeded = try seedHeldRecord(appState, db, janesDeathIndexRow())
        #expect(seeded.verdict == .lead)

        appState.resolveDispute(profileID: "p1", field: .birthDate, resolution: .deferred)

        let row = try #require(
            try db.loadEvidenceForProfile("p1").first { $0.sourceRecordID == seeded.id })
        #expect(row.verdict == .lead)
        #expect(RecordScorer.heldByOpenDispute(row.gates, field: .birthDate))
    }

    /// A bystander row stored with a verdict and gates TODAY'S RULES WOULD NOT
    /// REPRODUCE. That drift is exactly what `ScoreReplay`'s own doc warns about
    /// — "a replay row is not the stored verdict", the profile edited since, an
    /// unreconstructable probe subject — and it is the only shape that can tell
    /// a scoped write apart from a full-replay write.
    ///
    /// Review F07 (2026-08-26): the previous control seeded a bystander whose
    /// replay was byte-identical to its stored row, so `DisputeRescorer`'s own
    /// `guard !unchanged` skipped it whether or not the scoping filter existed.
    /// It asserted the safety property the whole design rests on and could not
    /// fail. This one can.
    @discardableResult
    private func seedStaleRow(
        _ db: ProjectDatabase, _ record: SourceRecord
    ) throws -> ScoredRecord {
        let stale = ScoredRecord(
            id: record.id, record: record, verdict: .impossible,
            gates: [GateResult(
                gate: .date, outcome: .impossible,
                reason: "stale stored verdict — hand-forced, no replay reproduces it")],
            summary: "stale bystander")
        try db.saveEvidence(profileID: "p1", scored: stale,
                            citationFull: "FreeBMD birth index", citationURL: nil)
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: stale.id),
            status: .savedAsLead)
        return stale
    }

    /// The re-score writes ONLY the rows this dispute demoted. A record the
    /// dispute never held keeps its stored verdict — even when today's rules
    /// disagree with it, because re-verdicting THAT row is a decision the user
    /// never asked for by clicking Resolve.
    ///
    /// Delete the scope filter in `DisputeRescorer` (`for detail in details
    /// where held.contains(detail.recordID)` → `for detail in details`) and this
    /// test fails: the bystander's replay differs from its stored row, so the
    /// unscoped write rewrites it.
    @Test func rescoreLeavesRecordsTheDisputeNeverHeldAlone() throws {
        let (appState, db, _, dispute) = try makeAppState()
        let held = try seedHeldRecord(appState, db, janesDeathIndexRow())
        let bystander = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "freebmd_birth_7b_515_1", sourceID: "freebmd",
                                 surname: "Doe", givenName: "Jane", rawFields: [:]),
            birthYear: 1880, quarter: "Mar", district: "Wirksworth",
            volume: "7b", page: "515"))
        let stale = try seedStaleRow(db, bystander)
        // The dispute never held this row, so nothing about settling it concerns
        // this row.
        #expect(!RecordScorer.heldByOpenDispute(stale.gates, field: .birthDate))

        appState.resolveDispute(
            profileID: "p1", field: .birthDate,
            resolution: .accepted(dispute.competingSources[0]))

        let rows = try db.loadEvidenceForProfile("p1")
        let after = try #require(rows.first { $0.sourceRecordID == stale.id })
        #expect(after.verdict == .impossible,
                "an untouched row was re-verdicted by a scoped re-score")
        #expect(after.gates.contains { $0.reason.hasPrefix("stale stored verdict") },
                "the untouched row's stored GATES were rewritten too")

        // Non-vacuity, both halves.
        // (a) an UNSCOPED write would genuinely have rewritten this row.
        //     Review F07 (2026-08-27): asked of `ScoreReplay.diagnose` — the
        //     replay `DisputeRescorer` actually iterates — rather than of
        //     `RecordScorer.classify`. The precise way the original control
        //     went toothless was the rescorer's own loop having nothing to do
        //     for this row: either `diagnose` omits it, or its `unchanged`
        //     guard skips it. `classify` can see neither of those, so it
        //     cannot notice the control decaying. Reproduce `unchanged`
        //     verbatim instead, over the same post-resolution rows.
        let profile = try #require(appState.snapshot.profiles["p1"])
        let details = ScoreReplay.diagnose(
            profileID: "p1", evidence: rows, profile: profile,
            snapshot: appState.snapshot,
            homeChapmanCode: (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? "")
        let bystanderDetail = try #require(
            details.first { $0.recordID == stale.id },
            "the replay never even emits this row, so scoping it out proves nothing")
        let replayWouldRewrite = bystanderDetail.finalVerdict != after.verdict
            || bystanderDetail.finalGates.count != after.gates.count
            || !zip(bystanderDetail.finalGates, after.gates).allSatisfy {
                $0.gate == $1.gate && $0.outcome == $1.outcome && $0.reason == $1.reason
            }
        #expect(replayWouldRewrite,
                "the control is toothless unless the replay disagrees with the stored row")
        // (b) the rescorer DID run — the row the dispute really held moved.
        let heldRow = try #require(rows.first { $0.sourceRecordID == held.id })
        #expect(heldRow.verdict == .impossible)
    }
}
