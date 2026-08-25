import Testing
import Foundation
@testable import AncestorKit

/// Owner dogfood 2026-08-25 — Emma Gladwin's confirmed facts carried BOTH
/// "Dec 1867" (FreeBMD 7b/513) and "Dec 1865" (7b/515) as cited birth dates at
/// the same time. `ContradictoryFactsAudit` contests the evidence store and saw
/// nothing, because what the profile actually HOLDS is a different question
/// from what the scorer last decided about the rows behind it.
struct RivalBirthRegistrationsRuleTests {

    private func registration(_ value: String, vol: String, page: String) -> FieldSource {
        FieldSource(
            origin: .freebmd, raw: value, addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                title: "Birth: Emma Gladwin, \(value), Belper",
                url: "https://www.freebmd.org.uk/cgi/\(vol)-\(page)",
                notes: "\"England & Wales, Civil Registration Birth Index, 1867,\" "
                    + "FreeBMD (https://www.freebmd.org.uk), Emma Gladwin, \(value), "
                    + "Belper, vol. \(vol)/\(page); accessed 21 Jul 2026."))
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

    // MARK: - The specimen

    @Test func twoCitedRegistrationsWithDifferentVolPageAreFlagged() {
        let profile = emma([
            registration("Dec 1867", vol: "7b", page: "513"),
            registration("Dec 1865", vol: "7b", page: "515"),
        ])
        let results = RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile))

        #expect(results.count == 1)
        #expect(results.first?.ruleID == "rivalBirthRegistrations")
        #expect(results.first?.severity == .error)
        #expect(results.first?.category == .issue,
                ".gap would file 'the tree is wrong' under 'half-applied evidence'")
        #expect(results.first?.message.contains("7b/513") == true)
        #expect(results.first?.message.contains("7b/515") == true)
    }

    @Test func theRuleRunsInTheAuditEngine() {
        #expect(AuditRules.builtIn.contains { $0.id == "rivalBirthRegistrations" })
    }

    // MARK: - What must NOT fire

    @Test func indexTwinsOfOneRegistrationAreNotRivals() {
        // The same GRO registration is indexed under several row ids; two
        // citations of 7b/513 are one birth, not two.
        let profile = emma([
            registration("Dec 1867", vol: "7b", page: "513"),
            registration("Q4 1867", vol: "7B", page: "513"),
        ])
        #expect(RivalBirthRegistrationsRule.registrations(for: profile).count == 1)
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    @Test func aBaptismCitationIsNotABirthRegistration() {
        // Parish baptisms carry no volume/page at all — a registration and a
        // baptism are corroboration, never rivals.
        let baptism = FieldSource(
            origin: .freebmd, raw: "1868", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                collection: "FreeREG Baptism Register",
                title: "Baptism: Emma Gladwin, 1868, Wirksworth St Mary",
                notes: "Derbyshire, Wirksworth, baptism of Emma Gladwin, 12 Jan 1868."))
        let profile = emma([registration("Dec 1867", vol: "7b", page: "513"), baptism])
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    @Test func aDeathIndexReferenceOnTheBirthDateIsNotARival() {
        // An age-at-death backfill puts a birth year on the profile citing the
        // DEATH registration. Its vol/page identifies a death, so it can never
        // rival a birth registration.
        let fromDeath = FieldSource(
            origin: .freebmd, raw: "CAL 1866", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                title: "Death: Emma Gladwin, Mar 1943, Belper",
                notes: "\"England & Wales, Civil Registration Death Index, 1943,\" "
                    + "FreeBMD, Emma Gladwin, age 76, Belper, vol. 7b/901."))
        let profile = emma([registration("Dec 1867", vol: "7b", page: "513"), fromDeath])
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    @Test func oneRegistrationIsNoFinding() {
        let profile = emma([registration("Dec 1867", vol: "7b", page: "513")])
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    @Test func anUncitedBirthDateIsNoFinding() {
        let bare = FieldSource(origin: .gedcom, raw: "1867",
                               addedAt: Date(timeIntervalSince1970: 0))
        let profile = emma([bare, bare])
        #expect(RivalBirthRegistrationsRule()
            .evaluate(profile: profile, snapshot: snapshot(profile)).isEmpty)
    }

    // MARK: - Reference parsing

    @Test func handEnteredVolumeAndPageAreRead() {
        let typed = FieldSource(
            origin: .manual, raw: "Dec 1865", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(
                collection: "FreeBMD Birth Index", page: "Volume 7b, page 515"))
        let profile = emma([registration("Dec 1867", vol: "7b", page: "513"), typed])
        let refs = RivalBirthRegistrationsRule.registrations(for: profile).map(\.reference)
        #expect(refs == ["7b/513", "7b/515"])
    }

    @Test func aCitationWithNoReferenceIsIgnored() {
        let vague = FieldSource(
            origin: .freebmd, raw: "1865", addedAt: Date(timeIntervalSince1970: 0),
            citation: Citation(title: "Birth: Emma Gladwin, Dec 1865, Belper"))
        #expect(RivalBirthRegistrationsRule.birthRegistrationReference(vague) == nil)
    }
}
