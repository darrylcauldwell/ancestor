import Testing
import Foundation
@testable import Ancestor_Research

/// Two owner-requested refinements (2026-07-22):
///
/// - **DS-23** — the birth date gate's tolerance is restored to ±2 (was ±1),
///   covering the compound registration-quarter-slip + census-age-rounding
///   case Python deliberately tolerated.
/// - **Spouse-birth inference** ("Ethel-class") — a married profile with no
///   birth date gets a research window from a spouse's birth year ± 5, so a
///   common-named, DOB-less spouse is no longer unresearchable. The profile's
///   own DOB always takes precedence; the window is search-only, never
///   written back.
@MainActor
struct SpouseBirthInferenceTests {

    // MARK: - DS-23: birth tolerance ±2

    @Test func birthRecordTwoYearsOffPasses() {
        // Subject born 1845 (span-0). A 1847 birth record (2 years off) now
        // passes the date gate; at ±1 it failed to a lead.
        let result = RecordScorer.classify(
            record: birthRecord(year: 1847),
            subject: pointBirthSubject(1845),
            searchType: .birth
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome == .pass,
                "a 2-year-off birth must pass at ±2 — got \(String(describing: result.gates.first { $0.gate == .date }?.outcome))")
    }

    @Test func birthRecordThreeYearsOffStillFails() {
        let result = RecordScorer.classify(
            record: birthRecord(year: 1848),
            subject: pointBirthSubject(1845),
            searchType: .birth
        )
        #expect(result.gates.first { $0.gate == .date }?.outcome == .fail)
    }

    // MARK: - Spouse-birth inference

    @Test func dobLessProfileInheritsSpouseWindow() {
        let ethel = profile(id: "ethel", given: "Ethel", surname: "Smith", birthYear: nil)
        let spouse = profile(id: "spouse", given: "Albert", surname: "Smith",
                             gender: .male, birthYear: 1850)
        let subject = ResearchSubject.fromProfile(ethel, snapshot: married(ethel, spouse))
        #expect(subject.birthYearFrom == 1845, "spouse 1850 − 5")
        #expect(subject.birthYearTo == 1855, "spouse 1850 + 5")
    }

    @Test func ownDobTakesPrecedenceOverSpouse() {
        let ethel = profile(id: "ethel", given: "Ethel", surname: "Smith", birthYear: 1900)
        let spouse = profile(id: "spouse", given: "Albert", surname: "Smith",
                             gender: .male, birthYear: 1850)
        let subject = ResearchSubject.fromProfile(ethel, snapshot: married(ethel, spouse))
        #expect(subject.birthYearFrom == 1900 && subject.birthYearTo == 1900,
                "the profile's own DOB must win over the spouse estimate")
    }

    @Test func noSpouseBirthYearFallsThrough() {
        // Spouse also DOB-less, no children → no window (unresearchable, as before).
        let ethel = profile(id: "ethel", given: "Ethel", surname: "Smith", birthYear: nil)
        let spouse = profile(id: "spouse", given: "Albert", surname: "Smith",
                             gender: .male, birthYear: nil)
        let subject = ResearchSubject.fromProfile(ethel, snapshot: married(ethel, spouse))
        #expect(subject.birthYearFrom == nil && subject.birthYearTo == nil)
    }

    // MARK: - Fixtures

    private func pointBirthSubject(_ year: Int) -> ResearchSubject {
        ResearchSubject(
            surname: "Smith", givenName: "John",
            birthYearFrom: year, birthYearTo: year,
            gender: .male, region: .englandAndWales, mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil)
        )
    }

    private func birthRecord(year: Int) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: "b-\(year)", sourceID: "freebmd", name: nil,
                                 surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:]),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "19", page: "438",
            mothersMaidenName: nil))
    }

    private func profile(id: String, given: String, surname: String,
                         gender: Gender = .female, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: surname,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func married(_ a: Profile, _ b: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: [a.id: a, b.id: b],
            relationships: [Relationship(
                id: UUID(), from: a.id, to: b.id,
                type: .spouse, role: nil, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil)])
    }
}
