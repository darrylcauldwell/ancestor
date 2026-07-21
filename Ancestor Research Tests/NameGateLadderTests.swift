import Testing
import Foundation
@testable import Ancestor_Research

/// The shared name-gate ladder rework from the 2026-07 sandwich audit.
///
/// - **DS-05** — scribal contractions (Wm, Jno, Thos, Chas, Jas) and Latin
///   register forms (Gulielmus, Johannes, Jacobus) scored 0.0 → the given
///   gate hard-failed → `.impossible`. A conservative equivalence table now
///   resolves them to the canonical modern name.
struct NameGateLadderTests {

    // MARK: - DS-05: scribal contractions & Latin forms

    @Test func censusContractionsResolveToCanonical() {
        #expect(ScoringRules.nameSimilarity("WM", "WILLIAM") >= 0.85)
        #expect(ScoringRules.nameSimilarity("WILLIAM", "WM") >= 0.85)
        #expect(ScoringRules.nameSimilarity("THOS", "THOMAS") >= 0.85)
        #expect(ScoringRules.nameSimilarity("CHAS", "CHARLES") >= 0.85)
        #expect(ScoringRules.nameSimilarity("JAS", "JAMES") >= 0.85)
        #expect(ScoringRules.nameSimilarity("JNO", "JOHN") >= 0.85)
        #expect(ScoringRules.nameSimilarity("ROBT", "ROBERT") >= 0.85)
    }

    @Test func latinFormsResolveToCanonical() {
        #expect(ScoringRules.nameSimilarity("GULIELMUS", "WILLIAM") >= 0.85)
        #expect(ScoringRules.nameSimilarity("JOHANNES", "JOHN") >= 0.85)
        #expect(ScoringRules.nameSimilarity("JACOBUS", "JAMES") >= 0.85)
        #expect(ScoringRules.nameSimilarity("CAROLUS", "CHARLES") >= 0.85)
    }

    @Test func twoContractionsOfSameNameMatch() {
        // 'Gulielmus' (Latin) and 'Wm' (contraction) both resolve to WILLIAM.
        #expect(ScoringRules.nameSimilarity("GULIELMUS", "WM") >= 0.85)
    }

    @Test func contractionTableRejectsAmbiguousAndUnrelated() {
        // Different contractions must not cross-match.
        #expect(ScoringRules.nameSimilarity("WM", "THOMAS") == 0.0)
        #expect(ScoringRules.nameSimilarity("JAS", "JOHN") == 0.0)
        // Deliberately-excluded standalone names must not collapse: 'Maria'
        // and 'Anna' are their own modern names, not Mary / Ann.
        #expect(ScoringRules.nameSimilarity("MARIA", "MARY") == 0.0)
        #expect(ScoringRules.nameSimilarity("ANNA", "ANN") < 0.85)
    }

    @Test func contractedGivenNamePassesTheNameGate() {
        // A birth record indexed "Wm Cauldwell" must reach the name gate as a
        // match for a "William Cauldwell" subject, not hard-fail.
        let result = RecordScorer.classify(
            record: birth(surname: "Cauldwell", given: "Wm"),
            subject: subject(surname: "Cauldwell", given: "William"),
            searchType: .birth
        )
        let name = result.gates.first { $0.gate == .name }
        #expect(name?.outcome != .fail,
                "'Wm' must match 'William' at the name gate — got \(String(describing: name?.outcome))")
        #expect(result.verdict != .impossible)
    }

    @Test func contractedMiddleNamePassesMiddleGuard() {
        // Subject "John Thomas"; a record "John Thos Smith" must not fail the
        // middle-name guard (THOS ≈ THOMAS).
        let result = RecordScorer.classify(
            record: birth(surname: "Smith", given: "John Thos"),
            subject: subject(surname: "Smith", given: "John", middle: "Thomas"),
            searchType: .birth
        )
        let name = result.gates.first { $0.gate == .name }
        #expect(name?.outcome != .fail,
                "contracted middle 'Thos' must match 'Thomas' — got \(String(describing: name?.reason))")
    }

    // MARK: - DS-06: unequal-length surname variants (single insertion/deletion)

    @Test func singleIndelDetectsTranscriptionVariants() {
        #expect(ScoringRules.isSingleIndel("BROOKES", "BROOKS"))
        #expect(ScoringRules.isSingleIndel("BROOKS", "BROOKES"))
        #expect(ScoringRules.isSingleIndel("SIMMS", "SIMS"))
        // Not single-indel: equal length (substitution), or length diff > 1.
        #expect(!ScoringRules.isSingleIndel("SMITH", "SMYTH"))
        #expect(!ScoringRules.isSingleIndel("HARRIS", "HARRISON"))
        #expect(!ScoringRules.isSingleIndel("WOOD", "WOODWARD"))
    }

    @Test func brookesVariantNoLongerHardFails() {
        // George BROOKES / George BROOKS — the canonical George Herbert Brooks
        // case. Previously scored 0.0 → surname hard-fail → .impossible,
        // dropping the record entirely. Now recovers as a reviewable .lead.
        #expect(ScoringRules.nameSimilarity("BROOKES", "BROOKS") >= 0.7)
        let result = RecordScorer.classify(
            record: marriage(surname: "Brookes", given: "George"),
            subject: subject(surname: "Brooks", given: "George"),
            searchType: .marriage
        )
        let name = result.gates.first { $0.gate == .name }
        #expect(name?.outcome == .softFail,
                "an unequal-length surname variant is a reviewable weak match — got \(String(describing: name?.outcome))")
        #expect(result.verdict != .impossible,
                "Brookes/Brooks must be recoverable, not dropped — got \(result.verdict)")
    }

    // MARK: - DS-16: weak surname matches soft-fail instead of auto-facting

    @Test func containmentSurnameSoftFailsNotFact() {
        // Harris/Harrison and Wood/Woodward are distinct families that
        // co-occur in the same districts; containment (0.80) must not
        // auto-promote them to .fact.
        for (record, subj) in [("Harrison", "Harris"), ("Woodward", "Wood")] {
            let result = RecordScorer.classify(
                record: birth(surname: record, given: "John"),
                subject: subject(surname: subj, given: "John"),
                searchType: .birth
            )
            let name = result.gates.first { $0.gate == .name }
            #expect(name?.outcome == .softFail,
                    "\(record) vs \(subj) must soft-fail the name gate — got \(String(describing: name?.outcome))")
            #expect(result.verdict != .fact,
                    "\(record) vs \(subj) must not auto-fact — got \(result.verdict)")
        }
    }

    @Test func singleCharSurnameDiffSoftFails() {
        // Dale/Gale — a one-character surname difference is ambiguous.
        let result = RecordScorer.classify(
            record: birth(surname: "Gale", given: "John"),
            subject: subject(surname: "Dale", given: "John"),
            searchType: .birth
        )
        #expect(result.gates.first { $0.gate == .name }?.outcome == .softFail)
    }

    @Test func strongSurnameVariantStaysStrong() {
        // AU/OU normalisation (Cauldwell/Caldwell, 0.95) and exact matches
        // are fact-grade — the owner's own surname variant must not demote.
        let auOu = RecordScorer.classify(
            record: birth(surname: "Cauldwell", given: "John"),
            subject: subject(surname: "Caldwell", given: "John"),
            searchType: .birth
        )
        #expect(auOu.gates.first { $0.gate == .name }?.outcome == .pass,
                "AU/OU surname variant must stay a strong (pass) match")

        let exact = RecordScorer.classify(
            record: birth(surname: "Smith", given: "John"),
            subject: subject(surname: "Smith", given: "John"),
            searchType: .birth
        )
        #expect(exact.gates.first { $0.gate == .name }?.outcome == .pass)
    }

    // MARK: - Fixtures

    private func subject(surname: String, given: String, middle: String? = nil) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: given,
            middleName: middle,
            birthYearFrom: 1843,
            birthYearTo: 1847,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            )
        )
    }

    private func birth(surname: String, given: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "b-\(surname)-\(given)", sourceID: "freebmd", name: nil,
                surname: surname, givenName: given, detailURL: nil, rawFields: [:]
            ),
            birthYear: 1845, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "19", page: "438",
            mothersMaidenName: nil
        ))
    }

    private func marriage(surname: String, given: String) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(
                id: "m-\(surname)-\(given)", sourceID: "freebmd", name: nil,
                surname: surname, givenName: given, detailURL: nil, rawFields: [:]
            ),
            marriageYear: 1867, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "112",
            spouseName: nil
        ))
    }
}
