import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 9 — validate-enrichment-parents gate.
/// Mirrors Python `agent/rules.py:525 validate_enrichment_parents`.
/// When a record carries the mother's maiden surname AND the subject's
/// linked mother on the tree has a known surname, a mismatch is the
/// classic wrong-person enrichment signature. The family-context gate
/// soft-fails rather than silently auto-promoting.
@MainActor
struct EnrichmentParentValidationTests {

    private func subject(
        motherSurname: String? = nil,
        familyContextProvided: Bool = true
    ) -> ResearchSubject {
        let context: FamilyContext? = familyContextProvided
            ? FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil,
                childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: motherSurname,
                motherGivenName: nil
            )
            : nil
        return ResearchSubject(
            profileID: "subj-1",
            surname: "Brooks", givenName: "Lilian", middleName: nil,
            birthYearFrom: 1914, birthYearTo: 1914,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .female, region: nil,
            mode: .verify, familyContext: context,
            homeChapmanCode: "DBY"
        )
    }

    private func birthRecord(mmn: String?) -> SourceRecord {
        let common = RecordCommon(
            id: "test-birth", sourceID: "freebmd",
            name: "Lilian Brooks",
            surname: "Brooks", givenName: "Lilian",
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common,
            birthYear: 1914, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper",
            volume: "7b", page: "100",
            mothersMaidenName: mmn
        )
        return .birth(birth)
    }

    // MARK: - Positive path

    @Test func familyContext_passesWhenMMNMatchesLinkedMotherSurname() {
        // Subject's linked mother is Land; record's MMN is Land. Pass.
        let s = subject(motherSurname: "Land")
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: "Land"),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate?.outcome == .pass)
        #expect((familyGate?.reason ?? "").contains("Land"))
    }

    @Test func familyContext_passesUnderCaseAndSimilarityTolerance() {
        // Case-insensitive: "land" vs "Land".
        let s = subject(motherSurname: "Land")
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: "land"),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate?.outcome == .pass)
    }

    // MARK: - Negative path — wrong-person enrichment

    @Test func familyContext_softFailsOnMMNConflict() {
        // Record claims MMN=Smith but linked mother is Land. Wrong person.
        let s = subject(motherSurname: "Land")
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: "Smith"),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate?.outcome == .softFail)
        let reason = familyGate?.reason ?? ""
        #expect(reason.contains("Smith"))
        #expect(reason.contains("Land"))
        #expect(reason.lowercased().contains("conflict") || reason.lowercased().contains("wrong"))
    }

    // MARK: - Skip paths — no data to validate against

    // Note on .skip semantics: per RecordScorer.classify (line 74), gate
    // results with outcome `.skip` are NOT appended to `gates`. So a
    // "skip" outcome shows up as absence of `.familyContext` in the
    // gates list — the assertions below pin that contract.

    @Test func familyContext_skipsWhenNoLinkedMother() {
        // Subject has familyContext but motherSurname is nil → can't validate.
        // Gate should fall through to .skip, not softFail.
        let s = subject(motherSurname: nil)
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: "Smith"),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate == nil, "skip outcomes aren't appended — no family gate in the list means we skipped")
    }

    @Test func familyContext_skipsWhenRecordHasNoMMN() {
        // Pre-Sep-1911 birth records have no MMN. Nothing to validate.
        let s = subject(motherSurname: "Land")
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: nil),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate == nil, "no MMN on record = nothing to validate against = skip")
    }

    @Test func familyContext_skipsWhenNoFamilyContextAtAll() {
        // Subject built without family context → gate skips entirely.
        let s = subject(familyContextProvided: false)
        let scored = RecordScorer.classify(
            record: birthRecord(mmn: "Smith"),
            subject: s, searchType: .birth
        )
        let familyGate = scored.gates.first { $0.gate == .familyContext }
        #expect(familyGate == nil, "no family context on subject = nothing to validate = skip")
    }
}
