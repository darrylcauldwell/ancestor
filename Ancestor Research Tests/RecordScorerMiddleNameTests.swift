import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the middle-name guard in `RecordScorer.checkName`.
///
/// Anchored to the May 2026 Jennifer Holmes failure mode: five candidate
/// "Jennifer Holmes 1947-49" births all passed the name gate because middle
/// initials weren't compared. With "Margaret" set as the subject's middle
/// name, "Jennifer A Holmes" should now name-fail while "Jennifer M Holmes"
/// continues to pass.
struct RecordScorerMiddleNameTests {

    // MARK: - Helpers

    private func subject(
        given: String = "Jennifer",
        middle: String? = nil,
        surname: String = "Holmes",
        birthYear: Int = 1948
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: given,
            middleName: middle,
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            gender: .female,
            region: .englandAndWales,
            mode: .extend
        )
    }

    private func birthRecord(
        givenName: String,
        surname: String = "Holmes",
        year: Int = 1948,
        district: String = "Belper"
    ) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "rec-\(givenName)-\(year)",
                sourceID: "freebmd",
                name: nil,
                surname: surname,
                givenName: givenName,
                detailURL: nil,
                rawFields: [:]
            ),
            birthYear: year,
            birthDate: nil,
            birthPlace: nil,
            quarter: nil,
            district: district,
            volume: nil,
            page: nil,
            mothersMaidenName: nil
        ))
    }

    // MARK: - Tests

    @Test func subjectWithoutMiddleNameIgnoresRecordMiddle() {
        // Backwards-compatible: subject has no middle name set, so we don't
        // care what's in the record's middle position.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer A"),
            subject: subject(middle: nil),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }

    @Test func subjectMiddleMatchesRecordInitial() {
        // The canonical fix: Margaret matches "Jennifer M Holmes".
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer M"),
            subject: subject(middle: "Margaret"),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }

    @Test func subjectMiddleRejectsWrongInitial() {
        // The principled rejection: Margaret rejects "Jennifer A Holmes" — a
        // different person.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer A"),
            subject: subject(middle: "Margaret"),
            searchType: .birth
        )
        // Name gate failure → lead in `.all` mode but impossible in extend.
        // Pipeline mode is .extend by default in these tests.
        guard let nameGate = result.gates.first(where: { $0.gate == .name }) else {
            Issue.record("expected a name gate result")
            return
        }
        #expect(nameGate.outcome == .fail,
                "name gate should fail when middle initial mismatches; reason=\(nameGate.reason)")
    }

    @Test func subjectMiddleMatchesFullRecordMiddle() {
        // Record carries the full middle name, not just an initial.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer Margaret"),
            subject: subject(middle: "Margaret"),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }

    @Test func subjectMiddleRejectsDifferentFullMiddle() {
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer Mary"),
            subject: subject(middle: "Margaret"),
            searchType: .birth
        )
        guard let nameGate = result.gates.first(where: { $0.gate == .name }) else {
            Issue.record("expected a name gate result")
            return
        }
        #expect(nameGate.outcome == .fail,
                "MARY ≠ MARGARET should fail; reason=\(nameGate.reason)")
    }

    @Test func recordWithoutMiddleContentPassesAnyway() {
        // A bare "Jennifer Holmes" record shouldn't be rejected for a
        // "Jennifer Margaret" subject — it just has no middle info to compare.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jennifer"),
            subject: subject(middle: "Margaret"),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }

    @Test func multiTokenSubjectMiddleHonoursFirstToken() {
        // Subject "Mary Ann" with record middle "M" — first initial matches.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Jane M"),
            subject: subject(given: "Jane", middle: "Mary Ann"),
            searchType: .birth
        )
        guard let nameGate = result.gates.first(where: { $0.gate == .name }) else {
            Issue.record("expected a name gate result")
            return
        }
        #expect(nameGate.outcome == .pass)
    }

    @Test func subjectMiddleIsCaseInsensitive() {
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "JENNIFER M"),
            subject: subject(middle: "margaret"),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }
}
