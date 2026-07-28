import Testing
import Foundation
@testable import Ancestor_Research

struct AuditEngineTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "test",
        firstName: String? = "John",
        lastName: String? = "Smith",
        birthDate: String? = nil,
        deathDate: String? = nil,
        birthLocation: String? = nil,
        bio: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: bio,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    // MARK: - MuddledIdentityRule (patronymic-muddle detector)

    @Test func muddledIdentityFlagsImpossibleBirthSpan() {
        // The Abraham Twyford case: one profile, birth 'BET 1882 AND 1909'
        // (27 years) — two same-named Abrahams merged onto one node.
        let abraham = makeProfile(id: "abr", firstName: "Abraham", lastName: "Twyford",
                                  birthDate: "BET 1882 AND 1909")
        let snapshot = makeSnapshot(profiles: [abraham])
        let results = MuddledIdentityRule().evaluate(profile: abraham, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
        #expect(results.first?.message.contains("27 years") == true)
        #expect(results.first?.message.contains("1882–1909") == true)
    }

    @Test func muddledIdentityFlagsImpossibleDeathSpan() {
        // Two deaths 44 years apart (1936 + 1980) merge into a death range.
        let p = makeProfile(id: "d", firstName: "Abraham", lastName: "Twyford",
                            deathDate: "BET 1936 AND 1980")
        let results = MuddledIdentityRule().evaluate(profile: p, snapshot: makeSnapshot(profiles: [p]))
        #expect(results.count == 1)
        #expect(results.first?.message.lowercased().contains("death") == true)
    }

    @Test func muddledIdentityIgnoresNarrowAndEstimateRanges() {
        // A tight index range (5 years) and an 'ABT' estimate (±5 = 10 years)
        // are normal single-person uncertainty — must not fire.
        let tight = makeProfile(id: "t", birthDate: "BET 1885 AND 1890")
        let estimate = makeProfile(id: "e", birthDate: "ABT 1900")
        let snap = makeSnapshot(profiles: [tight, estimate])
        #expect(MuddledIdentityRule().evaluate(profile: tight, snapshot: snap).isEmpty)
        #expect(MuddledIdentityRule().evaluate(profile: estimate, snapshot: snap).isEmpty)
    }

    @Test func muddledIdentityIsRegisteredBuiltIn() {
        #expect(AuditRules.builtIn.contains { $0.id == "muddledIdentity" })
    }

    /// PROFILE_SOURCES_LEDGER_SPEC Change 5 — the Tasks "Review records"
    /// deep-link keys on these exact rule IDs to open the Sources & Records
    /// ledger. Pin them so a rule rename can't silently drop the deep-link.
    @Test func ledgerReviewDeepLinkRuleIDsExist() {
        #expect(MuddledIdentityRule().id == "muddledIdentity")
        #expect(RecordAfterDeathRule().id == "recordAfterDeath")
        #expect(AuditRules.builtIn.contains { $0.id == "recordAfterDeath" })
    }

    private func makeSnapshot(
        profiles: [Profile],
        relationships: [Relationship] = []
    ) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    private func makePlaceholderParent(id: String) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: nil,
            lastName: nil,
            gender: nil,
            attributes: PersonAttributes(nameStatus: .placeholder, lifeStatus: .normal, privacy: .normal),
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func parentEdge(parent: String, child: String, role: ParentRole = .unspecified) -> Relationship {
        Relationship(
            id: UUID(), from: parent, to: child,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    // MARK: - Excess / Placeholder Parents

    @Test func excessParents_realPlusFourPlaceholders_error() {
        // The Elsie Twyford regression: 2 real parents + 4 blank placeholders.
        let child = makeProfile(id: "child")
        let father = makeProfile(id: "father", firstName: "Abraham", lastName: "Twyford")
        let mother = makeProfile(id: "mother", firstName: "Wilhelmina", lastName: "Wright")
        let ph = (1...4).map { makePlaceholderParent(id: "ph\($0)") }
        let snapshot = makeSnapshot(
            profiles: [child, father, mother] + ph,
            relationships: [
                parentEdge(parent: "father", child: "child", role: .father),
                parentEdge(parent: "mother", child: "child", role: .mother),
            ] + ph.map { parentEdge(parent: $0.id, child: "child") }
        )
        let results = ExcessParentEdgesRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
        // The four placeholders are surfaced for repair; the two named parents are not.
        #expect(Set(results.first?.relatedProfileIDs ?? []) == Set(["ph1", "ph2", "ph3", "ph4"]))
        // Placeholders present → remedy is "remove", not the merge-review wording.
        #expect(results.first?.message.contains("Remove the junk placeholder parents") == true)
    }

    @Test func excessParents_allNamed_noPlaceholders_reviewRemedy() {
        // George-Wheeldon shape: 3 NAMED parents, zero placeholders. Still an
        // error, but the remedy is human review, not "remove placeholders", and
        // no repair targets are surfaced.
        let child = makeProfile(id: "child")
        let p1 = makeProfile(id: "p1", firstName: "Alfred", lastName: "Wheeldon")
        let p2 = makeProfile(id: "p2", firstName: "Mary", lastName: "Wheeldon")
        let p3 = makeProfile(id: "p3", firstName: "Sarah", lastName: "Wheeldon")
        let snapshot = makeSnapshot(
            profiles: [child, p1, p2, p3],
            relationships: [
                parentEdge(parent: "p1", child: "child", role: .father),
                parentEdge(parent: "p2", child: "child", role: .mother),
                parentEdge(parent: "p3", child: "child", role: .mother),
            ]
        )
        let results = ExcessParentEdgesRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
        #expect(results.first?.relatedProfileIDs == nil)
        #expect(results.first?.message.contains("likely a duplicate or bad merge") == true)
        #expect(results.first?.message.contains("blank placeholder") == false)
    }

    @Test func excessParents_lonePlaceholderIsLegitimate_noFire() {
        // Two parentless siblings sharing ONE unknown-couple placeholder — valid.
        let child = makeProfile(id: "child")
        let ph = makePlaceholderParent(id: "ph1")
        let snapshot = makeSnapshot(
            profiles: [child, ph],
            relationships: [parentEdge(parent: "ph1", child: "child")]
        )
        #expect(ExcessParentEdgesRule().evaluate(profile: child, snapshot: snapshot).isEmpty)
    }

    @Test func excessParents_placeholderAlongsideNamed_warning() {
        // One real parent + one stray placeholder (2 total) → warning, not error.
        let child = makeProfile(id: "child")
        let father = makeProfile(id: "father", firstName: "Abraham", lastName: "Twyford")
        let ph = makePlaceholderParent(id: "ph1")
        let snapshot = makeSnapshot(
            profiles: [child, father, ph],
            relationships: [
                parentEdge(parent: "father", child: "child", role: .father),
                parentEdge(parent: "ph1", child: "child"),
            ]
        )
        let results = ExcessParentEdgesRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
        #expect(results.first?.relatedProfileIDs == ["ph1"])
    }

    @Test func excessParents_twoNamedParents_noFire() {
        let child = makeProfile(id: "child")
        let father = makeProfile(id: "father", firstName: "Abraham", lastName: "Twyford")
        let mother = makeProfile(id: "mother", firstName: "Wilhelmina", lastName: "Wright")
        let snapshot = makeSnapshot(
            profiles: [child, father, mother],
            relationships: [
                parentEdge(parent: "father", child: "child", role: .father),
                parentEdge(parent: "mother", child: "child", role: .mother),
            ]
        )
        #expect(ExcessParentEdgesRule().evaluate(profile: child, snapshot: snapshot).isEmpty)
    }

    // MARK: - Empty Profile (orphaned debris)

    @Test func emptyProfile_blankNoRelationships_fires() {
        let empty = makeProfile(id: "empty", firstName: nil, lastName: nil)
        let snapshot = makeSnapshot(profiles: [empty])
        let results = EmptyProfileRule().evaluate(profile: empty, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func emptyProfile_named_noFire() {
        let p = makeProfile(id: "p", firstName: "Jane", lastName: "Doe")
        let snapshot = makeSnapshot(profiles: [p])
        #expect(EmptyProfileRule().evaluate(profile: p, snapshot: snapshot).isEmpty)
    }

    @Test func emptyProfile_blankButHasRelationship_noFire() {
        // A nameless unknown that HOLDS a relationship (e.g. an unknown parent)
        // is a legitimate placeholder, not empty debris.
        let unknown = makeProfile(id: "u", firstName: nil, lastName: nil)
        let child = makeProfile(id: "c")
        let snapshot = makeSnapshot(profiles: [unknown, child],
                                    relationships: [parentEdge(parent: "u", child: "c")])
        #expect(EmptyProfileRule().evaluate(profile: unknown, snapshot: snapshot).isEmpty)
    }

    @Test func emptyProfile_blankButHasDate_noFire() {
        let dated = makeProfile(id: "d", firstName: nil, lastName: nil, birthDate: "1900")
        let snapshot = makeSnapshot(profiles: [dated])
        #expect(EmptyProfileRule().evaluate(profile: dated, snapshot: snapshot).isEmpty)
    }

    @Test func emptyProfile_surnameOnlyOrphan_fires() {
        // The lone " Wheeldon" left after its bad parent-link was removed.
        let stub = makeProfile(id: "wheeldon", firstName: nil, lastName: "Wheeldon")
        let snapshot = makeSnapshot(profiles: [stub])
        let results = EmptyProfileRule().evaluate(profile: stub, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func emptyProfile_surnameOnlyButLinked_noFire() {
        // A surname-only spouse who IS linked is a legit unknown-given placeholder.
        let spouseStub = makeProfile(id: "bown", firstName: nil, lastName: "Bown")
        let husband = makeProfile(id: "h", firstName: "John", lastName: "Smith")
        let snapshot = makeSnapshot(
            profiles: [spouseStub, husband],
            relationships: [Relationship(id: UUID(), from: "bown", to: "h",
                                         type: .spouse, role: nil, subtype: .unknown,
                                         marriageDate: nil, marriageLocation: nil, divorceDate: nil)]
        )
        #expect(EmptyProfileRule().evaluate(profile: spouseStub, snapshot: snapshot).isEmpty)
    }

    // MARK: - Duplicate Detection (given-name guard)

    @Test func duplicate_sameSurnameDifferentGiven_noFire() {
        // Dorothy Winnifred vs Florence May Keyworth — sisters, not duplicates.
        let a = makeProfile(id: "a", firstName: "Dorothy", lastName: "Keyworth", birthDate: "1901")
        let b = makeProfile(id: "b", firstName: "Florence", lastName: "Keyworth", birthDate: "1900")
        let snapshot = makeSnapshot(profiles: [a, b])
        #expect(DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot).isEmpty)
    }

    @Test func duplicate_sameNameOverlappingBirth_fires() {
        let a = makeProfile(id: "a1", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let b = makeProfile(id: "a2", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func duplicate_nicknameVariantStillFires() {
        // Bill / William are the same person — the nickname keeps similarity > 0.
        let a = makeProfile(id: "a1", firstName: "Bill", lastName: "Ward", birthDate: "1910")
        let b = makeProfile(id: "a2", firstName: "William", lastName: "Ward", birthDate: "1910")
        let snapshot = makeSnapshot(profiles: [a, b])
        #expect(!DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot).isEmpty)
    }

    // MARK: - Birth Before Death

    @Test func birthBeforeDeath_exactDates_error() {
        let profile = makeProfile(birthDate: "1920", deathDate: "1668")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func birthBeforeDeath_validDates_noIssue() {
        let profile = makeProfile(birthDate: "1880", deathDate: "1960")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func birthBeforeDeath_approximateDates_warningOnly() {
        // ABT 1890 → range 1885-1895. Death 1888. Earliest(1885) < latest(1888) so no error.
        // But bestYear(1890) > bestYear(1888) → warning.
        let profile = makeProfile(birthDate: "ABT 1890", deathDate: "1888")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func birthBeforeDeath_missingDate_skips() {
        let profile = makeProfile(birthDate: "1880", deathDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func birthBeforeDeath_unboundedRange_skipsError() {
        // AFT 1920 → earliest=1920, latest=nil. Death 1900.
        // earliest(1920) > latest(1900) — but we can't use this because
        // birth.earliest is used, not birth.latest. Let me check...
        // Actually: birth.earliest(1920) > death.latest(1900) → ERROR. This is correct.
        let profile = makeProfile(birthDate: "AFT 1920", deathDate: "BEF 1900")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = BirthBeforeDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Parent Age Gap

    @Test func parentAgeGap_tooYoung_error() {
        let parent = makeProfile(id: "parent", birthDate: "1874")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        // 1874 + 14 = 1888 > 1887 → ERROR
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func parentAgeGap_adequate_noIssue() {
        let parent = makeProfile(id: "parent", birthDate: "1860")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func parentAgeGap_stepParent_skips() {
        let parent = makeProfile(id: "step", birthDate: "1880")
        let child = makeProfile(id: "child", birthDate: "1887")
        let rel = Relationship(
            id: UUID(), from: "step", to: "child",
            type: .parent, role: .father, subtype: .step,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentAgeGapRule().evaluate(profile: child, snapshot: snapshot)
        // Step-parent — rule doesn't apply
        #expect(results.isEmpty)
    }

    // MARK: - ImpossibleParentageRule (reversed/mis-roled import edges)

    @Test func impossibleParentage_parentBornAfterChild_error() {
        // The George Keyworth b.1904 "father" of William Henry b.1875 case —
        // and note the edge subtype is NOT biological, so ParentAgeGap misses it.
        let parent = makeProfile(id: "george1904", birthDate: "1904")
        let child = makeProfile(id: "william1875", birthDate: "1875")
        let rel = Relationship(
            id: UUID(), from: "george1904", to: "william1875",
            type: .parent, role: .father, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ImpossibleParentageRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
        #expect(results.first?.message.contains("reversed or mis-linked") == true)
    }

    @Test func impossibleParentage_genderRoleMismatch_error() {
        // A male linked as "mother" (Florence's son Reginald wired as her mother).
        // Dates are fine here so ONLY the gender/role contradiction fires.
        let parent = makeProfile(id: "reginald", birthDate: "1850")   // makeProfile is male
        let child = makeProfile(id: "florence", birthDate: "1880")
        let rel = Relationship(
            id: UUID(), from: "reginald", to: "florence",
            type: .parent, role: .mother, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ImpossibleParentageRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.message.contains("contradicts their gender") == true)
    }

    @Test func impossibleParentage_normalParent_noIssue() {
        let parent = makeProfile(id: "p", birthDate: "1850")
        let child = makeProfile(id: "c", birthDate: "1880")
        let rel = Relationship(
            id: UUID(), from: "p", to: "c",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        #expect(ImpossibleParentageRule().evaluate(profile: child, snapshot: snapshot).isEmpty)
    }

    @Test func impossibleParentageIsRegisteredBuiltIn() {
        #expect(AuditRules.builtIn.contains { $0.id == "impossibleParentage" })
    }

    // MARK: - Lifespan

    @Test func lifespan_exceeds110_error() {
        let profile = makeProfile(birthDate: "1800", deathDate: "1920")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = LifespanRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func lifespan_normal_noIssue() {
        let profile = makeProfile(birthDate: "1880", deathDate: "1960")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = LifespanRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Marriage Age

    @Test func marriageAge_tooYoung_error() {
        let profile = makeProfile(id: "person", birthDate: "1880")
        let spouse = makeProfile(id: "spouse")
        let rel = Relationship(
            id: UUID(), from: "person", to: "spouse",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1890"), marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile, spouse], relationships: [rel])
        let results = MarriageAgeRule().evaluate(profile: profile, snapshot: snapshot)
        // 1890 < 1880 + 16 = 1896 → ERROR (married at age 10)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    /// Regression: an adult marriage with an APPROXIMATE birth must NOT flag as
    /// married-under-16. Born ABT 1860 (earliest 1855, latest 1865), married 1879
    /// → ~19 at marriage. The old bound (earliest-marriage < latest-birth + 16 →
    /// 1879 < 1881) tripped a false error; the fixed bound uses the oldest
    /// possible age (latest-marriage − earliest-birth = 24). This is Sarah
    /// Gilbert's real case ("born 1855, married 1879 → before age 16").
    @Test func marriageAge_adultWithApproxBirth_noFalseError() {
        let profile = makeProfile(id: "sarah", birthDate: "ABT 1860")
        let spouse = makeProfile(id: "samuel")
        let rel = Relationship(
            id: UUID(), from: "sarah", to: "samuel",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "Jun 1879"), marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile, spouse], relationships: [rel])
        #expect(MarriageAgeRule().evaluate(profile: profile, snapshot: snapshot).isEmpty)
    }

    // MARK: - No Marriage After Death

    @Test func noMarriageAfterDeath_error() {
        let profile = makeProfile(id: "person", deathDate: "1885")
        let spouse = makeProfile(id: "spouse")
        let rel = Relationship(
            id: UUID(), from: "person", to: "spouse",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1890"), marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile, spouse], relationships: [rel])
        let results = NoMarriageAfterDeathRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Missing Data Rules

    @Test func missingParents_detected() {
        let profile = makeProfile()
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingParentsRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingParents_hasParent_ok() {
        let parent = makeProfile(id: "parent")
        let child = makeProfile(id: "child")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = MissingParentsRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func missingBirthDate_detected() {
        let profile = makeProfile(birthDate: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBirthDateRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingBio_detected() {
        let profile = makeProfile(bio: nil)
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func missingBio_hasBio_ok() {
        let profile = makeProfile(bio: "A biography of John Smith.")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Duplicate Detection

    @Test func duplicateDetection_sameNameAndYear() {
        let a = makeProfile(id: "a", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let b = makeProfile(id: "b", firstName: "Mabel", lastName: "Cauldwell", birthDate: "1897")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.message.contains("Possible duplicate") == true)
    }

    @Test func duplicateDetection_differentNames_noMatch() {
        let a = makeProfile(id: "a", firstName: "John", lastName: "Smith", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "Mary", lastName: "Jones", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func duplicateDetection_nicknames() {
        let a = makeProfile(id: "a", firstName: "Bill", lastName: "Smith", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "William", lastName: "Smith", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        // Bill/William are nicknames → high similarity
        #expect(results.count == 1)
    }

    @Test func duplicateDetection_spellingVariant() {
        let a = makeProfile(id: "a", firstName: "John", lastName: "Caldwell", birthDate: "1880")
        let b = makeProfile(id: "b", firstName: "John", lastName: "Cauldwell", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [a, b])
        let results = DuplicateDetectionRule().evaluate(profile: a, snapshot: snapshot)
        // Caldwell/Cauldwell → AU/A swap → 0.95 similarity
        #expect(results.count == 1)
    }

    // MARK: - Name Similarity

    @Test func nameSimilarity_exact() {
        #expect(nameSimilarity("Smith", "Smith") == 1.0)
    }

    @Test func nameSimilarity_auSwap() {
        #expect(nameSimilarity("Caldwell", "Cauldwell") == 0.95)
    }

    @Test func nameSimilarity_nickname() {
        #expect(nameSimilarity("Bill", "William") == 0.85)
        #expect(nameSimilarity("Bob", "Robert") == 0.85)
        #expect(nameSimilarity("Peggy", "Margaret") == 0.85)
    }

    @Test func nameSimilarity_contains() {
        #expect(nameSimilarity("Mary", "Mary Ann") == 0.8)
    }

    @Test func nameSimilarity_noMatch() {
        #expect(nameSimilarity("John", "Mary") == 0.0)
    }

    // MARK: - Parent Died Before Child

    @Test func parentDiedBeforeChild_error() {
        let parent = makeProfile(id: "parent", birthDate: "1850", deathDate: "1880")
        let child = makeProfile(id: "child", birthDate: "1885")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentDiedBeforeChildRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    @Test func parentDiedBeforeChild_posthumousOK() {
        // Parent died 1 year before child born — allowed (posthumous birth)
        let parent = makeProfile(id: "parent", birthDate: "1850", deathDate: "1884")
        let child = makeProfile(id: "child", birthDate: "1885")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentDiedBeforeChildRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Parent Suspiciously Old

    @Test func parentSuspiciouslyOld_warning() {
        let parent = makeProfile(id: "parent", birthDate: "1820")
        let child = makeProfile(id: "child", birthDate: "1880")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentSuspiciouslyOldRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
    }

    @Test func parentSuspiciouslyOld_normalGap_ok() {
        let parent = makeProfile(id: "parent", birthDate: "1850")
        let child = makeProfile(id: "child", birthDate: "1880")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = ParentSuspiciouslyOldRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Self-Spouse

    @Test func selfSpouse_detected() {
        let profile = makeProfile(id: "person")
        let rel = Relationship(
            id: UUID(), from: "person", to: "person",
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [profile], relationships: [rel])
        let results = SelfSpouseRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .error)
    }

    // MARK: - Unsourced Bio

    @Test func unsourcedBio_detected() {
        let profile = makeProfile(bio: "This is a biography that is longer than fifty characters but has no source citations at all anywhere.")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = UnsourcedBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    @Test func unsourcedBio_withRefs_ok() {
        let profile = makeProfile(bio: "This is a biography with sources. <ref>Some source</ref> More text here to make it long enough.")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = UnsourcedBioRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Missing Death Location

    @Test func missingDeathLocation_detected() {
        let profile = makeProfile(birthDate: "1880", deathDate: "1960")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = MissingDeathLocationRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
    }

    // MARK: - Ancestor Extension

    @Test func ancestorExtension_endOfLine() {
        let profile = makeProfile(firstName: "John", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = AncestorExtensionRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .info)
    }

    @Test func ancestorExtension_hasParents_ok() {
        let parent = makeProfile(id: "parent")
        let child = makeProfile(id: "child", firstName: "John", birthDate: "1880")
        let rel = Relationship(
            id: UUID(), from: "parent", to: "child",
            type: .parent, role: .father, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = makeSnapshot(profiles: [parent, child], relationships: [rel])
        let results = AncestorExtensionRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func ancestorExtension_skipsUnknown() {
        let profile = makeProfile(firstName: "Unknown", birthDate: "1880")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = AncestorExtensionRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    @Test func ancestorExtension_tooRecent_ok() {
        let profile = makeProfile(firstName: "John", birthDate: "1950")
        let snapshot = makeSnapshot(profiles: [profile])
        let results = AncestorExtensionRule().evaluate(profile: profile, snapshot: snapshot)
        #expect(results.isEmpty)
    }

    // MARK: - Full Audit on Real GEDCOM

    @Test func auditRealGEDCOM() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let testDir = thisFile.deletingLastPathComponent()
        let repoRoot = testDir.deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("Cauldwell Family Tree.ged").path

        let parsed = try GEDCOMParser.parse(fileAt: path)
        let summary = AuditEngine.auditGrouped(parsed.snapshot)

        #expect(summary.profilesChecked == 216)
        #expect(summary.total > 0)
        // Should find some missing data at minimum
        #expect(!summary.warnings.isEmpty || !summary.info.isEmpty)
    }
}
