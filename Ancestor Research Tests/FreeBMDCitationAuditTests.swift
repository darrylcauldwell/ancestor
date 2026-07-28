import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Change 2 of FREEBMD_CITATION_BACKFILL_SPEC — the info-gap that flags applied
/// FreeBMD evidence with no direct entry link (and births missing the MMN).
struct FreeBMDCitationAuditTests {

    private func evidence(sourceID: String, citationURL: String?,
                          status: UserReviewStatus = .savedAsLead,
                          mmn: String? = "Lees",
                          vol: String = "7b", page: String = "1902") -> EvidenceRecord {
        let common = RecordCommon(id: "\(sourceID)_birth_\(vol)_\(page)_\(UUID().uuidString)",
                                  sourceID: sourceID, rawFields: [:])
        let record: SourceRecord = .birth(BirthRecord(common: common, birthYear: 1920,
                                                       volume: vol, page: page,
                                                       mothersMaidenName: mmn))
        return EvidenceRecord(
            id: EvidenceRecord.compositeID(profileID: "@P1@", sourceRecordID: common.id),
            profileID: "@P1@", sourceID: sourceID, sourceRecordID: common.id,
            recordType: .birth, verdict: .fact, record: record,
            citationFull: "cite", citationURL: citationURL,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: status)
    }

    @Test func firesForAppliedFreeBMDRecordWithNoLink() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora Beresford",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil)])
        #expect(f != nil)
        #expect(f?.severity == .info)
        #expect(f?.category == .gap)
        #expect(f?.ruleID == "freebmdLinkMissing")
        #expect(f?.message.contains("1 FreeBMD record") == true)
    }

    @Test func silentWhenLinkPresent() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd",
                citationURL: "https://www.freebmd.org.uk/cgi/information.pl?r=1:2&d=bmd_9")])
        #expect(f == nil)
    }

    @Test func ignoresNonFreeBMDSources() {
        // FindAGrave/CWGC/FS carry their own detail URLs — not our concern.
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "findagrave", citationURL: nil)])
        #expect(f == nil)
    }

    @Test func ignoresUnappliedEvidence() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, status: .unreviewed)])
        #expect(f == nil)
    }

    @Test func notesBirthsAlsoMissingMothersMaidenName() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, mmn: nil)])
        #expect(f?.message.contains("mother's maiden name") == true)
    }

    @Test func doesNotClaimMMNMissingWhenPresent() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, mmn: "Lees")])
        #expect(f != nil)
        #expect(f?.message.contains("mother's maiden name") == false)
    }

    @Test func warningSeverityWhenABirthLacksMMN() {
        // A missing MMN gates parent inference — it unlocks new data, so it's an
        // actionable warning, not cosmetic info.
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, mmn: nil)])
        #expect(f?.severity == .warning)
    }

    @Test func infoSeverityWhenLinkOnlyGap() {
        // A link gap with the MMN already present unlocks nothing new — info.
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, mmn: "Lees")])
        #expect(f?.severity == .info)
    }

    @Test func aggregatesMultipleRecordsIntoOneFinding() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil),
                       evidence(sourceID: "freebmd", citationURL: nil),
                       evidence(sourceID: "freebmd", citationURL: "https://x")])
        #expect(f?.message.contains("2 FreeBMD records") == true)  // the linked one excluded
    }

    // MARK: - Change 3 — cross-transcription link reconciliation

    @Test func reconcilesLinkFromSiblingTranscriptionSameGROEntry() {
        // Applied record (no link) + a sibling for the SAME vol/page that has a
        // link → the applied one adopts it.
        let applied = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let sibling = evidence(sourceID: "freebmd",
                               citationURL: "https://www.freebmd.org.uk/cgi/information.pl?r=143220917:8511&d=bmd_1",
                               status: .unreviewed, vol: "7b", page: "1902")
        let updates = FreeBMDCitationAudit.linkReconciliation(evidence: [applied, sibling])
        #expect(updates.count == 1)
        #expect(updates.first?.evidenceID == applied.id)
        #expect(updates.first?.citationURL.contains("143220917:8511") == true)
    }

    @Test func doesNotReconcileAcrossDifferentGROEntries() {
        let applied = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let other = evidence(sourceID: "freebmd", citationURL: "https://x",
                             status: .unreviewed, vol: "3a", page: "88")   // different entry
        #expect(FreeBMDCitationAudit.linkReconciliation(evidence: [applied, other]).isEmpty)
    }

    @Test func noReconciliationWhenNoDonorHasLink() {
        let a = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let b = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        #expect(FreeBMDCitationAudit.linkReconciliation(evidence: [a, b]).isEmpty)
    }

    @Test func reconciliationOnlyTargetsAppliedRecords() {
        // An unreviewed link-less record is not a recipient — only applied ones.
        let unreviewed = evidence(sourceID: "freebmd", citationURL: nil, status: .unreviewed,
                                  vol: "7b", page: "1902")
        let donor = evidence(sourceID: "freebmd", citationURL: "https://x",
                             status: .savedAsLead, vol: "7b", page: "1902")
        #expect(FreeBMDCitationAudit.linkReconciliation(evidence: [unreviewed, donor]).isEmpty)
    }

    // MARK: - Change 5 — targeted enrichment from a fresh FreeBMD lookup

    /// A fresh FreeBMD result row (as the current parser produces it): carries a
    /// detailURL + MMN + vol/page.
    private func result(vol: String = "7b", page: String = "1902",
                        url: String?, mmn: String? = "Lees") -> SourceRecord {
        let common = RecordCommon(id: "freebmd_birth_\(vol)_\(page)_\(UUID().uuidString)",
                                  sourceID: "freebmd", detailURL: url, rawFields: [:])
        return .birth(BirthRecord(common: common, birthYear: 1920, volume: vol, page: page,
                                  mothersMaidenName: mmn))
    }

    @Test func enrichmentMatchesByVolPageAndTakesLinkAndMMN() {
        let flagged = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let fresh = result(vol: "7b", page: "1902",
                           url: "https://www.freebmd.org.uk/cgi/information.pl?r=143220917:8511&d=bmd_1",
                           mmn: "Lees")
        let updates = FreeBMDCitationAudit.enrichmentUpdates(flagged: [flagged], results: [fresh])
        #expect(updates.count == 1)
        #expect(updates.first?.evidenceID == flagged.id)
        #expect(updates.first?.citationURL.contains("143220917:8511") == true)
        #expect(updates.first?.mothersMaidenName == "Lees")   // the cascade seed
    }

    @Test func enrichmentIgnoresResultsForADifferentGROEntry() {
        let flagged = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let wrongEntry = result(vol: "3a", page: "88", url: "https://x")
        #expect(FreeBMDCitationAudit.enrichmentUpdates(flagged: [flagged], results: [wrongEntry]).isEmpty)
    }

    @Test func enrichmentIgnoresResultsWithNoLink() {
        let flagged = evidence(sourceID: "freebmd", citationURL: nil, vol: "7b", page: "1902")
        let linkless = result(vol: "7b", page: "1902", url: nil)
        #expect(FreeBMDCitationAudit.enrichmentUpdates(flagged: [flagged], results: [linkless]).isEmpty)
    }

    @Test func enrichmentSkipsRecordsThatAlreadyHaveALink() {
        let alreadyLinked = evidence(sourceID: "freebmd", citationURL: "https://have", vol: "7b", page: "1902")
        let fresh = result(vol: "7b", page: "1902", url: "https://new")
        #expect(FreeBMDCitationAudit.enrichmentUpdates(flagged: [alreadyLinked], results: [fresh]).isEmpty)
    }
}
