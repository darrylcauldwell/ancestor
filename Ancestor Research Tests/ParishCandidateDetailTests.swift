import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EV31 (2026-08-26) — a FreeREG baptism names BOTH parents, and that is
/// usually the single most discriminating fact for "is this the right person".
/// The results-table row carries none of it (`parseResults` builds every row
/// with `fatherName: nil, motherName: nil`) and only the top hit of a search is
/// enriched (`enrichWithDetail(cap: 1)`), so at the moment of accept/reject the
/// deciding evidence sat behind a per-record "Details" click.
///
/// The fix is bound to INTENT, not layout: opening the collapsed "Researched —
/// not applied" bucket is an unambiguous "I am deciding on these now". The
/// volunteer-source constraint is what shapes it, so these tests exist mainly
/// to pin the BOUNDS — cap 3, one GET per evidence row per session, applied and
/// rejected rows untouched, already-fetched rows never re-requested.
@MainActor
struct ParishCandidateDetailTests {

    private func row(_ id: String, standing: ProfileSourcesLedger.Standing,
                     canLoad: Bool, rank: Int = 0,
                     sourceID: String = "freereg") -> ProfileSourcesLedger.RecordDetail {
        var d = ProfileSourcesLedger.RecordDetail(
            id: id, sourceID: sourceID, recordType: .parish, verdict: .lead,
            standing: standing, citation: "FreeREG \(id)", citationURL: nil,
            ageDetail: nil, reconcileNote: nil, matchRank: rank,
            duplicateIDs: [id], registrationKey: nil)
        d.canLoadParishDetail = canLoad
        d.isParishBaptism = true
        return d
    }

    // MARK: - Decision-time selection, bounded

    @Test func openingAResearchBucketPullsTheTopCandidatesEntryPages() {
        let rows = [row("a", standing: .researched, canLoad: true, rank: 90),
                    row("b", standing: .researched, canLoad: true, rank: 80),
                    row("c", standing: .researched, canLoad: true, rank: 70),
                    row("d", standing: .researched, canLoad: true, rank: 60)]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: []) == ["a", "b", "c"],
            "capped at 3 — a volunteer source is never swept, and the cap lands on the contested rivals")
    }

    @Test func alreadyFetchedAndAppliedAndRejectedRowsAreNeverRefetched() {
        // canLoad == false is the persisted-detail case (`parishNeedsDetail`
        // goes false once the entry is stored); applied rows belong to the
        // card-open backfill; rejected rows are the user's closed call.
        let rows = [row("done", standing: .researched, canLoad: false, rank: 90),
                    row("applied", standing: .applied, canLoad: true, rank: 80),
                    row("userRejected", standing: .userRejected, canLoad: true, rank: 70),
                    row("scorerRejected", standing: .scorerRejected, canLoad: true, rank: 60),
                    row("live", standing: .researched, canLoad: true, rank: 50)]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: []) == ["live"])
    }

    @Test func reopeningTheBucketCannotRespendARequest() {
        // The session's attempted set is keyed on the EVIDENCE composite id and
        // shared with the card-open backfill, so a bucket toggled open and shut
        // ten times still costs one GET per record.
        let rows = [row("a", standing: .researched, canLoad: true, rank: 90),
                    row("b", standing: .researched, canLoad: true, rank: 80)]
        let attempted: Set<String> = [
            EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "a")]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: attempted) == ["b"])
        let both: Set<String> = [
            EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "a"),
            EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "b")]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: both).isEmpty)
    }

    @Test func theAttemptedSetIsScopedToTheProfile() {
        // The composite id carries the profile, so the same record reviewed on
        // a different person is a different fetch — and the same record on the
        // SAME person is not.
        let rows = [row("a", standing: .researched, canLoad: true)]
        let attempted: Set<String> = [
            EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "a")]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: attempted).isEmpty)
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p2", attempted: attempted) == ["a"])
    }

    @Test func nothingToFetchWhenEveryCandidateAlreadyNamesItsKin() {
        let rows = [row("a", standing: .researched, canLoad: false),
                    row("b", standing: .researched, canLoad: false)]
        #expect(AppState.candidateRowsNeedingParishDetail(
            rows, profileID: "p1", attempted: []).isEmpty,
            "a fetched entry is persisted and re-displayed — no repeat request across launches")
    }

    // MARK: - Review F09: overlapping bucket-toggles must not double-fetch

    /// The bucket toggle spawns an unstructured `Task` per click and the source
    /// paces at 1000 ms, so "I clicked and nothing happened" is the normal
    /// appearance of a fetch in flight. Collapsing and re-expanding used to
    /// start a SECOND pass over the same rows, because selection read the
    /// attempted set up front while the claim happened one id at a time inside
    /// the loop, after an `await`. Four GETs where three were intended, at a
    /// volunteer source. Selection and claim are now one step, taken before the
    /// first suspension point.
    @Test func aSecondOverlappingInvocationClaimsNothing() {
        var attempted: Set<String> = []
        let rows = [row("a", standing: .researched, canLoad: true, rank: 90),
                    row("b", standing: .researched, canLoad: true, rank: 80),
                    row("c", standing: .researched, canLoad: true, rank: 70)]
        let first = AppState.claimParishDetailCandidates(
            rows, profileID: "p1", attempted: &attempted)
        #expect(first == ["a", "b", "c"])
        let second = AppState.claimParishDetailCandidates(
            rows, profileID: "p1", attempted: &attempted)
        #expect(second.isEmpty,
                "the whole set is claimed before the first await, so the overlapping toggle has nothing left to fetch")
    }

    @Test func claimingTakesTheReturnedRowsAndNothingElse() {
        // Rows past the cap must stay unclaimed — claiming a row we were never
        // going to fetch would starve it for the whole session.
        var attempted: Set<String> = []
        let rows = [row("a", standing: .researched, canLoad: true, rank: 90),
                    row("b", standing: .researched, canLoad: true, rank: 80),
                    row("c", standing: .researched, canLoad: true, rank: 70),
                    row("d", standing: .researched, canLoad: true, rank: 60)]
        let claimed = AppState.claimParishDetailCandidates(
            rows, profileID: "p1", attempted: &attempted)
        #expect(claimed == ["a", "b", "c"])
        #expect(attempted == Set(["a", "b", "c"].map {
            EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: $0)
        }))
        // …and the capped row is still available on the next open.
        #expect(AppState.claimParishDetailCandidates(
            rows, profileID: "p1", attempted: &attempted) == ["d"])
    }

    @Test func aClaimOnOnePersonDoesNotClaimTheSameRecordOnAnother() {
        var attempted: Set<String> = []
        let rows = [row("a", standing: .researched, canLoad: true)]
        _ = AppState.claimParishDetailCandidates(rows, profileID: "p1", attempted: &attempted)
        #expect(AppState.claimParishDetailCandidates(
            rows, profileID: "p2", attempted: &attempted) == ["a"],
            "the same register entry read against a different person is a different decision")
    }

    // MARK: - EV31 second half: a re-score must not throw the entry away

    private func common(_ id: String, url: String? = "https://www.freereg.org.uk/e/\(UUID().uuidString)",
                        raw: [String: String] = [:]) -> RecordCommon {
        RecordCommon(id: id, sourceID: "freereg", name: "John Wheeldon",
                     surname: "Wheeldon", givenName: "John",
                     detailURL: url, rawFields: raw)
    }

    @Test func aReScoredSearchRowDoesNotWipeTheFetchedRegisterEntry() {
        // The bare results-table row the next run produces…
        let fresh = ParishRecord(
            common: common("r1", raw: ["parish": "Cromford"]),
            eventType: "baptism", eventDate: "09 Sep 1848", eventYear: 1848,
            parish: "Cromford", county: "Derbyshire",
            fatherName: nil, motherName: nil, detail: nil)
        // …over the entry page a GET already paid for.
        let stored = ParishRecord(
            common: common("r1", raw: ["register_type": "PR"]),
            eventType: "baptism", eventDate: "09 Sep 1848", eventYear: 1848,
            parish: "Cromford", county: "Derbyshire",
            fatherName: "John WHEELDON", motherName: "Ruth", detail: nil)
        guard case .parish(let merged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .parish(fresh), stored: .parish(stored)) else {
            Issue.record("parish record expected"); return
        }
        #expect(merged.fatherName == "John WHEELDON",
                "the parents are what decide a namesake — a re-score must not delete them")
        #expect(merged.motherName == "Ruth")
        #expect(merged.common.rawFields["parish"] == "Cromford", "the fresh row's own fields win")
        #expect(merged.common.rawFields["register_type"] == "PR", "stored fields fill the gaps")
    }

    @Test func aFreshRowWithItsOwnParentsIsNotOverwrittenByTheStoredOne() {
        // The top hit of a search IS enriched in-run, so a fresh record can
        // carry newer parents. Newer wins.
        let fresh = ParishRecord(
            common: common("r1"), eventType: "baptism",
            fatherName: "John WHEELDON", motherName: "Ruth", detail: nil)
        let stored = ParishRecord(
            common: common("r1"), eventType: "baptism",
            fatherName: "J. WHEELDON", motherName: "R.", detail: nil)
        guard case .parish(let merged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .parish(fresh), stored: .parish(stored)) else {
            Issue.record("parish record expected"); return
        }
        #expect(merged.fatherName == "John WHEELDON")
        #expect(merged.motherName == "Ruth")
    }

    @Test func aFetchedCensusRosterSurvivesAReScore() {
        let roster = [HouseholdMember(name: "John Wheeldon", relationship: "Head", age: 47),
                      HouseholdMember(name: "Ruth Wheeldon", relationship: "Wife", age: 47)]
        let fresh = CensusRecord(common: common("c1"), censusYear: 1871, age: 47, household: nil)
        let stored = CensusRecord(common: common("c1"), censusYear: 1871, age: 47, household: roster)
        guard case .census(let merged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .census(fresh), stored: .census(stored)) else {
            Issue.record("census record expected"); return
        }
        #expect(merged.household?.count == 2,
                "the household was fetched once; a re-score must not make the user fetch it again")
    }

    @Test func mismatchedIdsAndKindsAreNeverMerged() {
        // Two different records must never bleed into each other — the merge is
        // a restore for ONE record, not a reconciliation between records.
        let fresh = ParishRecord(common: common("r1"), eventType: "baptism")
        let other = ParishRecord(
            common: common("r2"), eventType: "baptism",
            fatherName: "Somebody Else", motherName: "Not Ruth")
        guard case .parish(let merged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .parish(fresh), stored: .parish(other)) else {
            Issue.record("parish record expected"); return
        }
        #expect(merged.fatherName == nil, "a different record's parents are not this record's evidence")

        let censusStored = CensusRecord(common: common("r1"), censusYear: 1871)
        guard case .parish(let unchanged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .parish(fresh), stored: .census(censusStored)) else {
            Issue.record("parish record expected"); return
        }
        #expect(unchanged.fatherName == nil)
    }

    @Test func nothingStoredMeansTheFreshRecordIsWrittenUntouched() {
        let fresh = ParishRecord(common: common("r1"), eventType: "baptism", parish: "Cromford")
        guard case .parish(let merged) = EvidenceEnrichmentMerge.preservingEnrichment(
            fresh: .parish(fresh), stored: nil) else {
            Issue.record("parish record expected"); return
        }
        #expect(merged.parish == "Cromford")
        #expect(merged.detail == nil)
    }
}
