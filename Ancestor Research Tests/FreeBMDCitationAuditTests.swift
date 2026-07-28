import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Change 2 of FREEBMD_CITATION_BACKFILL_SPEC — the info-gap that flags applied
/// FreeBMD evidence with no direct entry link (and births missing the MMN).
struct FreeBMDCitationAuditTests {

    private func evidence(sourceID: String, citationURL: String?,
                          status: UserReviewStatus = .savedAsLead,
                          mmn: String? = "Lees") -> EvidenceRecord {
        let common = RecordCommon(id: "\(sourceID)_birth_7b_1902_\(UUID().uuidString)",
                                  sourceID: sourceID, rawFields: [:])
        let record: SourceRecord = .birth(BirthRecord(common: common, birthYear: 1920,
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

    @Test func aggregatesMultipleRecordsIntoOneFinding() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Nora",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil),
                       evidence(sourceID: "freebmd", citationURL: nil),
                       evidence(sourceID: "freebmd", citationURL: "https://x")])
        #expect(f?.message.contains("2 FreeBMD records") == true)  // the linked one excluded
    }
}
