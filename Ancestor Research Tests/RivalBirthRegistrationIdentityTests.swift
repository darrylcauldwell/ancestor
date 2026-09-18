import Testing
import Foundation
@testable import AncestorKit

/// EV1-14 follow-up (review M3) — `RivalBirthRegistrationsRule` used to
/// identify a registration by volume/page alone, contradicting the
/// registration-identity rule the same series established in
/// `RecordScorer.isSameRegistration`: FreeBMD volume/page numbering restarts
/// every quarter, so identity is quarter + district + volume + page. Two
/// different quarters (or districts) sharing a page number are two different
/// babies and must RIVAL; a citation that omits a discriminator is never
/// split off for the omission.
struct RivalBirthRegistrationIdentityTests {

    private func registration(_ value: String, district: String = "Belper",
                              vol: String, page: String) -> FieldSource {
        FieldSource(
            origin: .freebmd, raw: value, addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                title: "Birth: Emma Gladwin, \(value), \(district)",
                url: "https://www.freebmd.org.uk/cgi/\(vol)-\(page)",
                notes: "\"England & Wales, Civil Registration Birth Index,\" "
                    + "FreeBMD (https://www.freebmd.org.uk), Emma Gladwin, \(value), "
                    + "\(district), vol. \(vol)/\(page); accessed 21 Jul 2026."))
    }

    private func emma(_ sources: [FieldSource]) -> Profile {
        Profile(
            id: "@P1@", firstName: "Emma", lastName: "Gladwin", gender: .female,
            birthDate: GenealogicalDate(parsing: "Dec 1867"),
            birthLocation: "Belper, Derbyshire",
            isDeleted: false,
            sources: [.birthDate: sources], disputes: [:])
    }

    private func snapshot(_ profile: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
    }

    // MARK: - Rivals the vol/page-only identity missed

    /// Page numbering restarts every quarter, so a cross-quarter page
    /// collision within one district is two different babies — exactly the
    /// two-mutually-exclusive-registrations condition the rule was written
    /// to catch.
    @Test func crossQuarterEntriesSharingAVolPageAreRivals() {
        let profile = emma([
            registration("Dec 1865", district: "Chesterfield", vol: "7b", page: "513"),
            registration("Jun 1868", district: "Chesterfield", vol: "7b", page: "513"),
        ])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 2)

        let results = RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile))
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    /// Two districts can each use vol/page 7b/513 in the same quarter —
    /// different registration districts means different registrations.
    @Test func differentDistrictsSharingAVolPageAreRivals() {
        let profile = emma([
            registration("Dec 1867", district: "Belper", vol: "7b", page: "513"),
            registration("Dec 1867", district: "Chesterfield", vol: "7b", page: "513"),
        ])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 2)
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).count == 1)
    }

    /// The formatted-citation shape ("<district> registration district,
    /// <month> quarter <year>, volume …, page …") is read too.
    @Test func registrationDistrictProseShapeIsDiscriminated() {
        let belper = FieldSource(
            origin: .manual, raw: "Mar 1834", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                notes: "FreeBMD, Birth Index, Belper registration district, "
                    + "March quarter 1834, volume 7b, page 213."))
        let bakewell = FieldSource(
            origin: .manual, raw: "Mar 1834", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                notes: "FreeBMD, Birth Index, Bakewell registration district, "
                    + "March quarter 1834, volume 7b, page 213."))
        let profile = emma([belper, bakewell])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 2)
    }

    // MARK: - Omission tolerance (never split for what a citation lacks)

    /// A hand-entered citation carrying only the year and vol/page joins its
    /// fully-described twin — it cannot be told apart on a discriminator it
    /// omits (mirror of `isSameRegistration`'s quarter handling).
    @Test func aCitationOmittingQuarterAndDistrictJoinsItsVolPageTwin() {
        let typed = FieldSource(
            origin: .manual, raw: "1867", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                collection: "FreeBMD Birth Index", page: "Volume 7b, page 513"))
        let profile = emma([registration("Dec 1867", vol: "7b", page: "513"), typed])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 1)
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    /// Notational variants of one quarter stay one registration
    /// (the original pin, kept beside the new identity).
    @Test func sameQuarterNotationVariantsStayOneRegistration() {
        let profile = emma([
            registration("Dec 1867", vol: "7b", page: "513"),
            registration("Q4 1867", vol: "7B", page: "513"),
        ])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 1)
    }

    /// A quarterless first sighting adopts a twin's quarter, and a LATER
    /// conflicting entry is judged against that enriched identity — not
    /// against the omission.
    @Test func laterConflictIsJudgedAgainstTheEnrichedIdentity() {
        let profile = emma([
            registration("1867", vol: "7b", page: "513"),        // year only
            registration("Mar 1867", vol: "7b", page: "513"),    // fills quarter Q1
            registration("Jun 1867", vol: "7b", page: "513"),    // Q2 — a different baby
        ])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 2)
    }
}
