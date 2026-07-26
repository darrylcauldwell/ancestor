import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// #CPC-Change3 acceptance tests (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md`
/// Change 3): the in-run annotation step — spouse's persisted evidence →
/// pre-scoring `corroborating*` stamps on candidate marriage records — plus
/// the new gate-4 arm and the load-bearing property that THIS change moves
/// no verdicts.
struct CrossProfileAnnotationTests {

    // MARK: - Criterion 1: demonstrator record annotated, namesakes untouched

    @Test func annotatesTheMatchingBatchRecordOnly() throws {
        let (snapshot, _) = try demonstratorSnapshot()
        let batch: [SourceRecord] = [
            .marriage(maryMarriage(id: "mary-2130a")),
            .marriage(namesakeMarriage(id: "namesake-1", page: "800")),
            .marriage(namesakeMarriage(id: "namesake-2", page: "912")),
        ]
        let outcome = CrossProfileAnnotator.annotate(
            records: batch,
            subjectProfileID: "@MARY@",
            snapshot: snapshot,
            evidenceLookup: williamEvidenceLookup()
        )
        #expect(outcome.annotatedCount == 1)
        let annotated = outcome.records.compactMap { record -> MarriageRecord? in
            guard case .marriage(let m) = record else { return nil }
            return m
        }
        let target = try #require(annotated.first { $0.common.id == "mary-2130a" })
        #expect(target.corroboratingSpouseProfileID == "@WILLIAM@")
        #expect(target.corroboratingSpouseRecordID == "william-2130a")
        #expect(target.corroborationTier == "reciprocal")
        #expect(target.corroborationAnchor == "weak")
        for namesake in annotated where namesake.common.id != "mary-2130a" {
            #expect(namesake.corroboratingSpouseProfileID == nil)
        }
    }

    // MARK: - Criterion 5 (the property): this change moves NO verdicts

    @Test func annotationDoesNotChangeTheVerdict() throws {
        let (snapshot, _) = try demonstratorSnapshot()
        let plain = SourceRecord.marriage(maryMarriage(id: "mary-2130a"))
        let annotated = CrossProfileAnnotator.annotate(
            records: [plain],
            subjectProfileID: "@MARY@",
            snapshot: snapshot,
            evidenceLookup: williamEvidenceLookup()
        ).records[0]

        let subject = marySubject()
        let before = RecordScorer.classify(record: plain, subject: subject, searchType: .marriage)
        let after = RecordScorer.classify(record: annotated, subject: subject, searchType: .marriage)
        #expect(before.verdict == after.verdict,
                "Change 3 is purely additive — verdict movement is Change 4's doctrine change")
        #expect(after.verdict == .lead, "thin Mary still holds at lead until Change 4")
        // But the record is now human-applicable via the family gate.
        #expect(RecordScorer.wouldApply(after))
    }

    // MARK: - Criterion 2: the new gate-4 arm (no earlier arm fires)

    @Test func gateArmPassesOnAnnotationWhenNoSpouseColumnExists() {
        // Pre-1912-shaped record: no spouse column, no same-page inference —
        // only the cross-profile annotation identifies the partner.
        let record = MarriageRecord(
            common: RecordCommon(id: "m-1", sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY ELLEN",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Jun", district: "Bakewell", volume: "7b", page: "500",
            spouseName: nil,
            corroboratingSpouseProfileID: "@WILLIAM@",
            corroboratingSpouseRecordID: "w-1",
            corroborationTier: "samePagePrior",
            corroborationAnchor: "weak"
        )
        let result = RecordScorer.classify(record: .marriage(record), subject: marySubject(), searchType: .marriage)
        let gate = result.gates.first { $0.gate == .familyContext }
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.contains("cross-profile") == true)
    }

    // MARK: - Criterion 3: deterministic no-ops

    @Test func noOpWithoutProfileIDOrLookup() throws {
        let (snapshot, _) = try demonstratorSnapshot()
        let batch: [SourceRecord] = [.marriage(maryMarriage(id: "mary-2130a"))]

        let noProfile = CrossProfileAnnotator.annotate(
            records: batch, subjectProfileID: nil,
            snapshot: snapshot, evidenceLookup: williamEvidenceLookup())
        #expect(noProfile.annotatedCount == 0)

        let noLookup = CrossProfileAnnotator.annotate(
            records: batch, subjectProfileID: "@MARY@",
            snapshot: snapshot, evidenceLookup: nil)
        #expect(noLookup.annotatedCount == 0)
    }

    // MARK: - Criterion 4: Codable-additive round-trip

    @Test func preChangeJSONDecodesWithNilCorroborationFields() throws {
        let old = """
        {"common":{"id":"m-old","sourceID":"freebmd","rawFields":{}},
         "marriageYear":1915,"quarter":"Dec","district":"Bakewell",
         "volume":"7b","page":"2130a","spouseName":"Holmes"}
        """
        let decoded = try JSONDecoder().decode(
            MarriageRecord.self, from: Data(old.utf8))
        #expect(decoded.corroboratingSpouseProfileID == nil)
        #expect(decoded.corroborationTier == nil)

        // And the stamped fields survive their own round-trip.
        let stamped = MarriageRecord(
            common: decoded.common, marriageYear: decoded.marriageYear,
            marriageDate: nil, marriagePlace: nil,
            quarter: decoded.quarter, district: decoded.district,
            volume: decoded.volume, page: decoded.page,
            spouseName: decoded.spouseName,
            corroboratingSpouseProfileID: "@WILLIAM@",
            corroboratingSpouseRecordID: "w-1",
            corroborationTier: "reciprocal",
            corroborationAnchor: "strong"
        )
        let rehydrated = try JSONDecoder().decode(
            MarriageRecord.self, from: JSONEncoder().encode(stamped))
        #expect(rehydrated.corroboratingSpouseProfileID == "@WILLIAM@")
        #expect(rehydrated.corroborationAnchor == "strong")
    }

    // MARK: - Criterion 8: exclusions honoured at annotation time

    @Test func discardedPartnerEvidencePreventsAnnotation() throws {
        let (snapshot, _) = try demonstratorSnapshot()
        let outcome = CrossProfileAnnotator.annotate(
            records: [.marriage(maryMarriage(id: "mary-2130a"))],
            subjectProfileID: "@MARY@",
            snapshot: snapshot,
            evidenceLookup: williamEvidenceLookup(userStatus: .discarded)
        )
        #expect(outcome.annotatedCount == 0)
    }

    // MARK: - Collapsed transcription variants both annotate

    @Test func duplicateTranscriptionsInBatchBothAnnotate() throws {
        let (snapshot, _) = try demonstratorSnapshot()
        let batch: [SourceRecord] = [
            .marriage(maryMarriage(id: "mary-2130a")),
            .marriage(maryMarriage(id: "mary-2130a-variant")),
        ]
        let outcome = CrossProfileAnnotator.annotate(
            records: batch,
            subjectProfileID: "@MARY@",
            snapshot: snapshot,
            evidenceLookup: williamEvidenceLookup()
        )
        #expect(outcome.annotatedCount == 2,
                "both transcription variants of the one index line carry the annotation")
    }

    // MARK: - Directed fetch (multi-marriage completion)

    @Test func directedFetchTargetsTheSpouseHeldReferenceTheSubjectLacks() {
        // Keyworth holds his 1896 marriage (7b/74); his spouse Elizabeth
        // holds the 1909 one (7b/1518) he's missing. The work-list must name
        // exactly the 1909 page to go fetch his side of.
        let keyworth1896 = marriageAt(vol: "7b", page: "74", year: 1896, quarter: "Mar", surname: "KEYWORTH")
        let elizabeth1909 = marriageAt(vol: "7b", page: "1518", year: 1909, quarter: "Sep", surname: "WALLACE")

        let targets = CrossProfileAnnotator.directedFetchTargets(
            subjectHeld: [keyworth1896],
            spouseHeld: [elizabeth1909])
        // Quarter + district carry from the spouse's record so the pulled
        // side keys identically (same register page → same district/quarter).
        #expect(targets == [.init(volume: "7b", page: "1518", year: 1909,
                                  quarter: "Sep", district: "Chesterfield")])
    }

    @Test func directedFetchSkipsReferencesTheSubjectAlreadyHolds() {
        // Both sides already hold the same reference → nothing to fetch (the
        // corroboration JOIN already has both records).
        let his = marriageAt(vol: "7b", page: "2130a", year: 1915, quarter: "Dec", surname: "HOLMES")
        let hers = marriageAt(vol: "7b", page: "2130a", year: 1915, quarter: "Dec", surname: "THOMPSON")
        let targets = CrossProfileAnnotator.directedFetchTargets(
            subjectHeld: [his], spouseHeld: [hers])
        #expect(targets.isEmpty)
    }

    @Test func directedFetchIgnoresSpouseRecordsWithoutVolPage() {
        let noKey = marriageAt(vol: nil, page: nil, year: 1909, quarter: "Sep", surname: "WALLACE")
        let targets = CrossProfileAnnotator.directedFetchTargets(
            subjectHeld: [], spouseHeld: [noKey])
        #expect(targets.isEmpty)
    }

    @Test func directedFetchDedupesRepeatedSpouseReferences() {
        // Two transcriptions of the spouse's one 1909 record → one target.
        let a = marriageAt(vol: "7b", page: "1518", year: 1909, quarter: "Sep", surname: "WALLACE")
        let b = marriageAt(vol: "7b", page: "1518", year: 1909, quarter: "Sep", surname: "WALLACE")
        let targets = CrossProfileAnnotator.directedFetchTargets(
            subjectHeld: [], spouseHeld: [a, b])
        #expect(targets.count == 1)
    }

    private func marriageAt(
        vol: String?, page: String?, year: Int?, quarter: String, surname: String
    ) -> MarriageRecord {
        MarriageRecord(
            common: RecordCommon(id: "\(surname)-\(vol ?? "x")-\(page ?? "x")", sourceID: "freebmd",
                                 name: nil, surname: surname, givenName: "X",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: year, marriageDate: nil, marriagePlace: nil,
            quarter: quarter, district: "Chesterfield", volume: vol, page: page,
            spouseName: nil)
    }

    // MARK: - Fixtures

    /// Tree: Mary (name only) ×spouse× William (d.1919), via a temp DB so
    /// the snapshot shape is the production one.
    private func demonstratorSnapshot() throws -> (FamilyGraphSnapshot, ProjectDatabase) {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        _ = try db.addProfile(Profile(
            id: "@MARY@", externalIDs: [:], firstName: "Mary Ellen", middleName: nil,
            lastName: "Thompson", gender: .female, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        _ = try db.addProfile(Profile(
            id: "@WILLIAM@", externalIDs: [:], firstName: "William", middleName: nil,
            lastName: "Holmes", gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1919"), deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "@MARY@", to: "@WILLIAM@", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil,
            divorceDate: nil))
        return (try db.buildSnapshot(), db)
    }

    private func williamEvidenceLookup(
        userStatus: UserReviewStatus = .unreviewed
    ) -> ((String) -> [EvidenceRecord]) {
        let williamRow = EvidenceRecord(
            id: "@WILLIAM@|william-2130a", profileID: "@WILLIAM@",
            sourceID: "freebmd", sourceRecordID: "william-2130a",
            recordType: .marriage, verdict: .lead,
            record: .marriage(MarriageRecord(
                common: RecordCommon(id: "william-2130a", sourceID: "freebmd",
                                     name: nil, surname: "HOLMES", givenName: "WILLIAM",
                                     detailURL: nil, rawFields: [:]),
                marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
                quarter: "Dec", district: "Bakewell", volume: "7b", page: "2130a",
                spouseName: "Thompson")),
            citationFull: nil, citationURL: nil, scoredAt: Date(),
            userStatus: userStatus
        )
        return { profileID in profileID == "@WILLIAM@" ? [williamRow] : [] }
    }

    private func maryMarriage(id: String) -> MarriageRecord {
        MarriageRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY ELLEN",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: "2130a",
            spouseName: "Holmes")
    }

    private func namesakeMarriage(id: String, page: String) -> MarriageRecord {
        MarriageRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY ELLEN",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: page,
            spouseName: "Smith")
    }

    /// Mary as her run sees her: name only, spouse context from the tree,
    /// no birth window (the thin demonstrator shape).
    private func marySubject() -> ResearchSubject {
        ResearchSubject(
            surname: "Thompson",
            givenName: "Mary Ellen",
            middleName: nil,
            birthYearFrom: nil,
            birthYearTo: nil,
            gender: .female,
            region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "William Holmes",
                spouseSurname: "Holmes",
                spouseGivenName: "William",
                spouseFatherSurname: nil,
                childNames: ["Reginald Holmes"],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            )
        )
    }
}
