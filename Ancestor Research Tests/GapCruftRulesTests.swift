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

    // MARK: - "Not a duplicate" dismissals (v51)

    /// A snapshot with a set of dismissed pairs — mirrors what the project
    /// loader (`buildSnapshot`) hands the rule after the user marks a pair
    /// "not a duplicate".
    private func snapshot(
        dismissing dismissed: Set<DuplicatePairKey>,
        _ profiles: Profile...
    ) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: [],
            dismissedDuplicatePairs: dismissed)
    }

    @Test func dismissedPairStaysGoneAfterReAudit() {
        // The Glays/Gladys pair fires normally...
        let a = profile(id: "a", first: "Glays", last: "Cauldwell")
        let b = profile(id: "b", first: "Gladys", last: "Cauldwell")
        #expect(!DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)

        // ...but once the user marks them "not a duplicate", re-auditing the
        // same profiles emits nothing — the verdict survives the re-run.
        let dismissed = snapshot(dismissing: [DuplicatePairKey("a", "b")], a, b)
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: dismissed).isEmpty)
    }

    @Test func dismissalIsPairSpecificNotRuleWide() {
        // Dismissing one pair must not silence a DIFFERENT genuine duplicate —
        // the whole point of per-pair suppression over snoozing the rule.
        let a = profile(id: "a", first: "Glays", last: "Cauldwell")
        let b = profile(id: "b", first: "Gladys", last: "Cauldwell")
        let c = profile(id: "c", first: "Mabel", last: "Wheeldon")
        let d = profile(id: "d", first: "Mabel", last: "Wheeldon")

        let snap = snapshot(dismissing: [DuplicatePairKey("a", "b")], a, b, c, d)
        // a↔b suppressed…
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snap).isEmpty)
        // …c↔d still flagged.
        #expect(!DuplicateDetectionRule().evaluate(profile: c, snapshot: snap).isEmpty)
    }

    @Test func dismissalIsOrderInsensitive() {
        // The rule reports a pair from the alphabetically-first profile, so the
        // dismissal key must match whichever order it was recorded in.
        let a = profile(id: "a", first: "Glays", last: "Cauldwell")
        let b = profile(id: "b", first: "Gladys", last: "Cauldwell")
        // Recorded as (b, a) — canonicalises to (a, b) and still suppresses.
        let snap = snapshot(dismissing: [DuplicatePairKey("b", "a")], a, b)
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snap).isEmpty)
    }

    @Test func duplicatePairKeyCanonicalisesBothOrderings() {
        #expect(DuplicatePairKey("b", "a") == DuplicatePairKey("a", "b"))
        #expect(DuplicatePairKey("b", "a").hashValue == DuplicatePairKey("a", "b").hashValue)
        let key = DuplicatePairKey("z", "a")
        #expect(key.a == "a" && key.b == "z")
    }

    // MARK: - Structural / date suppression (generational namesake chains)

    private func parentEdge(parent: String, child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent,
                     role: .father, subtype: .biological,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    @Test func duplicateSuppressedWhenLinkedAsParentAndChild() {
        // Same-named father & son in a naming chain: George Keyworth b.1838 and
        // his son George b.1877, with a real parent→child edge. The detector
        // must not propose a merge the safety layer would block anyway.
        let father = profile(id: "g1838", first: "George", last: "Keyworth", birth: "1838")
        let son = profile(id: "g1877", first: "George", last: "Keyworth", birth: "1877")
        let snap = FamilyGraphSnapshot(
            profiles: ["g1838": father, "g1877": son],
            relationships: [parentEdge(parent: "g1838", child: "g1877")])
        #expect(DuplicateDetectionRule().evaluate(profile: father, snapshot: snap).isEmpty)
    }

    @Test func duplicateSuppressedWhenBirthYearsAGenerationApart() {
        // Exact same name, no edge between them, but born 27 years apart —
        // beyond the same-person band. Previously pinned at exactly 0.70 and
        // fired; now positively distinguished.
        let a = profile(id: "g1877", first: "George", last: "Keyworth", birth: "1877")
        let b = profile(id: "g1904", first: "George", last: "Keyworth", birth: "1904")
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }

    @Test func duplicateStillFiresWhenBirthYearsClose() {
        // Regression guard: a genuine duplicate recorded with fuzzy dates (a
        // couple of years apart, no overlap) must STILL surface — the gap
        // ceiling is generous precisely so we don't drop these.
        let a = profile(id: "a", first: "George", last: "Keyworth", birth: "1877")
        let b = profile(id: "b", first: "George", last: "Keyworth", birth: "1879")
        #expect(!DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }

    @Test func duplicateStillFiresForExactNameWhenBothDateless() {
        // Two dateless exact-name stubs are the classic import duplicate — no
        // date gap to judge, so they must still surface for review.
        let a = profile(id: "a", first: "George", last: "Cauldwell")
        let b = profile(id: "b", first: "George", last: "Cauldwell")
        #expect(!DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot(a, b)).isEmpty)
    }

    // MARK: - InvalidDateRule

    @Test func invalidDateFiresWhenNoYearReadable() {
        let p = profile(first: "Test", last: "Person", birth: "nineteenth century")
        let r = InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p))
        #expect(r.count == 1)
        #expect(r.first?.severity == .warning)
    }

    @Test func invalidDateFiresOnUnrecognisedMonthOrDay() {
        // The year (1987) reads fine, but "Julie"/"Seventeenth" were dropped —
        // the wider coverage this rule is meant to catch.
        let p = profile(first: "Test", last: "Person", birth: "Seventeenth of Julie 1987")
        #expect(!InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func invalidDateFiresOnFutureYear() {
        let p = profile(first: "Test", last: "Person", birth: "2099")
        #expect(!InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func invalidDateSilentOnCleanFullDate() {
        for good in ["21 Jul 1916", "18 July 2006", "1 January 1900", "29 Feb 1904"] {
            let p = profile(first: "Test", last: "Person", birth: good)
            #expect(InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty, "“\(good)” should be clean")
        }
    }

    @Test func invalidDateFiresOnImpossibleDay() {
        for bad in ["31 Feb 1900", "45 Jul 2006", "0 Jan 1900"] {
            let p = profile(first: "Test", last: "Person", birth: bad)
            #expect(!InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty, "“\(bad)” should flag")
        }
    }

    @Test func invalidDateSilentOnValidYear() {
        let p = profile(first: "Test", last: "Person", birth: "1887")
        #expect(InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func invalidDateSilentOnQualifiedYear() {
        let p = profile(first: "Test", last: "Person", birth: "ABT 1880")
        #expect(InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    @Test func invalidDateSilentWhenNoDate() {
        let p = profile(first: "Test", last: "Person")
        #expect(InvalidDateRule().evaluate(profile: p, snapshot: snapshot(p)).isEmpty)
    }

    // MARK: - GuidedDateField canonical output

    @Test func guidedDateCanonicalFormsAllParse() {
        // Every string the guided picker emits must read back as a year — else
        // it would trip UnparseableDateRule the moment it's entered.
        for s in ["21 Jul 1916", "Jul 1916", "1916", "abt 1880", "bef 1890", "aft 1890", "1865-1867"] {
            #expect(GenealogicalDate(parsing: s).bestYear != nil, "“\(s)” should read as a year")
        }
    }
}
