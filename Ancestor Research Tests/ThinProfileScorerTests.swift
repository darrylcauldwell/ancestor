import Testing
import Foundation
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC #Change1 — verdict-cap behaviour for thin
/// subjects, plus the `InformationDensity` classifier.
///
/// The empirical motivator: a surname-only HOLMES placeholder with a
/// 30-year birth-year window produced ~3,000 records landing `.fact`
/// in the cross-day Discovery run. After this change, the same
/// records can pass all gates but are capped at `.lead` — the scorer
/// refuses to assert truth when it can't meaningfully discriminate.
struct ThinProfileScorerTests {

    // MARK: - InformationDensity classifier

    @Test func densityRichWhenSubjectHasGivenAndNarrowBirthWindow() {
        let subject = ernestCauldwell()
        #expect(InformationDensity.from(subject: subject) == .rich)
    }

    @Test func densityThinWhenGivenNameNil() {
        let subject = surnameOnlyHolmes()
        #expect(InformationDensity.from(subject: subject) == .thin)
    }

    @Test func densityThinWhenGivenNameEmptyString() {
        var subject = ernestCauldwell()
        subject.givenName = ""
        #expect(InformationDensity.from(subject: subject) == .thin)
    }

    @Test func densityThinWhenGivenNameWhitespace() {
        var subject = ernestCauldwell()
        subject.givenName = "   "
        #expect(InformationDensity.from(subject: subject) == .thin)
    }

    @Test func densityThinWhenBirthWindowWide() {
        // Given name present, but window > 25 years — the parent-from-
        // oldest-child fallback case. Still thin.
        let subject = wideBirthWindowSubject()
        #expect(InformationDensity.from(subject: subject) == .thin)
    }

    @Test func densityRichWhenBirthWindowExactly25Years() {
        // Boundary: 25-year window is the *threshold*; > 25 is thin.
        var subject = ernestCauldwell()
        subject.birthYearFrom = 1880
        subject.birthYearTo = 1905
        #expect(InformationDensity.from(subject: subject) == .rich)
    }

    @Test func densityRichWhenBirthYearMissingButGivenPresent() {
        // No birth-year info but given name present — only the secondary
        // signal flags thinness, and we can't compute window width here.
        var subject = ernestCauldwell()
        subject.birthYearFrom = nil
        subject.birthYearTo = nil
        #expect(InformationDensity.from(subject: subject) == .rich)
    }

    // MARK: - Verdict cap on the scorer

    @Test func thinSubjectFactRecordCapsToLead() {
        // Surname-only HOLMES, parent-inferred 30-year birth window.
        // The record passes all gates (name passes by default since
        // subject has no given name, date passes since 1940 is in
        // [1925..1957], geography passes for any Belper district).
        // Before #Change1 → .fact. After → .lead.
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Holmes", givenName: "Jennifer", year: 1940),
            subject: surnameOnlyHolmes(),
            searchType: .birth
        )
        #expect(result.verdict == .lead,
                "Thin subject must cap at .lead, never .fact — got \(result.verdict)")
    }

    @Test func thinSubjectStillRejectsImpossibleRecords() {
        // Hard fail (death year well before subject's earliest birth
        // year) must still emit .impossible — the cap only modifies
        // .fact, not .impossible. Subject earliest birth = 1926;
        // death in 1900 is 26 years before, far past the date-gate
        // 5-year tolerance.
        let result = RecordScorer.classify(
            record: deathRecord(
                surname: "Holmes", givenName: "Jennifer",
                year: 1900
            ),
            subject: surnameOnlyHolmes(),
            searchType: .death
        )
        #expect(result.verdict == .impossible,
                "Pre-birth death must remain .impossible regardless of subject density — got \(result.verdict)")
    }

    @Test func thinSubjectLeadRecordStillLead() {
        // A record that already lands .lead (soft-fail on geography
        // e.g., unknown district) stays .lead — cap doesn't affect it.
        let result = RecordScorer.classify(
            record: birthRecord(
                surname: "Holmes", givenName: "Jennifer",
                year: 1940, district: "SomeUnknownDistrict"
            ),
            subject: surnameOnlyHolmes(),
            searchType: .birth
        )
        #expect(result.verdict == .lead)
    }

    // MARK: - No regression on rich subjects

    @Test func richSubjectFactStaysFact() {
        // Ernest Cauldwell, rich subject. Birth record matches name +
        // date + Belper geography → all gates pass → .fact. Density is
        // .rich → cap does not fire.
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Cauldwell", givenName: "Ernest", year: 1887),
            subject: ernestCauldwell(),
            searchType: .birth
        )
        #expect(result.verdict == .fact,
                "Rich subject must still emit .fact for fully-passing records — got \(result.verdict)")
    }

    @Test func wideBirthWindowSubjectFactCapsToLead() {
        // Subject has a given name (so name gate is operative) but the
        // window is 32 years — secondary thin signal fires. The .fact
        // verdict must cap to .lead.
        let result = RecordScorer.classify(
            record: birthRecord(surname: "Cauldwell", givenName: "Henry", year: 1850),
            subject: wideBirthWindowSubject(),
            searchType: .birth
        )
        #expect(result.verdict == .lead,
                "Wide-window subject must cap .fact at .lead — got \(result.verdict)")
    }

    // MARK: - Fixtures

    private func surnameOnlyHolmes() -> ResearchSubject {
        // The empirical bug case: Darryl's mother promoted as a
        // surname-only @FR_*HOLMES@ placeholder with a 30-year birth
        // window estimated from her child's birth.
        ResearchSubject(
            surname: "Holmes",
            givenName: nil,
            birthYearFrom: 1926,
            birthYearTo: 1956,
            gender: .female,
            region: .englandAndWales,
            mode: .discover
        )
    }

    private func ernestCauldwell() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Ernest",
            birthYearFrom: 1886,
            birthYearTo: 1888,
            gender: .male,
            region: .englandAndWales,
            mode: .extend
        )
    }

    private func wideBirthWindowSubject() -> ResearchSubject {
        // Given name present, but a 32-year window — thin via the
        // secondary signal.
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Henry",
            birthYearFrom: 1830,
            birthYearTo: 1862,
            gender: .male,
            region: .englandAndWales,
            mode: .discover
        )
    }

    private func commonFields(_ id: String, surname: String, givenName: String) -> RecordCommon {
        RecordCommon(
            id: id,
            sourceID: "freebmd",
            name: nil,
            surname: surname,
            givenName: givenName,
            detailURL: nil,
            rawFields: [:]
        )
    }

    private func birthRecord(
        surname: String,
        givenName: String,
        year: Int,
        district: String = "Belper"
    ) -> SourceRecord {
        .birth(BirthRecord(
            common: commonFields("rec-birth-\(surname)-\(givenName)-\(year)",
                                 surname: surname, givenName: givenName),
            birthYear: year,
            birthDate: nil,
            birthPlace: nil,
            quarter: "Mar",
            district: district,
            volume: "19",
            page: "438",
            mothersMaidenName: nil
        ))
    }

    private func deathRecord(
        surname: String,
        givenName: String,
        year: Int,
        district: String = "Belper"
    ) -> SourceRecord {
        .death(DeathRecord(
            common: commonFields("rec-death-\(surname)-\(givenName)-\(year)",
                                 surname: surname, givenName: givenName),
            deathYear: year,
            deathDate: nil,
            deathPlace: nil,
            age: 50,
            quarter: "Mar",
            district: district,
            volume: "7b",
            page: "412",
            spouseSurname: nil
        ))
    }
}
