import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// The four "gap" cruft rules built from the Tree-2 audit: JunkInNameRule,
/// IncompleteNameRule, SuspectLocationRule, and the strengthened fuzzy
/// DuplicateDetectionRule (insertion/deletion typos + exact-surname/near-given
/// boost). Detection lives on `Profile` so the audit chips and future cleanse
/// fixes share one source of truth.
struct GapCruftRulesTests {

    private func profile(
        id: String = "p1",
        first: String? = nil,
        middle: String? = nil,
        last: String? = nil,
        birth: String? = nil,
        birthLoc: String? = nil,
        deathLoc: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: middle, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLoc,
            deathDate: nil, deathLocation: deathLoc,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func snapshot(_ profiles: Profile...) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: [])
    }

    // MARK: - JunkInNameRule

    @Test func junkFiresOnQuestionMarkSurname() {
        // "Mary Anne ?" — real given name, literal "?" surname, and a death date
        // so EmptyProfileRule won't touch it.
        let p = profile(first: "Mary Anne", last: "?")
        let r = JunkInNameRule().evaluate(profile: p, snapshot: snapshot(p))
        #expect(r.count == 1)
        #expect(r.first?.severity == .warning)
    }

    @Test func junkFiresOnParentheticalNickname() {
        let p = profile(first: "Elizabeth Maud (Betty)", last: "Thompson")
        #expect(!JunkInNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func junkFiresOnPlaceholderWord() {
        let p = profile(first: "Unknown", last: "Andrews")
        #expect(!JunkInNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func junkSilentOnCleanName() {
        let p = profile(first: "Darryl", last: "Cauldwell")
        #expect(JunkInNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func junkResolutionLiftsParentheticalToNickname() {
        let res = profile(first: "Elizabeth Maud (Betty)", last: "Thompson").nameJunkResolution
        #expect(res?.field == .firstName)
        #expect(res?.proposed == "Elizabeth Maud")
        #expect(res?.nickname == "Betty")
    }

    @Test func junkResolutionStripsPlaceholderToEmpty() {
        #expect(profile(first: "Unknown", last: "Andrews").nameJunkResolution?.proposed == "")
    }

    @Test func junkResolutionOnQuestionMarkSurnameClears() {
        let res = profile(first: "Mary Anne", last: "?").nameJunkResolution
        #expect(res?.field == .lastName)
        #expect(res?.proposed == "")
    }

    // MARK: - IncompleteNameRule

    @Test func incompleteFiresOnSurnameOnly() {
        let p = profile(last: "Andrews")
        let r = IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p))
        #expect(r.count == 1)
        #expect(r.first?.message.contains("no given name") == true)
    }

    @Test func incompleteFiresOnGivenOnly() {
        let p = profile(first: "Ada")
        #expect(IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p))
            .first?.message.contains("no surname") == true)
    }

    @Test func incompleteFiresOnInitialOnlyGiven() {
        let p = profile(first: "R", last: "Smith")
        #expect(IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p))
            .first?.message.contains("initial") == true)
    }

    @Test func incompleteSilentOnCompleteName() {
        let p = profile(first: "Darryl", last: "Cauldwell")
        #expect(IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func incompleteDefersFullyEmptyToEmptyProfileRule() {
        // No name at all — IncompleteName stays silent (EmptyProfileRule owns it).
        let p = profile()
        #expect(IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func incompleteDefersJunkToJunkRule() {
        // "?" surname is junk, not "incomplete" — JunkInNameRule owns it.
        let p = profile(first: "Mary", last: "?")
        #expect(IncompleteNameRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    // MARK: - SuspectLocationRule

    @Test func suspectLocationFiresOnQuestionMarks() {
        let p = profile(first: "Sarah", last: "Gilbert", birthLoc: "Wensley????")
        #expect(!SuspectLocationRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func suspectLocationFiresOnAllCaps() {
        let p = profile(first: "Claire", last: "Rose", birthLoc: "CHESTERFIELD")
        #expect(!SuspectLocationRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func suspectLocationFiresOnAllLowercaseAndTrailingComma() {
        let lower = profile(id: "a", first: "Ruth", last: "Wheeldon", birthLoc: "wirksworth")
        let comma = profile(id: "b", first: "Mary", last: "A", birthLoc: "Sharlston,")
        #expect(!SuspectLocationRule().evaluate(profile: lower, snapshot: snapshot(lower)).isEmpty)
        #expect(!SuspectLocationRule().evaluate(profile: comma, snapshot: snapshot(comma)).isEmpty)
    }

    @Test func suspectLocationSilentOnCleanPlace() {
        let p = profile(first: "David", last: "Cauldwell", birthLoc: "Ashbourne, Derbyshire, England")
        #expect(SuspectLocationRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    // MARK: - Registration

    @Test func newRulesAreRegistered() {
        let ids = Set(AuditRules.builtIn.map(\.id))
        #expect(ids.isSuperset(of: ["junkInName", "incompleteName", "suspectLocation"]))
    }

    // MARK: - Strengthened duplicate detection

    @Test func nameSimilarityCreditsInsertionDeletionTypo() {
        // Different-length single-edit typo now scores like a same-length one.
        #expect(nameSimilarity("Glays", "Gladys") == 0.7)
    }

    @Test func duplicateFiresOnTypoNameEvenWithoutDates() {
        // Glays / Gladys Cauldwell, both dateless: exact surname + near-identical
        // given → flagged for review via the strong-name boost.
        let a = profile(id: "a", first: "Glays", last: "Cauldwell")
        let b = profile(id: "b", first: "Gladys", last: "Cauldwell")
        #expect(!DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }

    @Test func duplicateSuppressedWhenBirthYearsConflict() {
        // Same near-name but disjoint birth years → distinct people, no flag.
        let a = profile(id: "a", first: "Glays", last: "Cauldwell", birth: "1850")
        let b = profile(id: "b", first: "Gladys", last: "Cauldwell", birth: "1920")
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }

    @Test func duplicateStillSilentOnDifferentGivenSameSurname() {
        // Regression guard: the boost must NOT fire for genuinely different
        // givens under one surname (siblings).
        let a = profile(id: "a", first: "Dorothy", last: "Keyworth")
        let b = profile(id: "b", first: "Florence", last: "Keyworth")
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }
}
