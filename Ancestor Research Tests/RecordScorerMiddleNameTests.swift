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

    @Test func multiTokenGivenSplitsImpliedMiddle() {
        // GEDCOM imports the full given string into firstName and leaves
        // middleName empty (parseGEDCOMName returns "Ernest Victor" as one
        // value). Without compensation, an "Ernest Peter" record would
        // pass the gate against an "Ernest Victor" subject because both
        // share "ERNEST" as their first token. The scorer now treats the
        // second token of subject.givenName as the effective middle when
        // middleName is empty.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Ernest Peter", surname: "Cauldwell", year: 1919),
            subject: ResearchSubject(
                surname: "Cauldwell",
                givenName: "Ernest Victor",
                middleName: nil,
                birthYearFrom: 1919,
                birthYearTo: 1919,
                gender: .male,
                region: .englandAndWales,
                mode: .extend
            ),
            searchType: .birth
        )
        guard let nameGate = result.gates.first(where: { $0.gate == .name }) else {
            Issue.record("expected a name gate result")
            return
        }
        #expect(nameGate.outcome == .fail)
    }

    @Test func multiTokenGivenStillAcceptsMatchingMiddle() {
        // Symmetric to the above — "Ernest V" / "Ernest Victor" record
        // SHOULD pass against subject with given="Ernest Victor" and no
        // explicit middleName. The implicit-middle derivation produces
        // personMiddle="VICTOR", which matches the record's "V" via the
        // existing first-initial rule.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Ernest V", surname: "Cauldwell", year: 1919),
            subject: ResearchSubject(
                surname: "Cauldwell",
                givenName: "Ernest Victor",
                middleName: nil,
                birthYearFrom: 1919,
                birthYearTo: 1919,
                gender: .male,
                region: .englandAndWales,
                mode: .extend
            ),
            searchType: .birth
        )
        #expect(result.verdict != .impossible)
    }

    @Test func explicitMiddleFieldStillWinsWhenSet() {
        // When middleName IS set, trust the explicit value. Subject
        // given="Mary Ann" + middle="Susanne" should NOT split "Ann" as
        // the effective middle; the user told us "Susanne" is the middle.
        // Record "Mary Ann Holmes" should pass — record's "Ann" doesn't
        // mismatch subject's explicit middle "Susanne" because the gate
        // matches first-initial-or-substring, and "Ann"+"Susanne" don't
        // share that. Confirms the explicit field still wins.
        let result = RecordScorer.classify(
            record: birthRecord(givenName: "Mary Ann", surname: "Holmes", year: 1948),
            subject: ResearchSubject(
                surname: "Holmes",
                givenName: "Mary Ann",
                middleName: "Susanne",
                birthYearFrom: 1948,
                birthYearTo: 1948,
                gender: .female,
                region: .englandAndWales,
                mode: .extend
            ),
            searchType: .birth
        )
        // Record middle "Ann" vs subject middle "Susanne" — first
        // initials A vs S — fail. Confirms explicit middleName isn't
        // overridden by the implicit-split rule.
        guard let nameGate = result.gates.first(where: { $0.gate == .name }) else {
            Issue.record("expected a name gate result")
            return
        }
        #expect(nameGate.outcome == .fail)
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

// MARK: - Probate / burial death-axis tests

/// Tests for the unification of `.death` / `.probate` / `.burial` in
/// `RecordScorer.checkDate`'s `searchType` switch. Pre-fix, probate records
/// fell through to the default `birth-window` branch and got marked
/// `.impossible` — a death-year record (e.g. 1980) compared against a
/// birth-year window (e.g. 1900±tol) failed by decades. Post-fix, all
/// three share the death-axis logic — record year vs birth year →
/// ageAtDeath in plausible-lifespan band [15, 100], with recorded age
/// cross-checked when present.
///
/// Fixtures are neutral: a fictional John Smith born 1900, died 1980,
/// Derbyshire address (county hardcoded in the geography gate as a
/// passing region).
struct RecordScorerProbateTests {

    // MARK: - Helpers

    private func neutralSubject(
        deathLocation: String? = nil,
        deathYear: Int? = nil
    ) -> ResearchSubject {
        ResearchSubject(
            surname: "Smith",
            givenName: "John",
            middleName: nil,
            birthYearFrom: 1900,
            birthYearTo: 1900,
            deathYearFrom: deathYear,
            deathYearTo: deathYear,
            gender: .male,
            region: .englandAndWales,
            deathLocation: deathLocation,
            mode: .extend
        )
    }

    private func probateRecord(
        name: String = "John Smith",
        surname: String = "Smith",
        given: String = "John",
        deathYear: Int? = 1980,
        ageAtDeath: Int? = 80,
        address: String? = "Derbyshire",
        registry: String? = nil
    ) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(
                id: "probate-\(deathYear ?? 0)",
                sourceID: "probate",
                name: name,
                surname: surname,
                givenName: given,
                detailURL: nil,
                rawFields: [:]
            ),
            deathDate: nil,
            deathYear: deathYear,
            probateDate: nil,
            birthDate: nil,
            ageAtDeath: ageAtDeath,
            address: address,
            grantType: "PROBATE",
            registry: registry,
            probateNumber: nil,
            regimentNumber: nil
        ))
    }

    private func burialRecord(
        name: String = "John Smith",
        surname: String = "Smith",
        given: String = "John",
        deathYear: Int? = 1980,
        location: String? = "Derbyshire"
    ) -> SourceRecord {
        .burial(BurialRecord(
            common: RecordCommon(
                id: "burial-\(deathYear ?? 0)",
                sourceID: "findagrave",
                name: name,
                surname: surname,
                givenName: given,
                detailURL: nil,
                rawFields: [:]
            ),
            deathDate: nil,
            deathYear: deathYear,
            birthDate: nil,
            birthYear: nil,
            birthPlace: nil,
            deathPlace: nil,
            burialLocation: location,
            cemetery: nil,
            memorialID: nil,
            inscription: nil,
            bio: nil,
            isVeteran: false
        ))
    }

    // MARK: - Tests

    @Test func probateRecordPromotesOnDeathAxisMatch() {
        // 1900-born subject + probate showing ageAtDeath=80 + Derbyshire
        // address → .fact. Pre-fix this record was marked .impossible
        // because the default branch compared the 1980 record year against
        // the 1900±tol birth window and failed by ~80 years.
        let result = RecordScorer.classify(
            record: probateRecord(),
            subject: neutralSubject(),
            searchType: .probate
        )
        #expect(result.verdict == .fact)
    }

    @Test func probateRecordWithWrongNameStaysImpossible() {
        // Name gate must still reject obvious wrong-persons. Regression
        // check that the death-axis branch hasn't relaxed the name gate.
        let result = RecordScorer.classify(
            record: probateRecord(
                name: "Mary Jones",
                surname: "Jones",
                given: "Mary"
            ),
            subject: neutralSubject(),
            searchType: .probate
        )
        #expect(result.verdict == .impossible)
    }

    @Test func probateWithContradictoryAgeAtDeathFailsDateGate() {
        // Recorded ageAtDeath must be consistent with (deathYear - birthYear).
        // 1900-born, deathYear=1980 implies ageAtDeath ~80; a record claiming
        // ageAtDeath=30 is internally contradictory → date gate `.fail`,
        // verdict drops below `.fact`. (When no recorded age is present the
        // gate falls back to the [15, 100] plausibility band; with a
        // recorded age it's the consistency check that matters.)
        let result = RecordScorer.classify(
            record: probateRecord(deathYear: 1980, ageAtDeath: 30),
            subject: neutralSubject(),
            searchType: .probate
        )
        #expect(result.verdict != .fact)
    }

    @Test func probateWithoutAddressPassesWhenSubjectDeathLocationIsUK() {
        // The deathLocation plumbing (Profile.deathLocation →
        // ResearchSubject.deathLocation) lets the geography gate pass on
        // subject-side context when the record has no address — the case
        // for post-1996 UK probate grants where Nuxeo omits estate address.
        // Subject's known UK death location compensates.
        let result = RecordScorer.classify(
            record: probateRecord(address: nil),
            subject: neutralSubject(deathLocation: "Chesterfield, Derbyshire, England"),
            searchType: .probate
        )
        #expect(result.verdict == .fact)
    }

    @Test func probateWithoutAddressOrSubjectDeathLocationStaysLead() {
        // Without subject-side context (deathLocation nil) the gate must
        // soft-fail rather than blanket-passing — otherwise a coincidental
        // name+year match anywhere in the UK would auto-promote a wrong
        // person's probate to `.fact`. Verdict downgrades to `.lead`.
        let result = RecordScorer.classify(
            record: probateRecord(address: nil),
            subject: neutralSubject(deathLocation: nil),
            searchType: .probate
        )
        #expect(result.verdict == .lead)
    }

    @Test func probateWithoutAddressFailsWhenSubjectDiedAbroad() {
        // The leniency on missing record address only fires when subject's
        // death location overlaps the source's coverage region (UK for
        // Probate Calendar). A subject who died abroad shouldn't auto-promote
        // on a UK probate match — falls through to softFail → lead.
        let result = RecordScorer.classify(
            record: probateRecord(address: nil),
            subject: neutralSubject(deathLocation: "Sydney, Australia"),
            searchType: .probate
        )
        #expect(result.verdict == .lead)
    }

    @Test func probateWithoutAddressPassesWhenRegistryCoversSubject() {
        // Registry-based catchment match. Manchester District Probate
        // Registry covers Derbyshire (among others); a Manchester-filed
        // probate for a Derbyshire-home subject passes geography even
        // without an estate address. This is the record-side
        // counterpart to the subject-side deathLocation check, and is
        // more specific (it uses data on the record, not assumptions).
        let result = RecordScorer.classify(
            record: probateRecord(address: nil, registry: "Manchester"),
            subject: neutralSubject(deathLocation: nil),
            searchType: .probate
        )
        #expect(result.verdict == .fact)
    }

    @Test func probateWithoutAddressFailsWhenRegistryMismatch() {
        // Bristol registry covers SW England (SOM/GLS/DEV/etc.), not
        // Derbyshire. A Bristol-filed probate for a Derbyshire-home
        // subject is suspicious — likely a different person of the
        // same name from the SW. Soft-fail → lead, not fact, even
        // though we have a record-side signal.
        let result = RecordScorer.classify(
            record: probateRecord(address: nil, registry: "Bristol"),
            subject: neutralSubject(deathLocation: nil),
            searchType: .probate
        )
        #expect(result.verdict == .lead)
    }

    @Test func probateWithUnknownRegistryFallsThroughToDeathLocation() {
        // When the registry isn't in our catchment table, fall through
        // to the existing subject-deathLocation check. This preserves
        // backward-compatible behaviour for the Probate Calendar's
        // long-tail of pre-reorganisation registries.
        let result = RecordScorer.classify(
            record: probateRecord(address: nil, registry: "Truro"),
            subject: neutralSubject(deathLocation: "Chesterfield, Derbyshire, England"),
            searchType: .probate
        )
        #expect(result.verdict == .fact)
    }

    @Test func burialRecordFailsWhenSubjectHasDifferentKnownDeathYear() {
        // The Ernest-Sr false positive: subject known to have died 1980,
        // a burial record showing a 1959 death (~21 years off) shouldn't
        // promote even though ageAtDeath=59 against birth 1900 is
        // plausible. The new death-year-vs-recordYear check rejects.
        let result = RecordScorer.classify(
            record: burialRecord(deathYear: 1959, location: "Derbyshire"),
            subject: neutralSubject(deathYear: 1980),
            searchType: .burial
        )
        // Verdict drops below fact (date gate fails).
        #expect(result.verdict != .fact)
    }

    @Test func burialRecordPassesWhenSubjectsKnownDeathYearMatches() {
        // Regression: subject's known death year matches the record's,
        // so the new check passes; existing ageAtDeath plausibility
        // still applies and verdict reaches .fact.
        let result = RecordScorer.classify(
            record: burialRecord(deathYear: 1980, location: "Derbyshire"),
            subject: neutralSubject(deathYear: 1980),
            searchType: .burial
        )
        #expect(result.verdict == .fact)
    }

    @Test func burialRecordPassesWithinTolerance() {
        // Tolerance of ±2 years accommodates minor date variance
        // (probate filed in the year following death, parish-register
        // burial dated days after secular death certificate, etc.).
        let result = RecordScorer.classify(
            record: burialRecord(deathYear: 1981, location: "Derbyshire"),
            subject: neutralSubject(deathYear: 1980),
            searchType: .burial
        )
        #expect(result.verdict == .fact)
    }

    @Test func burialRecordWhenSubjectDeathYearUnknownFallsBackToAgePlausibility() {
        // When subject's death year isn't known, the new check is
        // skipped and we fall back to the existing ageAtDeath
        // plausibility gate. Preserves the original burial promotion
        // path for subjects still being researched.
        let result = RecordScorer.classify(
            record: burialRecord(deathYear: 1980, location: "Derbyshire"),
            subject: neutralSubject(deathYear: nil),
            searchType: .burial
        )
        #expect(result.verdict == .fact)
    }

    @Test func burialRecordPromotesOnDeathAxisMatch() {
        // Burial parity — the same shared branch covers .burial. Name
        // match + Derbyshire location + plausible death year → .fact.
        // Pre-fix, burial records were falling through to the default
        // birth-window branch too.
        let result = RecordScorer.classify(
            record: burialRecord(),
            subject: neutralSubject(),
            searchType: .burial
        )
        #expect(result.verdict == .fact)
    }
}
