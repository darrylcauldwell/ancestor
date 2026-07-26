import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// #CPC-Change4 pinned suite (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md`
/// Change 4; SANDWICH gate-repair convention — every gate change ships
/// pinned by named tests). The bounded elevation: a reciprocal-tier,
/// STRONG-anchor cross-profile annotation lifts a marriage record to
/// `.fact` when — and only when — the sole blocker is insufficient subject
/// information (the nil-window date fail, or the thin-subject cap). Every
/// bounding condition is independently falsified back to `.lead`.
struct CrossProfileElevationTests {

    // MARK: - The elevation fires (nil-window Mary + strong anchor)

    @Test func strongAnchorReciprocalAnnotationElevatesNilWindowSubject() {
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "strong"),
            subject: mary(), searchType: .marriage)
        #expect(result.verdict == .fact,
                "date failed only on insufficient information; the spouse's persisted record supplies the identification")
    }

    @Test func elevationSurvivesRecordJSONRoundTrip() throws {
        // Re-stomp proxy: the persisted record re-classifies identically —
        // the elevation is an input the scorer reproduces, never a stored
        // verdict flip.
        guard case .marriage(let m) = annotatedRecord(tier: "reciprocal", anchor: "strong") else {
            Issue.record("fixture shape"); return
        }
        let rehydrated = try JSONDecoder().decode(MarriageRecord.self, from: JSONEncoder().encode(m))
        let result = RecordScorer.classify(
            record: .marriage(rehydrated), subject: mary(), searchType: .marriage)
        #expect(result.verdict == .fact)
    }

    // MARK: - Thin-cap exemption (wide-window subject, clean date pass)

    @Test func thinCapLiftsForStrongAnchorReciprocalAnnotation() {
        // Child-derived 27-year window: date gate passes, thin cap would
        // demote — the annotation is the external discrimination the cap
        // demands, so it lifts.
        let wideWindow = mary(birthYearFrom: 1871, birthYearTo: 1898)
        let annotated = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "strong"),
            subject: wideWindow, searchType: .marriage)
        #expect(annotated.verdict == .fact)

        let plain = RecordScorer.classify(
            record: plainRecord(), subject: wideWindow, searchType: .marriage)
        #expect(plain.verdict == .lead, "without the annotation the thin cap holds")
    }

    // MARK: - Every bounding condition independently falsified

    @Test func samePagePriorTierDoesNotElevate() {
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "samePagePrior", anchor: "strong"),
            subject: mary(), searchType: .marriage)
        #expect(result.verdict == .lead)
    }

    @Test func weakAnchorDoesNotElevate() {
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "weak"),
            subject: mary(), searchType: .marriage)
        #expect(result.verdict == .lead)
    }

    @Test func noAnchorDoesNotElevate() {
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "none"),
            subject: mary(), searchType: .marriage)
        #expect(result.verdict == .lead)
    }

    @Test func unannotatedRecordNeverElevates() {
        // The determinism boundary: no annotation (which only
        // CrossProfileAnnotator writes, from persisted evidence rows) means
        // no elevation — there is no other route into the clause.
        let result = RecordScorer.classify(
            record: plainRecord(), subject: mary(), searchType: .marriage)
        #expect(result.verdict == .lead)
    }

    @Test func geographySoftFailBlocksElevation() {
        // Unknown district → geography softFail → zero-softFail condition
        // fails; conservative refusal.
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "strong"),
            subject: mary(homeChapmanCode: ""), searchType: .marriage)
        #expect(result.verdict == .lead)
    }

    @Test func nameSoftFailBlocksElevation() {
        // Subject given name unknown → name gate soft-fails (surname-only
        // cannot confirm identity) → elevation refused.
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "strong"),
            subject: mary(givenName: nil), searchType: .marriage)
        #expect(result.verdict != .fact)
    }

    @Test func marriageAfterSubjectDeathIsNeverElevated() {
        // The date gate's nil-window guard fires BEFORE its death check, so
        // for a birth-windowless dead subject the fail reason reads
        // "insufficient information" while a marriage-after-death
        // contradiction sits unexamined — the predicate's own death
        // re-check must refuse (this test originally exposed exactly that
        // hole: the clause elevated a record post-dating the subject's
        // death).
        let dead = mary(deathYearFrom: 1910, deathYearTo: 1910)
        let result = RecordScorer.classify(
            record: annotatedRecord(tier: "reciprocal", anchor: "strong"),
            subject: dead, searchType: .marriage)
        #expect(result.verdict != .fact,
                "a subject dead in 1910 cannot have a 1915 marriage elevated — got \(result.verdict)")
    }

    // MARK: - Fixtures

    private func annotatedRecord(tier: String, anchor: String) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(id: "mary-2130a", sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY ELLEN",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: "2130a",
            spouseName: "Holmes",
            corroboratingSpouseProfileID: "@WILLIAM@",
            corroboratingSpouseRecordID: "william-2130a",
            corroborationTier: tier,
            corroborationAnchor: anchor))
    }

    private func plainRecord() -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(id: "mary-2130a", sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY ELLEN",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: "2130a",
            spouseName: "Holmes"))
    }

    private func mary(
        givenName: String? = "Mary Ellen",
        birthYearFrom: Int? = nil, birthYearTo: Int? = nil,
        deathYearFrom: Int? = nil, deathYearTo: Int? = nil,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: "Thompson",
            givenName: givenName,
            middleName: nil,
            birthYearFrom: birthYearFrom,
            birthYearTo: birthYearTo,
            deathYearFrom: deathYearFrom,
            deathYearTo: deathYearTo,
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
            ),
            homeChapmanCode: homeChapmanCode
        )
    }
}
