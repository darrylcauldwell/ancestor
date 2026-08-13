import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Change 2 of FREEBMD_CITATION_BACKFILL_SPEC — the info-gap that flags applied
/// FreeBMD evidence with no direct entry link (and births missing the MMN).
struct FreeBMDCitationAuditTests {

    private func evidence(sourceID: String, citationURL: String?,
                          status: UserReviewStatus = .savedAsLead,
                          mmn: String? = "Lees", birthYear: Int = 1920,
                          vol: String = "7b", page: String = "1902") -> EvidenceRecord {
        let common = RecordCommon(id: "\(sourceID)_birth_\(vol)_\(page)_\(UUID().uuidString)",
                                  sourceID: sourceID, rawFields: [:])
        let record: SourceRecord = .birth(BirthRecord(common: common, birthYear: birthYear,
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

    @Test func pre1911BirthWithoutMMNStaysInfo() {
        // MMN entered the GRO index only in Sep 1911 — a Victorian birth (John
        // Cauldwell, 1861) never carried one, so it isn't "missing" and unlocks
        // nothing: link-only, info, no MMN claim in the message.
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "John Cauldwell",
            evidence: [evidence(sourceID: "freebmd", citationURL: nil, mmn: nil, birthYear: 1861)])
        #expect(f?.severity == .info)
        #expect(f?.message.contains("mother's maiden name") == false)
    }

    // MARK: - Change 6 Fix 2 — the audit also reads the applied-fact layer

    /// A profile carrying a link-less FreeBMD field-source citation on the given
    /// field(s). `notes` is the citation text the fingerprint dedupes on.
    private func profileWithFreeBMDFact(
        url: String?, on fields: [ProfileField] = [.deathDate],
        notes: String = "Death: ABRAHAM TWYFORD, Jun 1980, BAKEWELL, vol. 6/40; accessed 5 Aug 2026."
    ) -> Profile {
        let cite = Citation(title: "Death", url: url, notes: notes)
        var sources: [ProfileField: [FieldSource]] = [:]
        for field in fields {
            sources[field] = [FieldSource(origin: .freebmd, raw: "x",
                                          addedAt: Date(timeIntervalSince1970: 0), citation: cite)]
        }
        return Profile(
            id: "@P1@", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: sources, disputes: [:])
    }

    @Test func firesWhenAppliedFactCitationIsLinkLessEvenIfEvidenceHealed() {
        // Abraham 2026-08-10: the evidence row was link-healed on re-research but
        // the published citation stayed bare — evidence-only would go falsely green.
        let healed = evidence(sourceID: "freebmd",
            citationURL: "https://www.freebmd.org.uk/cgi/information.pl?r=9:9&d=bmd_9")
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Abraham Twyford",
            evidence: [healed], profile: profileWithFreeBMDFact(url: nil))
        #expect(f != nil, "a bare published citation must flag even when evidence is healed")
        #expect(f?.message.contains("1 FreeBMD record") == true)
    }

    @Test func silentWhenFactCitationCarriesItsLink() {
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Abraham Twyford", evidence: [],
            profile: profileWithFreeBMDFact(
                url: "https://www.freebmd.org.uk/cgi/information.pl?r=1:2&d=bmd_9"))
        #expect(f == nil)
    }

    @Test func ignoresNonFreeBMDFactCitations() {
        let cite = Citation(title: "Census", url: nil, notes: "FreeCen 1891 census")
        let fs = FieldSource(origin: .freecen, raw: "1891",
                             addedAt: Date(timeIntervalSince1970: 0), citation: cite)
        let profile = Profile(
            id: "@P1@", externalIDs: [:], firstName: "A", lastName: "B", gender: .male,
            attributes: nil, birthDate: nil, birthLocation: nil, deathDate: nil,
            deathLocation: nil, bio: nil, isDeleted: false,
            sources: [.birthDate: [fs]], disputes: [:])
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "A B", evidence: [], profile: profile)
        #expect(f == nil, "only FreeBMD-origin citations are our concern")
    }

    @Test func countsOneRegistrationCitedOnTwoFieldsOnce() {
        // deathDate + deathLocation cite the SAME registration — one record.
        let f = FreeBMDCitationAudit.finding(
            profileID: "@P1@", profileName: "Abraham Twyford", evidence: [],
            profile: profileWithFreeBMDFact(url: nil, on: [.deathDate, .deathLocation]))
        #expect(f?.message.contains("1 FreeBMD record") == true,
                "same registration on two fields must count once")
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

    // MARK: - vol/page recovery from the stable record id (dogfood 2026-08-13)

    @Test func volPageFromFreeBMDIDParsesTheStableID() {
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("freebmd_death_6_122_264339957")?.vol == "6")
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("freebmd_death_6_122_264339957")?.page == "122")
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("freebmd_birth_7b_933_51")?.vol == "7b")
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("freebmd_marriage_8_1465_99")?.page == "1465")
        // Non-freebmd / malformed → nil, never a guess.
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("findagrave_216193100") == nil)
        #expect(FreeBMDCitationAudit.volPageFromFreeBMDID("freebmd_death") == nil)
    }

    /// The three-profile bug: an applied death record whose TYPED volume/page
    /// never populated (nil) but whose id carries the GRO reference must still
    /// yield vol/page — so the enricher stops falsely reporting "no volume/page".
    @Test func volPageRecoversFromIDWhenTypedFieldsAreEmpty() {
        let rec = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "freebmd_death_6_122_264339957", sourceID: "freebmd",
                                 name: "Annie Smith", surname: "SMITH", givenName: "ANNIE",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1979, deathDate: nil, deathPlace: nil, age: 74, quarter: "Dec",
            district: "Basford", volume: nil, page: nil, spouseSurname: nil))
        let vp = FreeBMDCitationAudit.volPage(rec)
        #expect(vp.vol == "6")
        #expect(vp.page == "122")
    }

    /// Typed fields win when present — the id fallback is a backstop, not an override.
    @Test func volPagePrefersTypedFieldsOverID() {
        let rec = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "freebmd_death_9_999_1", sourceID: "freebmd",
                                 name: "X Y", surname: "Y", givenName: "X",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1979, deathDate: nil, deathPlace: nil, age: 74, quarter: "Dec",
            district: "Basford", volume: "6", page: "122", spouseSurname: nil))
        let vp = FreeBMDCitationAudit.volPage(rec)
        #expect(vp.vol == "6")   // typed, not the id's "9"
        #expect(vp.page == "122")
    }
}
