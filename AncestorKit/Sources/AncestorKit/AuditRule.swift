import Foundation

/// Protocol — all rules (built-in and future user-defined) conform.
/// Each rule is its own struct, independently testable.
public nonisolated protocol AuditRuleDefinition: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var fireCondition: String { get }
    var warningCondition: String? { get }
    var workedExample: String { get }
    var defaultSeverity: Severity { get }
    var category: AuditCategory { get }

    /// Numeric thresholds the user can tune (M18, DESIGN.md §13). Rules
    /// that consume tunables read them via `AuditEngine`'s threshold
    /// resolution helpers, falling back to `defaultValue` when no
    /// override exists. Rules with no tunables return [].
    var tunableThresholds: [TunableThreshold] { get }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult]

    /// Threshold-aware evaluation (M18). The audit engine calls this with the
    /// per-rule merged thresholds dictionary (defaults overridden by the user's
    /// global override). Rules that don't honour thresholds get the default
    /// implementation, which delegates to the zero-threshold `evaluate`.
    /// Direct callers (existing tests) keep using the 2-arg method, which
    /// resolves to the rule's defaults.
    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult]

    /// Manual-guidance message variant (M16.6). When `AppState.isSmallManualProject`
    /// is active, the audit engine attaches this to the result so the UI can
    /// frame gaps as suggestions ("you might add…") rather than warnings.
    /// Returns nil to indicate no guidance variant — the canonical `message`
    /// is used unchanged. Errors and consistency issues should leave this nil.
    func guidanceMessage(profile: Profile) -> String?
}

// Default category — most rules are consistency issues
nonisolated extension AuditRuleDefinition {
    public var category: AuditCategory { .issue }

    /// Default: no tunable thresholds. Rules opt-in by overriding.
    public var tunableThresholds: [TunableThreshold] { [] }

    /// Default: ignore thresholds and call the zero-arg evaluate.
    /// Threshold-honouring rules override this.
    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot)
    }

    /// Default: no guidance variant. Rules opt-in by overriding.
    public func guidanceMessage(profile: Profile) -> String? { nil }
}

/// Registry of built-in rules.
public nonisolated enum AuditRules {
    public static let builtIn: [AuditRuleDefinition] = [
        BirthBeforeDeathRule(),
        ParentsPerRoleRule(),
        RecordAfterDeathRule(),
        OrphanStubRule(),
        PhantomSpouseRule(),
        ParentAgeGapRule(),
        MarriageAgeRule(),
        LifespanRule(),
        MuddledIdentityRule(),
        ImpossibleParentageRule(),
        NoMarriageAfterDeathRule(),
        MissingParentsRule(),
        MissingBirthDateRule(),
        MissingDeathDateRule(),
        MissingBirthLocationRule(),
        MissingBioRule(),
        InvalidDateRule(),
        DuplicateDetectionRule(),
        ExcessParentEdgesRule(),
        CensusRelationshipRule(),
        MissingCoParentRule(),
        EmptyProfileRule(),
        CompletenessScoreRule(),
        ParentDiedBeforeChildRule(),
        ParentSuspiciouslyOldRule(),
        SelfSpouseRule(),
        UnsourcedBioRule(),
        MissingDeathLocationRule(),
        AncestorExtensionRule(),
        UnlinkedSpouseForFemaleSubjectRule(),
        MarriedSurnameFromSpouseRule(),
        CensusAgeBirthYearRule(),
        GivenNameContainsMiddleRule(),
        JunkInNameRule(),
        IncompleteNameRule(),
        SuspectLocationRule(),
    ]
}

// MARK: - Missing Co-Parent (sibling-corroborated)

/// A child recorded with exactly ONE parent, whose sibling has a SECOND parent
/// they lack — and that second parent is the known parent's spouse. The classic
/// case: children added from one parent's census kept only that parent (the
/// Wheeldon daughters had Ruth but not John, while their siblings had both).
///
/// Sibling-corroboration is what makes this safe: it fires only when the known
/// parent's spouse ALREADY parents one of the child's siblings, so it won't
/// misfire on genuine single parents or step-relationships. It stays a
/// suggestion (the human links), so remarriage cases can be declined; and it
/// only fires on a single unambiguous candidate (two spouses each parenting a
/// different sibling → a possible remarriage → stay silent).
public nonisolated struct MissingCoParentRule: AuditRuleDefinition {
    public let id = "missingCoParent"
    // `.issue`, not `.gap`: a lopsided family (siblings not sharing parents) is a
    // structural inconsistency, and `.issue` keeps this actionable finding out of
    // the 800-strong Gaps bucket where it would be buried.
    public let category: AuditCategory = .issue
    public let displayName = "Missing Co-Parent"
    public let description = "A child has only one parent recorded, but a sibling also has a second parent (the known parent's spouse) — so the child is very likely missing that co-parent too."
    public let fireCondition = "Profile has exactly one parent E; E has a spouse S who already parents one of the profile's siblings but not the profile; S is the only such candidate."
    public let warningCondition: String? = nil
    public let workedExample = "Hannah Wheeldon has only Ruth as a parent, but her siblings Kezia and Samuel also have John Wheeldon — John is very likely Hannah's father too."
    public let defaultSeverity = Severity.warning
    public init() {}

    public struct Suggestion {
        public let coParent: Profile
        public let knownParent: Profile
        public let corroboratingSibling: Profile
    }

    /// The single, sibling-corroborated co-parent to suggest — nil when the rule
    /// doesn't apply or the candidate is ambiguous. Shared by the rule and the
    /// one-click fix so the finding and the action can never disagree.
    public static func suggestion(for profile: Profile, in snapshot: FamilyGraphSnapshot) -> Suggestion? {
        let parents = snapshot.parentsOf(profile.id)
        guard parents.count == 1, let known = parents.first else { return nil }
        let parentIDs = Set(parents.map(\.id))
        let siblings = snapshot.childrenOf(known.id).filter { $0.id != profile.id }
        guard !siblings.isEmpty else { return nil }

        var candidate: Suggestion?
        var count = 0
        for spouse in snapshot.spousesOf(known.id) where !parentIDs.contains(spouse.id) {
            // Only a spouse who ALREADY parents one of the profile's siblings.
            if let sib = siblings.first(where: { sib in
                snapshot.parentsOf(sib.id).contains { $0.id == spouse.id }
            }) {
                count += 1
                candidate = Suggestion(coParent: spouse, knownParent: known, corroboratingSibling: sib)
            }
        }
        return count == 1 ? candidate : nil
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let s = Self.suggestion(for: profile, in: snapshot) else { return [] }
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .warning, category: .issue, ruleID: id,
            message: Self.message(subject: profile, suggestion: s),
            relatedProfileIDs: [s.coParent.id])]
    }

    static func message(subject: Profile, suggestion s: Suggestion) -> String {
        let role = s.coParent.gender == .male ? "father"
            : (s.coParent.gender == .female ? "mother" : "other parent")
        let who = subject.firstName ?? subject.displayName
        // Surface the birth years so the chronology can be sanity-checked before
        // accepting (e.g. the child must be born after the parents married). The
        // co-parent's year, when known, frames the childbearing window.
        func born(_ p: Profile) -> String { p.birthDate?.bestYear.map { "b.\($0)" } ?? "no birth date" }
        let momBorn = s.coParent.birthDate?.bestYear.map { " (b.\($0))" } ?? ""
        let base = "\(who) (\(born(subject))) has only \(s.knownParent.displayName) as a parent, but their sibling \(s.corroboratingSibling.displayName) (\(born(s.corroboratingSibling))) also has \(s.coParent.displayName)\(momBorn) — likely \(who)'s \(role)."
        // No birth year → the date check can't be made here; nudge to confirm one.
        return subject.birthDate?.bestYear == nil
            ? base + " Confirm \(who)'s birth year before accepting."
            : base
    }
}

// MARK: - Junk In Name (import hygiene)

/// Flags a name field carrying placeholder or junk text — a literal "?", a
/// parenthetical aside/nickname, or a word like "unknown". These are classic
/// GEDCOM-import residue ("Mary Anne ?", "Elizabeth Maud (Betty) Thompson").
/// Distinct from a *blank* profile (EmptyProfileRule): the junk sits alongside
/// an otherwise-real name, so the profile isn't empty. Shares detection with
/// `Profile.nameFieldJunk` so audit and cleanse agree on what counts as junk.
public nonisolated struct JunkInNameRule: AuditRuleDefinition {
    public let id = "junkInName"
    public let displayName = "Junk In Name"
    public let description = "A name field contains placeholder or junk text — a \"?\", a parenthetical aside, or a word like \"unknown\"."
    public let fireCondition = "firstName or lastName contains \"?\", parentheses, or a placeholder word."
    public let warningCondition: String? = nil
    public let workedExample = "\"Mary Anne ?\" (surname is a literal \"?\") or \"Elizabeth Maud (Betty) Thompson\" (a nickname folded into the given name)."
    public let defaultSeverity = Severity.warning
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let junk = profile.nameFieldJunk else { return [] }
        let which = junk.field == .lastName ? "surname" : "given name"
        let display = profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "(unnamed)" : profile.displayName
        return [AuditResult(
            profileID: profile.id, profileName: display,
            severity: .warning, ruleID: id,
            message: "\(display) — \(which) \u{201C}\(junk.value)\u{201D} \(junk.reason). Clean it up or replace it with the real name."
        )]
    }
}

// MARK: - Incomplete Name (half a name)

/// Flags a profile with only half a name — a given name and no surname, a
/// surname and no given name, or a given name that is just an initial. INFO,
/// not a warning: a surname-only person is frequently a legitimate unknown-
/// maiden placeholder (an unnamed spouse), so this is a nudge to complete or
/// research the name, not an error. Shares `Profile.incompleteName`, which
/// defers empty names to EmptyProfileRule and junk names to JunkInNameRule so
/// the three never double-fire.
public nonisolated struct IncompleteNameRule: AuditRuleDefinition {
    public let id = "incompleteName"
    public let category: AuditCategory = .gap
    public let displayName = "Incomplete Name"
    public let description = "A profile has only part of a name — a given name with no surname, a surname with no given name, or a given name that is only an initial."
    public let fireCondition = "Exactly one of given/surname present (non-junk), or the given name is a single initial."
    public let warningCondition: String? = nil
    public let workedExample = "\" Andrews\" (surname only — likely an unknown-maiden spouse) or \"R Smith\" (given name is only an initial)."
    public let defaultSeverity = Severity.info
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let reason = profile.incompleteName else { return [] }
        let display = profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "(unnamed)" : profile.displayName.trimmingCharacters(in: .whitespaces)
        return [AuditResult(
            profileID: profile.id, profileName: display,
            severity: .info, category: .gap, ruleID: id,
            message: "\(display) — \(reason). Add the missing part, or research it (a surname-only spouse often needs a maiden name)."
        )]
    }
}

// MARK: - Suspect Location (malformed place string)

/// Flags a birth/death location string that looks malformed — a stray "?", a
/// rogue comma, or all-caps / all-lowercase casing. A fast, gazetteer-free
/// heuristic that surfaces the obvious junk ("Wensley????", "CHESTERFIELD",
/// "wirksworth", "Sharlston,") as a tree-wide chip; the Cleanse wizard still
/// does the real gazetteer match and fix. Shares `Profile.suspectLocations`.
public nonisolated struct SuspectLocationRule: AuditRuleDefinition {
    public let id = "suspectLocation"
    public let displayName = "Suspect Location"
    public let description = "A birth or death place string looks malformed — stray punctuation, a rogue comma, or unusual casing."
    public let fireCondition = "Location contains \"?\", a stray comma, or is entirely upper- or lower-case."
    public let warningCondition: String? = nil
    public let workedExample = "\"Wensley????\", \"CHESTERFIELD\", \"wirksworth\", or \"Sharlston,\" (trailing comma)."
    public let defaultSeverity = Severity.info
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        profile.suspectLocations.map { loc in
            let which = loc.field == .deathLocation ? "death" : "birth"
            return AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .info, ruleID: id,
                message: "\(profile.displayName) — \(which) place \u{201C}\(loc.value)\u{201D} looks malformed (\(loc.reason)). Tidy it in Cleanse."
            )
        }
    }
}

// MARK: - Given Name Contains Middle Name (import hygiene)

/// Flags profiles whose `firstName` holds more than one token while `middleName`
/// is empty — the signature of an import that packed the middle name into the
/// given field (GEDCOM has no separate middle-name tag, so "Lilian Mary" lands
/// wholesale in `firstName`). Left unsplit, the given name reads wrong on the
/// profile and the record scorer has to compensate at match time. Surfaces as an
/// info chip; the Cleanse wizard carries the matching one-tap "split into given +
/// middle" fix (or decline, for a genuine compound given like "Mary Ann"). Shares
/// its detection with `Profile.impliedGivenMiddleSplit` so audit and cleanse can
/// never disagree about which records are affected.
public nonisolated struct GivenNameContainsMiddleRule: AuditRuleDefinition {
    public let id = "givenNameContainsMiddle"
    public let category: AuditCategory = .issue
    public let displayName = "Middle Name In Given Name"
    public let description = "A profile's given name holds more than one word while the middle name is empty — the middle name was likely folded into the given field on import."
    public let fireCondition = "firstName has ≥2 tokens AND middleName is empty."
    public let warningCondition: String? = nil
    public let workedExample = "Imported \"Lilian Mary\" in firstName with an empty middleName → should be firstName \"Lilian\", middleName \"Mary\"."
    public let defaultSeverity = Severity.info
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let split = profile.impliedGivenMiddleSplit else { return [] }
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .info, ruleID: id,
            message: "Given name \"\(profile.firstName ?? "")\" looks like it contains a middle name — split into given \"\(split.first)\" + middle \"\(split.middle)\"."
        )]
    }
}

// MARK: - Completeness Score Rule

public nonisolated struct CompletenessScoreRule: AuditRuleDefinition {
    public init() {}

    public let id = "completenessScore"
    public let category: AuditCategory = .gap
    public let displayName = "Completeness Score"
    public let description = "Profiles are scored 0-7 based on populated fields."
    public let fireCondition = "Score below maximum for that profile type."
    public let warningCondition: String? = nil
    public let workedExample = "Profile with name, birth date, birth location but no death info, no bio, no parents → 3/7"
    public let defaultSeverity = Severity.info

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let comp = snapshot.completeness(for: profile.id)
        if comp.score < comp.maximum {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .gap, ruleID: id,
                message: "\(profile.displayName) — completeness \(comp.score)/\(comp.maximum) (missing: \(comp.missing.map(\.label).joined(separator: ", ")))"
            )]
        }
        return []
    }
}

// MARK: - Temporal Rules (Error + Warning tiers)

public nonisolated struct BirthBeforeDeathRule: AuditRuleDefinition {
    public init() {}

    public let id = "birthBeforeDeath"
    public let displayName = "Birth Before Death"
    public let description = "A person must be born before they die."
    public let fireCondition = "birth.earliest > death.latest"
    public let warningCondition: String? = "birth.bestYear > death.bestYear"
    public let workedExample = "Birth 'AFT 1920' (earliest=1920), Death 'BEF 1668' (latest=1668): 1920 > 1668 → ERROR"
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let birth = profile.effectiveDate(.birthDate),
              let death = profile.effectiveDate(.deathDate) else { return [] }
        var results: [AuditResult] = []

        if let be = birth.earliest, let dl = death.latest, be > dl {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .error, ruleID: id,
                message: "Born \(birth.original) but died \(death.original) — birth after death"
            ))
        } else if let bby = birth.bestYear, let dby = death.bestYear, bby > dby {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, ruleID: id,
                message: "Born ~\(bby) but died ~\(dby) — probable birth after death"
            ))
        }
        return results
    }
}

public nonisolated struct ParentAgeGapRule: AuditRuleDefinition {
    public init() {}

    public let id = "parentAgeGap"
    public let displayName = "Parent Age Gap"
    public let description = "A biological parent must be at least 14 years older than their child."
    public let fireCondition = "parent.birthDate.latest + 14 > child.birthDate.earliest"
    public let warningCondition: String? = "parent.bestYear + 14 > child.bestYear"
    public let workedExample = "Parent '1874' (latest=1874), Child '1887' (earliest=1887): 1874+14=1888 > 1887 → ERROR (gap is 13)"
    public let defaultSeverity = Severity.error

    public var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "minYearsGap",
            displayName: "Minimum parent-child age gap",
            defaultValue: 14, minimum: 8, maximum: 20, unit: "years"
        )]
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        let minGap = Int(thresholds["minYearsGap"] ?? 14)
        guard let childBirth = profile.effectiveDate(.birthDate) else { return [] }
        var results: [AuditResult] = []

        let parentRels = snapshot.relationships.filter {
            $0.type == .parent && $0.to == profile.id && $0.subtype == .biological
        }

        for rel in parentRels {
            guard let parent = snapshot.profiles[rel.from],
                  let parentBirth = parent.effectiveDate(.birthDate) else { continue }

            if let pl = parentBirth.latest, let ce = childBirth.earliest, pl + minGap > ce {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(parent.displayName) (born \(parentBirth.original)) is parent of \(profile.displayName) (born \(childBirth.original)) — gap may be less than \(minGap) years"
                ))
            } else if let pby = parentBirth.bestYear, let cby = childBirth.bestYear, pby + minGap > cby {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(parent.displayName) (~\(pby)) may be too young to be parent of \(profile.displayName) (~\(cby)) — gap ~\(cby - pby) years"
                ))
            }
        }
        return results
    }
}

/// Detects a biologically impossible parent edge — the "parent" is not older
/// than the child (born the same year or later), or their gender contradicts
/// the parent role (a male linked as a "mother"). The mechanical signature of a
/// GEDCOM import (or manual slip) that reversed parent/child DIRECTION or got
/// the ROLE wrong: a descendant wired upward as an ancestor, or a child
/// attached to a parent with the role reversed.
///
/// Distinct from `ParentAgeGapRule` (a real biological parent merely a few
/// years too young): this is a HARD impossibility, checked across EVERY
/// relationship subtype — `ParentAgeGapRule` filters to `.biological`, so it
/// misses import artifacts whose edges carry an unknown/other subtype.
public nonisolated struct ImpossibleParentageRule: AuditRuleDefinition {
    public init() {}

    public let id = "impossibleParentage"
    public let displayName = "Impossible Parentage"
    public let description = "A parent linked to a child born before them, or whose gender contradicts the parent role — usually a reversed or mis-roled edge from a GEDCOM import."
    public let fireCondition = "a parent's EARLIEST possible birth + 12 > the child's LATEST possible birth (parent implausibly young / not older — robust to disputed dates, which can't fire it from a midpoint), or a male parent in a 'mother' role (or vice versa)"
    public let warningCondition: String? = nil
    public let workedExample = "A parent recorded with a birth year at or after their child's — e.g. an imported edge that reversed parent and child — can't be biologically real; flagged for the user to re-point."
    public let defaultSeverity = Severity.error
    public let category: AuditCategory = .issue

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // `profile` is the CHILD; inspect edges where it's the `to` side.
        var results: [AuditResult] = []
        let childYear = profile.effectiveDate(.birthDate)?.bestYear
        for rel in snapshot.relationships where rel.type == .parent && rel.to == profile.id {
            guard let parent = snapshot.profiles[rel.from], !parent.isDeleted else { continue }

            // Date impossibility — a parent must be meaningfully OLDER than the
            // child. Compare CONSERVATIVE bounds with a minimum parenting age:
            // the edge is impossible when the LARGEST possible gap (child's
            // latest birth − parent's earliest birth) is still under the floor.
            //
            // Two things this gets right:
            //  • Disputed/wide dates can't false-fire from a midpoint — using
            //    the range bounds, a stray record decades off (real case:
            //    Gertrude Cauldwell, b.1920 with a mis-attached 1859 census →
            //    effective range [1859,1920]) still leaves a 31-year gap to her
            //    1889-born father, so it correctly does NOT fire.
            //  • A parent who is the child's CONTEMPORARY still fires — even
            //    with a fuzzy near-same-year estimate (real case: Elizabeth
            //    ~1861, CAL, wired as mother of Joseph 1861: max gap ~1 year).
            let minParentAge = 12
            if let childLatest = profile.effectiveDate(.birthDate)?.latest,
               let parentEarliest = parent.effectiveDate(.birthDate)?.earliest,
               parentEarliest + minParentAge > childLatest {
                let py = parent.effectiveDate(.birthDate)?.bestYear ?? parentEarliest
                let cy = childYear ?? childLatest
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, category: .issue, ruleID: id,
                    message: "\(parent.displayName) (born ~\(py)) is too close in age to be a parent of \(profile.displayName) (born ~\(cy)) — a parent must be meaningfully older; this edge is likely reversed or mis-linked (common GEDCOM import error)"))
                continue
            }

            // Gender/role contradiction — a male "mother" or female "father".
            if let role = rel.role, let g = parent.gender,
               (role == .mother && g == .male) || (role == .father && g == .female) {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, category: .issue, ruleID: id,
                    message: "\(parent.displayName) (\(g == .male ? "male" : "female")) is linked as the \(role == .mother ? "mother" : "father") of \(profile.displayName) — the role contradicts their gender; likely a mis-linked edge"))
            }
        }
        return results
    }
}

public nonisolated struct MarriageAgeRule: AuditRuleDefinition {
    public init() {}

    public let id = "marriageAge"
    public let displayName = "Marriage Age"
    public let description = "A person must be at least 16 to marry."
    public let fireCondition = "marriage.latest - birth.earliest < 16 (even the OLDEST possible age at marriage is under 16)"
    public let warningCondition: String? = "marriage.bestYear - birth.bestYear < 16 (best-estimate age under 16)"
    public let workedExample = "Born ABT 1860 (earliest 1855), married 1879: oldest age 1879−1855=24 → no error. Born 1870, married 1884: 1884−1870=14 → ERROR."
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let birth = profile.effectiveDate(.birthDate) else { return [] }
        var results: [AuditResult] = []

        let spouseRels = snapshot.relationships.filter {
            $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
        }

        for rel in spouseRels {
            guard let marriage = rel.marriageDate else { continue }

            // Hard error only when even the OLDEST possible age at marriage is
            // under 16 (latest marriage − earliest birth). The old bound used the
            // MINIMUM age (earliest marriage − latest birth), so a wide or
            // conflicting birth range tripped the error even when the best
            // estimate was well over 16 — producing contradictions like "born
            // 1855, married 1879 → before age 16" (24 at marriage).
            if let ml = marriage.latest, let be = birth.earliest, ml - be < 16 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(profile.displayName) married \(marriage.original) but born \(birth.original) — that is only \(max(0, ml - be)) at marriage, under the age of 16"
                ))
            } else if let mby = marriage.bestYear, let bby = birth.bestYear, mby - bby < 16 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(profile.displayName) may have married (~\(mby)) at about \(max(0, mby - bby)), before age 16 (born ~\(bby))"
                ))
            }
        }
        return results
    }
}

/// Patronymic-muddle detector: a single profile whose ACCEPTED birth (or
/// death) date spans more years than one person's could — the signature of two
/// same-named relatives (father/son both "Abraham", etc.) collapsed onto one
/// node. A person is born once and dies once; a 27-year accepted birth range
/// means two people's births were averaged together.
///
/// This is the acceptance-side echo of the discovery engine's identity
/// constraints (dies-once, one birth window): those split contradictory
/// records apart while *clustering*; this flags the same contradiction once
/// it's already been *absorbed* onto a profile. Read-only — it names the muddle
/// so a human can disentangle it.
public nonisolated struct MuddledIdentityRule: AuditRuleDefinition {
    public init() {}

    public let id = "muddledIdentity"
    public let displayName = "Muddled Identity"
    public let description = "A profile whose birth or death date spans more years than one person's could — usually two same-named relatives (a patronymic muddle) merged into one profile."
    public let fireCondition = "birthDate or deathDate range wider than the span threshold (default 15 years)"
    public let warningCondition: String? = nil
    public let workedExample = "Abraham Twyford, birth 'BET 1882 AND 1909' — a 27-year span: the 1888-born father and a second Abraham collapsed onto one node."
    public let defaultSeverity = Severity.warning
    public let category: AuditCategory = .issue

    public static let defaultSpanYears = 15

    public var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "spanYears",
            displayName: "Max plausible date span for one person",
            defaultValue: Double(Self.defaultSpanYears), minimum: 8, maximum: 40, unit: "years"
        )]
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        let maxSpan = Int(thresholds["spanYears"] ?? Double(Self.defaultSpanYears))
        var results: [AuditResult] = []
        for (field, label) in [(ProfileField.birthDate, "Birth"), (ProfileField.deathDate, "Death")] {
            guard let date = profile.effectiveDate(field),
                  let earliest = date.earliest, let latest = date.latest,
                  latest - earliest > maxSpan else { continue }
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .issue, ruleID: id,
                message: "\(profile.displayName) — \(label.lowercased()) recorded as '\(date.original)' spans \(latest - earliest) years; likely two same-named people (a patronymic muddle) merged into one profile"
            ))
        }
        return results
    }
}

public nonisolated struct LifespanRule: AuditRuleDefinition {
    public init() {}

    public let id = "lifespan"
    public let displayName = "Lifespan"
    public let description = "No person lives beyond 110 years."
    public let fireCondition = "death.earliest - birth.latest > 110"
    public let warningCondition: String? = "death.bestYear - birth.bestYear > 110"
    public let workedExample = "Birth '1800' (latest=1800), Death 'AFT 1920' (earliest=1920): 1920-1800=120 > 110 → ERROR"
    public let defaultSeverity = Severity.error

    public var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "maxLifespan",
            displayName: "Maximum plausible lifespan",
            defaultValue: 110, minimum: 90, maximum: 130, unit: "years"
        )]
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        let maxLifespan = Int(thresholds["maxLifespan"] ?? 110)
        guard let birth = profile.effectiveDate(.birthDate),
              let death = profile.effectiveDate(.deathDate) else { return [] }
        var results: [AuditResult] = []

        if let de = death.earliest, let bl = birth.latest, de - bl > maxLifespan {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .error, ruleID: id,
                message: "\(profile.displayName) lifespan \(de - bl) years (born \(birth.original), died \(death.original)) — exceeds \(maxLifespan)"
            ))
        } else if let dby = death.bestYear, let bby = birth.bestYear, dby - bby > maxLifespan {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) probable lifespan ~\(dby - bby) years — exceeds \(maxLifespan)"
            ))
        }
        return results
    }
}

public nonisolated struct NoMarriageAfterDeathRule: AuditRuleDefinition {
    public init() {}

    public let id = "noMarriageAfterDeath"
    public let displayName = "No Marriage After Death"
    public let description = "A person cannot marry after they die."
    public let fireCondition = "marriage.earliest > death.latest"
    public let warningCondition: String? = "marriage.bestYear > death.bestYear"
    public let workedExample = "Marriage '1890', Death 'BEF 1885' (latest=1885): 1890 > 1885 → ERROR"
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let death = profile.effectiveDate(.deathDate) else { return [] }
        var results: [AuditResult] = []

        let spouseRels = snapshot.relationships.filter {
            $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
        }

        for rel in spouseRels {
            guard let marriage = rel.marriageDate else { continue }

            if let me = marriage.earliest, let dl = death.latest, me > dl {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(profile.displayName) married \(marriage.original) but died \(death.original) — married after death"
                ))
            } else if let mby = marriage.bestYear, let dby = death.bestYear, mby > dby {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(profile.displayName) may have married (~\(mby)) after death (~\(dby))"
                ))
            }
        }
        return results
    }
}

// MARK: - Missing Data Rules

public nonisolated struct MissingParentsRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingParents"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Parents"
    public let description = "Profile has no parent links."
    public let fireCondition = "No parent edges for this profile."
    public let warningCondition: String? = nil
    public let workedExample = ""
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let parents = snapshot.parentsOf(profile.id)
        if parents.isEmpty {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no parents"
            )]
        }
        return []
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "Consider adding \(profile.displayName)'s parents — their parish records often unlock further generations."
    }
}

public nonisolated struct MissingBirthDateRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingBirthDate"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Birth Date"
    public let description = "Profile has no birth date."
    public let fireCondition = "birthDate is nil."
    public let warningCondition: String? = nil
    public let workedExample = ""
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        if profile.birthDate == nil {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no birth date"
            )]
        }
        return []
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "What you might add next: birth date for \(profile.displayName)."
    }
}

public nonisolated struct MissingDeathDateRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingDeathDate"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Death Date"
    public let description = "Profile has no death date (may still be living)."
    public let fireCondition = "deathDate is nil and not potentially living."
    public let warningCondition: String? = nil
    public let workedExample = ""
    public let defaultSeverity = Severity.info

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let comp = snapshot.completeness(for: profile.id)
        if profile.deathDate == nil && !comp.potentiallyLiving {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no death date"
            )]
        }
        return []
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "What you might add next: death date for \(profile.displayName)."
    }
}

public nonisolated struct MissingBirthLocationRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingBirthLocation"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Birth Location"
    public let description = "Profile has no birth location."
    public let fireCondition = "birthLocation is nil."
    public let warningCondition: String? = nil
    public let workedExample = ""
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        if profile.birthLocation == nil {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no birth location"
            )]
        }
        return []
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "You could note where \(profile.displayName) was born when you next find a record."
    }
}

public nonisolated struct MissingBioRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingBio"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Biography"
    public let description = "Profile has no biography."
    public let fireCondition = "bio is nil or empty."
    public let warningCondition: String? = nil
    public let workedExample = ""
    public let defaultSeverity = Severity.info

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        if profile.bio == nil || (profile.bio?.isEmpty ?? true) {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no biography"
            )]
        }
        return []
    }
}

// MARK: - Invalid or Unclear Date

/// A date is filled in but can't be fully, sensibly understood — no readable
/// year, a year in the future, or leftover text (a misspelt month, a word-form
/// day) the parser didn't recognise. Such dates are silently ignored or
/// misread by every year-range check, so they look like evidence but aren't.
/// Covers the profile's birth/death and every life event's date.
public nonisolated struct InvalidDateRule: AuditRuleDefinition {
    public init() {}

    public let id = "invalidDate"
    public let displayName = "Invalid or unclear date"
    public let description = "A date is filled in but can't be fully understood — no readable year, a future year, or unrecognised text — so date checks ignore or misread it."
    public let fireCondition = "A date field's text doesn't resolve to a sensible, fully-recognised date."
    public let warningCondition: String? = nil
    public let workedExample = "\"Seventeenth of Julie 1987\" — the year reads as 1987 but the day/month are unrecognised."
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        var results: [AuditResult] = []

        func check(_ date: GenealogicalDate?, _ label: String) {
            guard let date, let reason = Self.problem(with: date) else { return }
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .issue, ruleID: id,
                message: "\(profile.displayName) — \(label) date \(reason)"))
        }

        check(profile.birthDate, "birth")
        check(profile.deathDate, "death")
        for event in snapshot.lifeEvents[profile.id] ?? [] {
            let kind = event.type.displayName.lowercased()
            check(event.date, kind)
            check(event.endDate, "\(kind) end")
        }
        return results
    }

    /// Why a date is invalid/unclear, or nil when it reads cleanly. Public so
    /// the guided date field and tests can share the exact same judgement.
    public static func problem(with date: GenealogicalDate) -> String? {
        let text = date.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let year = date.bestYear else {
            return "“\(text)” couldn’t be read as a year, so research and date checks ignore it."
        }
        let currentYear = Calendar.current.component(.year, from: Date())
        if year > currentYear + 1 {
            return "“\(text)” reads as a future year (\(year)) — likely a typo."
        }
        if let stray = firstUnrecognisedWord(text) {
            return "“\(text)” contains text that wasn’t understood (“\(stray)”) — only the year (\(year)) was read; check the day and month."
        }
        if let dayIssue = impossibleDay(text) {
            return "“\(text)” — \(dayIssue)"
        }
        return nil
    }

    private static let monthNames: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    private static let monthAbbrev = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// When a month name and a day number are both present, flag a day that
    /// can't exist for that month (31 Feb, 45 Jul, day 0) — the kind of typo a
    /// human resolves at a glance.
    private static func impossibleDay(_ text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard let month = words.compactMap({ monthNames[$0] }).first else { return nil }
        let ns = text as NSString
        let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})\b"#)
        let days = (re?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [])
            .compactMap { Int(ns.substring(with: $0.range)) }
        guard let day = days.first else { return nil }
        if day < 1 || day > daysInMonth[month - 1] {
            return "the day (\(day)) is impossible for \(monthAbbrev[month - 1])."
        }
        return nil
    }

    /// Words the parser legitimately understands in a date — months (abbrev +
    /// full), qualifiers, and filler. Anything else purely-alphabetic is a
    /// misspelt month or a word-form day the parser silently dropped.
    private static let knownWords: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
        "abt", "about", "c", "ca", "cal", "calc", "circa", "est", "estimated",
        "bef", "before", "aft", "after", "bet", "between", "btw", "and", "to", "from",
        "around", "approx", "approximately", "q1", "q2", "q3", "q4", "quarter", "qtr",
        "of", "the", "on", "in",
    ]

    /// The first purely-alphabetic token that isn't a recognised date word.
    /// Only judges pure-letter tokens — anything with a digit ("17th", "1880s",
    /// "c1900", the year itself) is ambiguous and deliberately left alone to
    /// avoid false positives.
    private static func firstUnrecognisedWord(_ text: String) -> String? {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for tok in tokens where !tok.isEmpty && tok.allSatisfy(\.isLetter) {
            if !knownWords.contains(tok) { return tok }
        }
        return nil
    }
}

// MARK: - Duplicate Detection (candidate suggestion, not strict rule)

public nonisolated struct DuplicateDetectionRule: AuditRuleDefinition {
    public init() {}

    public let id = "duplicateDetection"
    public let displayName = "Possible Duplicates"
    public let description = "Two profiles with similar names and overlapping birth years may be the same person."
    public let fireCondition = "Similarity score ≥ 0.7 between two profiles."
    public let warningCondition: String? = nil
    public let workedExample = "MABEL CAULDWELL b.1897 exists as both Cauldwell-148 and Cauldwell-145"
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // Only check from the "first" profile alphabetically to avoid double-reporting
        var results: [AuditResult] = []

        for (otherID, other) in snapshot.profiles {
            guard otherID != profile.id, otherID > profile.id else { continue }

            // The user has already reviewed this pair and confirmed they are
            // two different people — don't re-surface it on this or any future
            // re-audit (a false positive on a dense same-surname tree). The
            // decision persists in the snapshot's dismissed set.
            if snapshot.dismissedDuplicatePairs.contains(DuplicatePairKey(profile.id, otherID)) {
                continue
            }

            // Structurally impossible to be the same person: a direct
            // parent-child edge already asserts these are two people (one is the
            // other's parent). MergeSafety BLOCKS the merge for exactly this
            // case — so the detector should never have proposed it. Suppress at
            // source rather than surface a row the user can only dismiss. This
            // catches same-named father/son pairs in a generational naming chain
            // (e.g. George Keyworth b.1838 → his son George b.1877).
            if hasDirectParentChildEdge(profile.id, otherID, snapshot: snapshot) {
                continue
            }

            let score = similarityScore(profile, other)
            if score >= 0.7 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "Possible duplicate: \(profile.displayName) and \(other.displayName) (score: \(String(format: "%.2f", score)))",
                    relatedProfileIDs: [otherID]
                ))
            }
        }
        return results
    }

    private func similarityScore(_ a: Profile, _ b: Profile) -> Double {
        let givenA = a.firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        let givenB = b.firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        let surnameA = a.lastName?.trimmingCharacters(in: .whitespaces) ?? ""
        let surnameB = b.lastName?.trimmingCharacters(in: .whitespaces) ?? ""

        let givenSim = (!givenA.isEmpty && !givenB.isEmpty) ? nameSimilarity(givenA, givenB) : 0.0

        // A true duplicate shares the given name too. When both profiles have a
        // given name and they're completely dissimilar (e.g. Dorothy vs
        // Florence), they're different people — usually same-surname siblings —
        // so surname (0.4) + birth-year overlap (0.3) alone must NOT reach the
        // 0.7 threshold. nameSimilarity credits nicknames, containment, and
        // single-edit typos, so anything genuinely close still scores > 0.
        if !givenA.isEmpty && !givenB.isEmpty && givenSim == 0 { return 0 }

        let surnameSim = (!surnameA.isEmpty && !surnameB.isEmpty) ? nameSimilarity(surnameA, surnameB) : 0.0

        var score = surnameSim * 0.4 + givenSim * 0.3

        // Birth year overlap corroborates; disjoint years positively DISTINGUISH.
        var datesConflict = false
        if let birthA = a.birthDate, let birthB = b.birthDate {
            if rangesOverlap(birthA, birthB) {
                score += 0.3
            } else {
                datesConflict = true
                // Two DATED profiles whose birth years are far apart cannot be
                // the same person misrecorded — census ages and estimates vary
                // by a few years, never by a generation. Beyond the gap ceiling
                // they positively distinguish, so this is never a duplicate
                // (e.g. George Keyworth 1877 vs 1904, or Lily 1907 vs 2012).
                // An exact same-name pair otherwise pins at exactly 0.70 and
                // fires regardless of the date gap — this is what stops that.
                if let gap = birthYearGap(birthA, birthB), gap > Self.distinctBirthYearGap {
                    return 0
                }
            }
        }

        // Strong-name duplicate signal without corroborating dates: a near-exact
        // surname AND a near-identical given name (a typo like GLAYS/GLADYS, or a
        // nickname / added-middle variant like GEOFF/GEOFFREY) is worth flagging
        // for review even when neither profile carries a date. Suppressed when
        // the dates positively conflict — two same-named people with disjoint
        // birth years are distinct, not duplicates.
        if surnameSim >= 0.9, givenSim >= 0.7, !datesConflict {
            score = max(score, 0.7)
        }

        return score
    }

    /// Birth-year gap beyond which two DATED profiles cannot be the same person
    /// misrecorded. Census ages and estimates drift a few years at most; a
    /// larger gap is a generational distinction, not a transcription variance.
    /// Deliberately generous (well above MergeSafety's ±2 "same person" band) so
    /// genuine duplicates recorded with fuzzy dates are never silently dropped —
    /// only clear-cut different-generation pairs are.
    static let distinctBirthYearGap = 10

    /// Years between two disjoint birth-date ranges (0 if they overlap or either
    /// is unbounded/undated). Uses `bestYear` so single years and estimate
    /// ranges compare on the same footing.
    private func birthYearGap(_ a: GenealogicalDate, _ b: GenealogicalDate) -> Int? {
        guard let ay = a.bestYear, let by = b.bestYear else { return nil }
        return abs(ay - by)
    }

    /// True when `a` and `b` are directly linked as parent and child (either
    /// direction). Mirrors MergeSafety's hard block so the detector and the
    /// merge guard agree on what "structurally impossible to be one person"
    /// means. Grandparent/uncle links are NOT direct edges and fall to the
    /// date-gap suppression instead.
    private func hasDirectParentChildEdge(_ a: String, _ b: String, snapshot: FamilyGraphSnapshot) -> Bool {
        snapshot.relationships.contains { r in
            r.type == .parent &&
            ((r.from == a && r.to == b) || (r.from == b && r.to == a))
        }
    }

    private func rangesOverlap(_ a: GenealogicalDate, _ b: GenealogicalDate) -> Bool {
        let aEarliest = a.earliest ?? Int.min
        let aLatest = a.latest ?? Int.max
        let bEarliest = b.earliest ?? Int.min
        let bLatest = b.latest ?? Int.max
        return aEarliest <= bLatest && bEarliest <= aLatest
    }
}

// MARK: - Name Similarity (ported from Python rules.py)

/// Score name similarity handling genealogical variations.
/// Returns 0.0–1.0.
public nonisolated func nameSimilarity(_ a: String, _ b: String) -> Double {
    let a = a.uppercased().trimmingCharacters(in: .whitespaces)
    let b = b.uppercased().trimmingCharacters(in: .whitespaces)

    if a == b { return 1.0 }

    // Spelling normalisation (Caldwell/Cauldwell, Colour/Color)
    let aNorm = a.replacingOccurrences(of: "AU", with: "A")
        .replacingOccurrences(of: "OU", with: "O")
    let bNorm = b.replacingOccurrences(of: "AU", with: "A")
        .replacingOccurrences(of: "OU", with: "O")
    if aNorm == bNorm { return 0.95 }

    // One contains the other (Mary Ann / Mary)
    if a.contains(b) || b.contains(a) { return 0.8 }

    // Nickname equivalents
    let nicknames: [String: String] = [
        "JACK": "JOHN", "JOHN": "JACK",
        "HARRY": "HENRY", "HENRY": "HARRY",
        "BILL": "WILLIAM", "WILLIAM": "BILL",
        "TED": "EDWARD", "EDWARD": "TED",
        "DICK": "RICHARD", "RICHARD": "DICK",
        "POLLY": "MARY", "MARY": "POLLY",
        "PEGGY": "MARGARET", "MARGARET": "PEGGY",
        "BETTY": "ELIZABETH", "ELIZABETH": "BETTY",
        "NELL": "ELLEN", "ELLEN": "NELL",
        "JOE": "JOSEPH", "JOSEPH": "JOE",
        "KATE": "CATHERINE", "CATHERINE": "KATE",
        "WILLIE": "WILLIAM",
        "NELLIE": "ELLEN",
        "LIZZIE": "ELIZABETH",
        "FLORRIE": "FLORENCE", "FLORENCE": "FLORRIE",
        "BOB": "ROBERT", "ROBERT": "BOB",
        // Ada — standalone name AND a diminutive of Adelaide/Adeline/Adela;
        // map the long forms to "ADA" so duplicate detection treats them as
        // the same person (kept in step with ScoringRules.nicknameEquivalents).
        "ADELAIDE": "ADA", "ADELINE": "ADA", "ADELA": "ADA", "ADELINA": "ADA",
    ]
    if nicknames[a] == b || nicknames[b] == a { return 0.85 }

    // A single edit away — a substitution on equal-length names (DALE/GALE) or
    // one insertion/deletion for names of 4+ letters (GLAYS/GLADYS, a dropped
    // letter). Both are Levenshtein distance 1; the length floor keeps a
    // one-edit gap from over-crediting very short names.
    if a.count == b.count {
        let diffs = zip(a, b).filter { $0 != $1 }.count
        if diffs == 1 { return 0.7 }
    } else if min(a.count, b.count) >= 4, abs(a.count - b.count) == 1, levenshtein(a, b) == 1 {
        return 0.7
    }

    return 0.0
}

/// Levenshtein edit distance (insertions, deletions, substitutions). Used by
/// `nameSimilarity` to credit single-character insertion/deletion typos across
/// unequal-length names. Two-row DP — O(a·b) time, O(b) space.
nonisolated func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    var curr = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        curr[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[b.count]
}

// MARK: - Parent Died Before Child (from Python audit.py line 134)

public nonisolated struct ParentDiedBeforeChildRule: AuditRuleDefinition {
    public init() {}

    public let id = "parentDiedBeforeChild"
    public let displayName = "Parent Died Before Child Born"
    public let description = "A parent cannot have died before their child was born (1-year posthumous allowance)."
    public let fireCondition = "parent.deathDate.latest < child.birthDate.earliest - 1"
    public let warningCondition: String? = "parent.deathDate.bestYear < child.birthDate.bestYear - 1"
    public let workedExample = "Parent died 1880, child born 1885: 1880 < 1884 → ERROR"
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let childBirth = profile.effectiveDate(.birthDate) else { return [] }
        var results: [AuditResult] = []

        let parentRels = snapshot.relationships.filter {
            $0.type == .parent && $0.to == profile.id
        }

        for rel in parentRels {
            guard let parent = snapshot.profiles[rel.from],
                  let parentDeath = parent.effectiveDate(.deathDate) else { continue }

            // Error tier: parent definitely died before child born (1-year posthumous allowance)
            if let pdl = parentDeath.latest, let cbe = childBirth.earliest, pdl < cbe - 1 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(parent.displayName) died \(parentDeath.original) but child \(profile.displayName) born \(childBirth.original) — parent died before child"
                ))
            } else if let pdby = parentDeath.bestYear, let cbby = childBirth.bestYear, pdby < cbby - 1 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(parent.displayName) (~\(pdby)) may have died before child \(profile.displayName) (~\(cbby))"
                ))
            }
        }
        return results
    }
}

// MARK: - Parent Suspiciously Old (from Python audit.py line 110)

public nonisolated struct ParentSuspiciouslyOldRule: AuditRuleDefinition {
    public init() {}

    public let id = "parentSuspiciouslyOld"
    public let displayName = "Parent Suspiciously Old"
    public let description = "A parent more than 55 years older than their child is unusual and worth checking."
    public let fireCondition = "child.birthDate.earliest - parent.birthDate.latest > 55"
    public let warningCondition: String? = "child.birthDate.bestYear - parent.birthDate.bestYear > 55"
    public let workedExample = "Parent born 1820, child born 1880: gap 60 → WARNING (unusual but possible)"
    public let defaultSeverity = Severity.warning

    public var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "maxYearsGap",
            displayName: "Maximum parent-child age gap",
            defaultValue: 55, minimum: 40, maximum: 80, unit: "years"
        )]
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        let maxGap = Int(thresholds["maxYearsGap"] ?? 55)
        guard let childBirth = profile.effectiveDate(.birthDate) else { return [] }
        var results: [AuditResult] = []

        let parentRels = snapshot.relationships.filter {
            $0.type == .parent && $0.to == profile.id
        }

        for rel in parentRels {
            guard let parent = snapshot.profiles[rel.from],
                  let parentBirth = parent.effectiveDate(.birthDate) else { continue }

            if let cbe = childBirth.earliest, let pbl = parentBirth.latest, cbe - pbl > maxGap {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(parent.displayName) (born \(parentBirth.original)) is \(cbe - pbl)+ years older than \(profile.displayName) — unusual"
                ))
            } else if let cbby = childBirth.bestYear, let pbby = parentBirth.bestYear, cbby - pbby > maxGap {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(parent.displayName) (~\(pbby)) is ~\(cbby - pbby) years older than \(profile.displayName) — unusual"
                ))
            }
        }
        return results
    }
}

// MARK: - Self-Spouse (from Python audit.py line 152)

public nonisolated struct SelfSpouseRule: AuditRuleDefinition {
    public init() {}

    public let id = "selfSpouse"
    public let displayName = "Self-Spouse"
    public let description = "A person cannot be linked as their own spouse."
    public let fireCondition = "Spouse edge where from == to."
    public let warningCondition: String? = nil
    public let workedExample = "Profile X has a spouse link pointing to itself"
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let selfSpouse = snapshot.relationships.contains {
            $0.type == .spouse && $0.from == profile.id && $0.to == profile.id
        }
        if selfSpouse {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .error, ruleID: id,
                message: "\(profile.displayName) — linked as own spouse"
            )]
        }
        return []
    }
}

// MARK: - Unsourced Bio (from Python audit.py line 190)

public nonisolated struct UnsourcedBioRule: AuditRuleDefinition {
    public init() {}

    public let id = "unsourcedBio"
    public let displayName = "Unsourced Biography"
    public let description = "Biography exists but has no source citations — may be unverified GEDCOM data."
    public let fireCondition = "Bio present (>50 chars) but no <ref> tags or Sources section."
    public let warningCondition: String? = nil
    public let workedExample = "Profile has 200-char bio but no references or Sources heading"
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let bio = profile.bio, bio.count > 50 else { return [] }

        let hasRefs = bio.contains("<ref") || bio.contains("Sources") || bio.contains("sources")
        if !hasRefs {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) — bio has no source citations (\(bio.count) chars, no <ref> or Sources)"
            )]
        }
        return []
    }
}

// MARK: - Missing Death Location (from Python audit.py line 243)

public nonisolated struct MissingDeathLocationRule: AuditRuleDefinition {
    public init() {}

    public let id = "missingDeathLocation"
    public let category: AuditCategory = .gap
    public let displayName = "Missing Death Location"
    public let description = "Profile has a death date but no death location."
    public let fireCondition = "deathDate is set but deathLocation is nil."
    public let warningCondition: String? = nil
    public let workedExample = "Profile has death date 1960 but no death location recorded"
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // Only flag if we know they died (has death date) but not where
        if profile.deathDate != nil && profile.deathLocation == nil {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — has death date but no death location"
            )]
        }
        return []
    }
}

// MARK: - Ancestor Extension (from Python audit.py line 310)

public nonisolated struct AncestorExtensionRule: AuditRuleDefinition {
    public init() {}

    public let id = "ancestorExtension"
    public let category: AuditCategory = .gap
    public let displayName = "End-of-Line Ancestor"
    public let description = "Profile has no parents and was born before 1920 — tree can be extended via parish/civil records."
    public let fireCondition = "No parent edges, birth year < 1920, name is not 'Unknown'."
    public let warningCondition: String? = nil
    public let workedExample = "John Smith born 1880 with no parents → search christening records"
    public let defaultSeverity = Severity.info

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let parents = snapshot.parentsOf(profile.id)
        guard parents.isEmpty else { return [] }

        guard let birthYear = profile.birthDate?.bestYear, birthYear < 1920 else { return [] }

        // Skip placeholder names
        let name = (profile.firstName ?? "").lowercased()
        guard !name.isEmpty,
              name != "unknown",
              name != "private",
              name != "testdebug" else { return [] }

        let sourceHint: String
        if birthYear < 1837 {
            sourceHint = "parish registers"
        } else if birthYear < 1870 {
            sourceHint = "christening/baptism records or parish registers"
        } else {
            sourceHint = "christening/baptism records"
        }

        return [AuditResult(
            id: UUID(), profileID: profile.id, profileName: profile.displayName,
            severity: .info, category: .gap, ruleID: id,
            message: "\(profile.displayName) (b.\(birthYear)) — no parents, search \(sourceHint) to extend tree"
        )]
    }
}

// MARK: - Engine-research gap rules

/// Fires when a female profile carries a known married surname but
/// no spouse is linked in the tree. Without the linked spouse, the
/// pipeline's construction-time married-surname derivation
/// (`ResearchSubject.fromProfile`) cannot pivot death/burial/probate
/// searches under the married surname — so the research engine
/// systematically misses her records filed under that name.
///
/// Mirrors the LocalTwin spouse-lookup chain in Python's
/// `_expand_post_marriage_searches` — Swift can't read the Python
/// twin file at runtime, so we surface the gap to the user with
/// guidance on linking the spouse instead.
public nonisolated struct UnlinkedSpouseForFemaleSubjectRule: AuditRuleDefinition {
    public init() {}

    public let id = "unlinkedSpouseForFemaleSubject"
    public let category: AuditCategory = .gap
    public let displayName = "Married Surname Without Linked Spouse"
    public let description = "Female profile has a married surname recorded but no spouse profile linked. Death-shape research can't pivot to the married surname."
    public let fireCondition = "gender == .female, marriedSurname is non-empty, no spouse relationship exists"
    public let warningCondition: String? = nil
    public let workedExample = "Catherine Hannah Bown (m. 1892, d. as WARD): spouse not linked in tree, engine can't search death index under WARD"
    public let defaultSeverity = Severity.warning

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard profile.gender == .female else { return [] }
        let married = (profile.marriedSurname ?? "").trimmingCharacters(in: .whitespaces)
        guard !married.isEmpty else { return [] }
        // Already covered by the construction-time derivation when
        // ANY spouse is linked — only fire when the user has the
        // surname but didn't link a spouse profile.
        guard snapshot.spousesOf(profile.id).isEmpty else { return [] }
        return [AuditResult(
            id: UUID(), profileID: profile.id, profileName: profile.displayName,
            severity: .warning, category: .gap, ruleID: id,
            message: "\(profile.displayName) — married surname '\(married)' recorded but spouse not linked"
        )]
    }

    public func guidanceMessage(profile: Profile) -> String? {
        let married = (profile.marriedSurname ?? "?").trimmingCharacters(in: .whitespaces)
        return "Link \(profile.displayName)'s spouse so research can find her death/probate records under '\(married)'. Use Add Spouse from the profile, or import the spouse from WikiTree."
    }
}

/// The MIRROR of `UnlinkedSpouseForFemaleSubjectRule`: a female profile that HAS
/// a linked spouse (whose surname differs from hers) but NO `marriedSurname`
/// recorded. Without it, `ResearchSubject.fromProfile` can't pivot death-shape
/// searches (death / burial / probate / military) to the married name, so her
/// death-side records are systematically missed — searched under her maiden
/// name, they return only namesakes (the live Jennifer Holmes → Cauldwell case:
/// probate searched as HOLMES surfaced strangers in Enfield/Frome/…, never her
/// real Derbyshire CAULDWELL grant).
///
/// The finding carries the spouse in `relatedProfileIDs` so the Tasks surface
/// can offer a one-click "Set married surname to <spouse surname>" — the app
/// suggests the fix rather than leaving the user to know they need it. Marriage
/// records were deliberately NOT auto-derived onto `marriedSurname` (divorce /
/// remarriage can change surname-at-death), so this human-confirmed nudge is the
/// safe path.
public nonisolated struct MarriedSurnameFromSpouseRule: AuditRuleDefinition {
    public let id = "marriedSurnameFromSpouse"
    // `.issue`, not `.gap`: the Tasks view routes `.gap`-category audit findings
    // out (they're meant to be redundant with the completeness Gaps view — this
    // one isn't, so `.gap` would hide it entirely). It's a data-quality issue
    // with a concrete consequence (missed death-side records), which fits.
    public let category: AuditCategory = .issue
    public let displayName = "Married Surname Missing"
    public let description = "A woman with a linked spouse but no married surname recorded — her death, probate, and burial records won't be found under her married name."
    public let fireCondition = "gender == .female, a linked spouse's surname differs from hers, and marriedSurname is empty."
    public let warningCondition: String? = nil
    public let workedExample = "Jennifer Holmes is linked to David Cauldwell but has no married surname — probate searched under HOLMES returns only namesakes, never her CAULDWELL grant."
    public let defaultSeverity = Severity.warning
    public init() {}

    /// The spouse whose surname she can adopt, plus that surname — nil when the
    /// rule doesn't apply. Shared by the rule and the Tasks one-click action so
    /// the finding and the fix can never disagree about which name to set.
    public static func suggestion(for profile: Profile, in snapshot: FamilyGraphSnapshot) -> (spouse: Profile, marriedSurname: String)? {
        guard profile.gender == .female,
              (profile.marriedSurname ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let herSurname = (profile.lastName ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        // First linked spouse with a real surname that differs from hers.
        for spouse in snapshot.spousesOf(profile.id) {
            let ss = (spouse.lastName ?? "").trimmingCharacters(in: .whitespaces)
            if !ss.isEmpty, ss.uppercased() != herSurname {
                return (spouse, ss)
            }
        }
        return nil
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let (spouse, marriedSurname) = Self.suggestion(for: profile, in: snapshot) else { return [] }
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .warning, category: .issue, ruleID: id,
            message: "\(profile.displayName) is married to \(spouse.displayName) but has no married surname — her death, probate, and burial records won't be found under '\(marriedSurname)'.",
            relatedProfileIDs: [spouse.id])]
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "Record \(profile.displayName)'s married surname so research finds her death and probate records."
    }
}

// MARK: - Excess / Placeholder Parents (2026-07-16 sibling-shortcut regression)

/// Fires when a profile has more than two parent edges, or a blank placeholder
/// parent stacked alongside a real (named) one. The sibling-shortcut direction
/// bug (owner report 2026-07-16) wired an orphan's *placeholder* parents onto an
/// established profile that already had real parents — Elsie Twyford ended up
/// with six parent edges (2 real + 4 blank placeholders), invisible in the tree
/// because the renderer collapses blank placeholders.
///
/// `ParentsPerRoleRule` (F4a) misses this entirely: the junk edges carry role
/// `.unspecified`, so the same-role duplicate check never groups them. The
/// legitimate shared-placeholder case (two parentless siblings sharing ONE
/// unknown-couple placeholder) does not fire — that is a single placeholder
/// parent with no named parent. `relatedProfileIDs` lists the placeholder
/// parents so a repair can target them precisely.
public nonisolated struct ExcessParentEdgesRule: AuditRuleDefinition {
    public let id = "excessParentEdges"
    public let displayName = "Excess or Placeholder Parents"
    public let description = "A profile must not have more than two parents, nor a blank placeholder parent alongside a real one."
    public let fireCondition = "More than 2 parent edges, OR a placeholder parent coexists with a named parent."
    public let warningCondition: String? = "Placeholder parent alongside a named parent (2 or fewer total)."
    public let workedExample = "Elsie Twyford has Abraham Twyford + Wilhelmina Wright plus four blank placeholder parents → 6 parent edges → error."
    public let defaultSeverity = Severity.error
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let parentEdges = snapshot.relationships.filter {
            $0.type == .parent && $0.to == profile.id
        }
        // 0 or 1 parent is always fine (a lone placeholder is the legitimate
        // unknown-couple stand-in).
        guard parentEdges.count > 1 else { return [] }

        // Junk = anonymous stub parents (blank/placeholder), by the SAME
        // predicate `PlaceholderParentRepair` uses, so the finding and the
        // repair can never disagree about what to strip. A dangling edge to a
        // missing profile also counts as junk to remove.
        let junkParentIDs = parentEdges
            .map(\.from)
            .filter { snapshot.profiles[$0]?.isAnonymousStub ?? true }
        let hasNamedParent = parentEdges.contains {
            guard let parent = snapshot.profiles[$0.from] else { return false }
            return !parent.isAnonymousStub
        }

        // ERROR: structurally impossible parent count. The remedy differs by
        // cause: blank/anonymous stubs are junk to remove; all-named excess is a
        // duplicate or bad merge that needs a human to pick the right parent.
        if parentEdges.count > 2 {
            let placeholderNote = junkParentIDs.isEmpty
                ? ""
                : " (including \(junkParentIDs.count) blank placeholder\(junkParentIDs.count == 1 ? "" : "s"))"
            let remedy = junkParentIDs.isEmpty
                ? "Review which parent is correct — likely a duplicate or bad merge."
                : "Remove the junk placeholder parents."
            return [AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .error, ruleID: id,
                message: "\(profile.displayName) has \(parentEdges.count) parent edges\(placeholderNote) — a person has at most two. \(remedy)",
                relatedProfileIDs: junkParentIDs.isEmpty ? nil : junkParentIDs
            )]
        }

        // WARNING: a placeholder parent is redundant next to a real one — the
        // fingerprint of a bad sibling link that didn't overflow past two.
        if !junkParentIDs.isEmpty && hasNamedParent {
            return [AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) has a blank placeholder parent alongside a named parent — likely a stray placeholder from a bad sibling link.",
                relatedProfileIDs: junkParentIDs
            )]
        }

        return []
    }
}

/// Reconciles the family relationships a CENSUS HOUSEHOLD implies against the
/// tree. Surfaces CONTRADICTIONS — the census names a relative already in the
/// tree, but in a different role (e.g. two people the census lists as siblings
/// are linked in the tree as parent and child). Detection is delegated to the
/// pure `CensusRelationshipReconciler`; that engine also detects census
/// relatives entirely MISSING from the tree, which a later stage will surface
/// alongside a one-click "add from census" so they are actionable rather than
/// noise. Heuristic (name + age matching, scoped to the subject's own
/// relatives) → a reviewable warning, never an auto-fix.
public nonisolated struct CensusRelationshipRule: AuditRuleDefinition {
    public let id = "censusRelationship"
    public let displayName = "Census Relationship Mismatch"
    public let description = "A census household implies a family relationship that the tree records differently — e.g. two people a census lists as siblings are linked in the tree as parent and child."
    public let fireCondition = "A census household names a relative of the subject who is already in the tree, but in a different role than the census implies."
    public let warningCondition: String? = "Census-implied role (parent/child/spouse/sibling) disagrees with the tree edge for the same person."
    public let workedExample = "Samuel Wheeldon's 1861 census lists Mary as a daughter alongside him (a son) — making them siblings — but the tree records Samuel as Mary's father → contradiction."
    public let defaultSeverity = Severity.warning
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let findings = CensusRelationshipReconciler.findings(for: profile, in: snapshot)
        var results: [AuditResult] = []

        // Contradictions — one reviewable warning each; never auto-fixed.
        for finding in findings where finding.kind == .contradiction {
            results.append(AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .issue, ruleID: id,
                message: Self.contradictionMessage(subject: profile, finding: finding),
                relatedProfileIDs: finding.treeRelativeID.map { [$0] }))
        }

        // Missing relatives + parent-in-law leads — one info summary per subject
        // (a `.gap`), carrying the census-reconciliation panel (per-row "Add") in
        // the Health view. Grouped so a big household is one row, not one per
        // absent relative. A household with no missing blood relative can still
        // surface here on the strength of an in-law lead alone (a mother-in-law
        // pins the spouse's maiden name and parent — a lot from one line).
        let missing = findings.filter { $0.kind == .missing }
        let unlinked = CensusRelationshipReconciler.unlinkedRelatives(for: profile, in: snapshot)
        let inLawLeads = CensusRelationshipReconciler.inLawLeads(for: profile, in: snapshot)
        if !missing.isEmpty || !unlinked.isEmpty || !inLawLeads.isEmpty {
            results.append(AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .gap, ruleID: id,
                message: Self.gapMessage(subject: profile, missing: missing,
                                         unlinked: unlinked, inLaw: inLawLeads)))
        }
        return results
    }

    /// "The 1861 census records Mary Wheeldon as Samuel's sibling, but the tree
    /// has them as Samuel's child. Reconcile before trusting either."
    static func contradictionMessage(subject: Profile, finding: CensusRelationshipReconciler.Finding) -> String {
        let who = finding.member.name
        let subjectName = subject.firstName ?? subject.displayName
        let censusWord = relationPhrase(finding.censusRelation)
        let treeWord = finding.treeRelation.map(relationPhrase) ?? "a different relative"
        let lead = finding.censusYear.map { "The \($0) census" } ?? "A census"
        return "\(lead) records \(who) as \(subjectName)'s \(censusWord), but the tree has them as \(subjectName)'s \(treeWord). Reconcile before trusting either."
    }

    /// "A census lists 2 of Samuel's relatives not in the tree: Hannah Wheeldon
    /// (sibling), Alice Wheeldon (sibling)."
    /// Combined gap summary: missing blood relatives to create, relatives already
    /// in the tree but unlinked, and parent-in-law leads — each its own sentence.
    static func gapMessage(subject: Profile,
                           missing: [CensusRelationshipReconciler.Finding],
                           unlinked: [CensusRelationshipReconciler.UnlinkedRelative],
                           inLaw: [CensusRelationshipReconciler.InLawLead]) -> String {
        var parts: [String] = []
        if !missing.isEmpty { parts.append(missingMessage(subject: subject, missing: missing)) }
        if !unlinked.isEmpty { parts.append(unlinkedMessage(subject: subject, unlinked: unlinked)) }
        if !inLaw.isEmpty { parts.append(inLawMessage(subject: subject, inLaw: inLaw)) }
        return parts.joined(separator: " ")
    }

    /// "A census names 1 of Kezia's relatives already in the tree but not linked:
    /// Mary Lizzy Wheeldon (sibling)."
    static func unlinkedMessage(subject: Profile,
                                unlinked: [CensusRelationshipReconciler.UnlinkedRelative]) -> String {
        let subjectName = subject.firstName ?? subject.displayName
        let list = unlinked.map { "\($0.member.name) (\(relationPhrase($0.relation)))" }.joined(separator: ", ")
        let n = unlinked.count
        return "A census names \(n) of \(subjectName)'s relatives already in the tree but not linked: \(list)."
    }

    /// "A census names Martha Barker (mother-in-law) — she pins Elizabeth's
    /// parent and maiden name (Barker)."
    static func inLawMessage(subject: Profile,
                             inLaw: [CensusRelationshipReconciler.InLawLead]) -> String {
        let subjectName = subject.firstName ?? subject.displayName
        let list = inLaw.map { lead -> String in
            let word = lead.kind == .mother ? "mother-in-law" : "father-in-law"
            let surname = lead.member.name.split(separator: " ").last.map(String.init)
            let maiden = surname.map { ", maiden name \($0)" } ?? ""
            return "\(lead.member.name) (\(word)\(maiden))"
        }.joined(separator: ", ")
        let n = inLaw.count
        return "A census names \(subjectName)'s \(n == 1 ? "" : "\(n) ")in-law\(n == 1 ? "" : "s") who pin a spouse's parent: \(list)."
    }

    static func missingMessage(subject: Profile, missing: [CensusRelationshipReconciler.Finding]) -> String {
        let subjectName = subject.firstName ?? subject.displayName
        let list = missing.map { f -> String in
            let yr = f.member.birthYear ?? f.censusYear.flatMap { y in f.member.age.map { y - $0 } }
            let yrText = yr.map { ", b.\($0)" } ?? ""
            return "\(f.member.name) (\(relationPhrase(f.censusRelation))\(yrText))"
        }.joined(separator: ", ")
        let n = missing.count
        // "N of X's relatives" is plural regardless of N (one OF a plural pool).
        return "A census lists \(n) of \(subjectName)'s relatives not in the tree: \(list)."
    }

    private static func relationPhrase(_ r: CensusRelation) -> String {
        switch r {
        case .parent:  return "parent"
        case .child:   return "child"
        case .spouse:  return "spouse"
        case .sibling: return "sibling"
        }
    }
}

// MARK: - Empty Profile (orphaned debris)

/// Fires on a profile that carries no information at all — blank name, no birth
/// or death date, and no relationships. These are orphaned stubs, typically the
/// dead remains of a bad merge or the sibling-shortcut placeholder bug (owner
/// report 2026-07-16: four blank stubs left behind after their parent edges were
/// stripped). They can't be researched (no identity to search) and connect to
/// nothing, so they're safe to delete. Distinct from `OrphanStubRule`, which
/// needs a NAME match to fire and so misses fully-nameless orphans.
public nonisolated struct EmptyProfileRule: AuditRuleDefinition {
    public let id = "emptyProfile"
    public let displayName = "Empty Profile"
    public let description = "A profile with no identifying given name (a bare surname or \"?\"), no dates, and no relationships — orphaned debris, safe to remove."
    public let fireCondition = "No meaningful given name AND no birth/death date AND no relationship edges."
    public let warningCondition: String? = nil
    public let workedExample = "A lone \" Wheeldon\" (surname only) left orphaned after its one bad parent-link was removed — no dates, no family."
    public let defaultSeverity = Severity.warning
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // "Identifiable" means a real given name — a bare surname or a "?" tells
        // you nothing about who the person is. Strip "?"/whitespace so both
        // surname-only and "?"-named stubs count as empty.
        func meaningful(_ s: String?) -> Bool {
            !(s ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ?")).isEmpty
        }
        let hasGivenName = meaningful(profile.firstName) || meaningful(profile.middleName)
        guard !hasGivenName, profile.birthDate == nil, profile.deathDate == nil else { return [] }
        // Must be an orphan. A surname-only person who is LINKED (e.g. an
        // unknown-given-name spouse or parent) is a legitimate placeholder that
        // holds real structure — not debris.
        let hasRelationships = snapshot.relationships.contains {
            $0.from == profile.id || $0.to == profile.id
        }
        guard !hasRelationships else { return [] }
        return [AuditResult(
            profileID: profile.id,
            profileName: profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "(empty profile)" : profile.displayName,
            severity: .warning, ruleID: id,
            message: "Empty profile — no given name, dates, or relationships (a bare surname or \"?\" stub). Safe to remove (orphaned debris)."
        )]
    }
}

// MARK: - Conflict-layer wrappers (CONFLICT_LAYER_SPEC CL2)

/// F4a as an audit rule — thin wrapper over
/// `ConflictPredicates.duplicateBiologicalParentEdges` so the audit pass
/// and the conflict sweep can never disagree (CL2 AC2, DS-26).
public nonisolated struct ParentsPerRoleRule: AuditRuleDefinition {
    public let id = "parentsPerRole"
    public let displayName = "One Biological Parent Per Role"
    public let description = "A profile must not have two biological fathers or two biological mothers."
    public let fireCondition = "≥2 biological parent edges with the same role pointing at distinct profiles."
    public let warningCondition: String? = nil
    public let workedExample = "Two accepted mother proposals → two biological mother edges → error."
    public let defaultSeverity = Severity.error
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let duplicates = ConflictPredicates.duplicateBiologicalParentEdges(
            subjectID: profile.id, relationships: snapshot.relationships)
        return duplicates.map { role, edges in
            let names = edges.compactMap { snapshot.profiles[$0.from]?.displayName }
                .joined(separator: ", ")
            return AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: defaultSeverity, ruleID: id,
                message: "Two biological \(role.rawValue)s: \(names). One person has one biological \(role.rawValue).",
                relatedProfileIDs: edges.map(\.from)
            )
        }
    }
}

/// F3 as an audit rule — thin wrapper over `ConflictPredicates.aliveEvidence`
/// so the audit pass and the conflict sweep share the death-vs-later-alive
/// predicate (CL2 AC1/AC2, DS-15). Reads life events from the snapshot;
/// snapshots built without life events never fire (no false positives).
public nonisolated struct RecordAfterDeathRule: AuditRuleDefinition {
    public let id = "recordAfterDeath"
    public let displayName = "Record After Death"
    public let description = "Alive-evidence (census, residence, occupation, military, religion) dated after the profile's death."
    public let fireCondition = "deathDate.latest < year of any alive-evidence life event."
    public let warningCondition: String? = nil
    public let workedExample = "Death 1905 but an accepted 1911 census life event → error."
    public let defaultSeverity = Severity.error
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let deathYear = profile.deathDate?.latest else { return [] }
        let events = snapshot.lifeEvents[profile.id] ?? []
        let later = ConflictPredicates.aliveEvidence(afterYear: deathYear, in: events)
        guard !later.isEmpty else { return [] }
        let detail = later
            .map { "\($0.event.type.rawValue) \($0.year)" }
            .joined(separator: ", ")
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: defaultSeverity, ruleID: id,
            message: "Death \(deathYear) contradicted by later alive-evidence: \(detail)."
        )]
    }
}


/// IMPORT_DEDUPE_SPEC Change 1 — surfaces orphan-stub duplicates (a
/// profile with no relationship edges whose name matches an edge-bearing
/// profile). Complements `DuplicateDetectionRule`: that rule needs
/// birth-year overlap to reach 0.7 and misses surname-only stubs entirely
/// (the Ancestry "Carter" case). Thin wrapper over `OrphanStubDetector`
/// so the Audit tab and the import-time cleanse can never disagree.
public nonisolated struct OrphanStubRule: AuditRuleDefinition {
    public let id = "orphanStub"
    public let displayName = "Orphan Duplicate Records"
    public let description = "A profile with no relationships that shares a name with a linked profile — often a duplicate stub left by a GEDCOM export (e.g. Ancestry.com merges)."
    public let fireCondition = "Zero relationship edges AND name-identical to an edge-bearing profile."
    public let warningCondition: String? = nil
    public let workedExample = "A bare 'Carter' with no dates or family, next to the linked Carter who is Betsy Cauldwell's husband."
    public let defaultSeverity = Severity.warning
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // One row per (this-stub, target) candidate; only report when THIS
        // profile is the stub (avoids double-reporting from the target side).
        OrphanStubDetector.candidates(in: snapshot)
            .filter { $0.stubID == profile.id }
            .map { candidate in
                let emptyNote = candidate.stubIsEmpty ? " (empty — safe to remove)" : ""
                return AuditResult(
                    profileID: profile.id, profileName: profile.displayName,
                    severity: defaultSeverity, ruleID: id,
                    message: "Possible orphan duplicate: \(candidate.matchBasis)\(emptyNote).",
                    relatedProfileIDs: [candidate.targetID])
            }
    }
}

/// IMPORT_DEDUPE_SPEC Change 4 — surfaces phantom-spouse stubs (a dateless,
/// evidence-free profile whose ONLY edge is a single spouse-link to a real
/// person). The one spouse-edge disqualifies these from `OrphanStubRule`'s
/// zero-edge cleanse, yet they are the same duplicate debris — extra
/// husbands/wives left by a GEDCOM merge. Thin wrapper over
/// `PhantomSpouseDetector` so the Audit tab, the on-demand scan, and the guided
/// cleanse card can never disagree.
public nonisolated struct PhantomSpouseRule: AuditRuleDefinition {
    public let id = "phantomSpouse"
    public let displayName = "Phantom Spouse Duplicates"
    public let description = "A dateless, evidence-free profile whose only link is a marriage to a real person — usually a duplicate of that person's real spouse, left by a GEDCOM merge."
    public let fireCondition = "Empty (name only — no dates, locations, or bio) AND exactly one relationship edge, which is a spouse-link."
    public let warningCondition: String? = nil
    public let workedExample = "Gerty — no dates or records, sole edge a marriage to William Henry Keyworth — a fragment of his real second wife, Elizabeth Wallace."
    public let defaultSeverity = Severity.warning
    public let category: AuditCategory = .issue
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        // One row per phantom; only report when THIS profile is the phantom.
        PhantomSpouseDetector.candidates(in: snapshot)
            .filter { $0.phantomID == profile.id }
            .map { candidate in
                let anchorName = snapshot.profiles[candidate.anchorID]?.displayName ?? "a linked person"
                let targetClause: String
                if let targetID = candidate.suggestedTargetID,
                   let targetName = snapshot.profiles[targetID]?.displayName {
                    targetClause = " — likely the same person as \(targetName)"
                } else if !candidate.documentedSpouseIDs.isEmpty {
                    let names = candidate.documentedSpouseIDs
                        .compactMap { snapshot.profiles[$0]?.displayName }
                    targetClause = names.isEmpty ? ""
                        : " — likely a duplicate of \(anchorName)'s documented spouse (\(names.joined(separator: " or ")))"
                } else {
                    targetClause = ""   // anchor has no documented spouse — pure manual review
                }
                // Implicated IDs: the anchor, then the suggested target or the
                // full documented set, so the Tasks/cleanse surfaces can act
                // without re-parsing the message.
                let related = [candidate.anchorID]
                    + (candidate.suggestedTargetID.map { [$0] } ?? candidate.documentedSpouseIDs)
                return AuditResult(
                    profileID: profile.id, profileName: profile.displayName,
                    severity: defaultSeverity, category: .issue, ruleID: id,
                    message: "\(profile.displayName) has no dates or records and only exists as a marriage link to \(anchorName)\(targetClause).",
                    relatedProfileIDs: related)
            }
    }
}

// MARK: - Birth Year From Census

/// A relative with no birth year whose age appears in a *linked* family
/// member's applied census — the birth year can be calculated (`censusYear −
/// age`, ±1). This is the "linked → enrich" half of census-roster absorption,
/// surfaced as a persistent Tasks entry with a one-click fix rather than only
/// inside a research review. Gap-fill only, and it reuses
/// `CensusAgeEnrichment`'s two-way-unique matching so an ambiguous "two Johns"
/// household is skipped, not guessed.
public nonisolated struct CensusAgeBirthYearRule: AuditRuleDefinition {
    // `.issue`, not `.gap`: the Tasks view routes `.gap` findings out (they
    // duplicate the completeness Gaps view). This one carries a concrete,
    // one-click action, so it belongs in Tasks.
    public let id = "censusAgeBirthYear"
    public let category: AuditCategory = .issue
    public let displayName = "Birth Year From Census"
    public let description = "A relative with no birth year appears, with an age, in a linked family member's census — the year can be calculated."
    public let fireCondition = "birthDate is empty AND the profile appears (by name, with an age) in a linked relative's applied census household."
    public let warningCondition: String? = nil
    public let workedExample = "John Cauldwell has no birth year but appears as 'Head, age 30' in his son Ernest's 1891 census → calculated birth year ~1861."
    public let defaultSeverity = Severity.warning
    public init() {}

    /// The calculated year, the census it came from, and the relative whose
    /// census carried it — nil when the rule doesn't apply. Shared by the rule
    /// and the Tasks one-click so the finding and the fix can't disagree.
    public static func suggestion(for profile: Profile, in snapshot: FamilyGraphSnapshot)
        -> (year: Int, censusYear: Int, viaName: String, sourceID: String?)? {
        // Only ever fill an EMPTY birth year.
        guard profile.birthDate?.bestYear == nil else { return nil }

        // Each census-owning relative, tagged with how THIS profile relates to
        // them (the subject): the profile is a parent's child, a child's
        // parent, a sibling's sibling, a spouse's spouse. That tag lets the
        // engine break a "two Johns" roster tie by role.
        var relatives: [(via: Profile, relation: CensusRelation)] = []
        relatives += snapshot.parentsOf(profile.id).map { ($0, CensusRelation.child) }
        relatives += snapshot.childrenOf(profile.id).map { ($0, CensusRelation.parent) }
        relatives += snapshot.siblingsOf(profile.id).map { ($0, CensusRelation.sibling) }
        relatives += snapshot.spousesOf(profile.id).map { ($0, CensusRelation.spouse) }
        for (via, relation) in relatives {
            for event in snapshot.lifeEvents[via.id] ?? [] where event.type == .census {
                guard case .census(let details)? = event.details,
                      !details.household.isEmpty,
                      let censusYear = event.date?.bestYear else { continue }
                // Ask the shared engine whether THIS profile is an unambiguous
                // match in `via`'s roster (subject = via, candidate = profile).
                let proposals = CensusAgeEnrichment.proposals(
                    subjectID: via.id, household: details.household,
                    censusYear: censusYear, linkedRelatives: [profile],
                    sourceID: event.sources.first?.origin.identifier,
                    relations: [profile.id: relation])
                if let p = proposals.first {
                    return (p.estimatedBirthYear, censusYear, via.displayName, p.sourceID)
                }
            }
        }
        return nil
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let s = Self.suggestion(for: profile, in: snapshot) else { return [] }
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .warning, category: .issue, ruleID: id,
            message: "\(profile.displayName) has no birth year, but appears in \(s.viaName)'s \(s.censusYear) census — their age gives a calculated birth year of ~\(s.year).")]
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "Set \(profile.displayName)'s birth year from their age in a linked relative's census."
    }
}
