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

    /// Numeric thresholds the user can tune (M18, the design). Rules
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
        SiblingIdentityCollisionRule(),
        ExcessParentEdgesRule(),
        CensusRelationshipRule(),
        CitedCensusWithoutEventRule(),
        MissingCoParentRule(),
        EmptyProfileRule(),
        CompletenessScoreRule(),
        ParentDiedBeforeChildRule(),
        ParentSuspiciouslyOldRule(),
        SelfSpouseRule(),
        UnsourcedBioRule(),
        MissingDeathLocationRule(),
        DatelessReadsAsLivingRule(),
        AncestorExtensionRule(),
        UnlinkedSpouseForFemaleSubjectRule(),
        MarriedSurnameFromSpouseRule(),
        CensusAgeBirthYearRule(),
        GivenNameContainsMiddleRule(),
        JunkInNameRule(),
        IncompleteNameRule(),
        SuspectLocationRule(),
        FertilityGapRule(),
        RivalBirthRegistrationsRule(),
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
    public let category: AuditCategory = .research
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
            severity: .info, category: .research, ruleID: id,
            message: "\(display) — \(reason). Add the missing part, or research it (a surname-only spouse often needs a maiden name)."
        )]
    }
}

// MARK: - Dateless — Reads As Living

/// A profile with NO dates at all is treated as "possibly living" by the
/// completeness heuristic (an unbounded birth can't rule out being alive), so
/// it gets privacy treatment and is skipped by living-person guards — even
/// when the surrounding family makes a Victorian birth certain. Live specimen
/// (owner dogfood 2026-07-30): the dateless sister Elizabeth Keyworth read
/// "(living)" though her brother was born 1875. This rule infers a
/// conservative "born no later than" bound from family anchors — siblings
/// (+20), spouse (+20), children (−14) — and flags dateless profiles whose
/// bound is more than 100 years ago (the same threshold the living heuristic
/// itself uses).
public nonisolated struct DatelessReadsAsLivingRule: AuditRuleDefinition {
    public let id = "datelessReadsAsLiving"
    public let category: AuditCategory = .gap
    public let displayName = "Dateless — Reads As Living"
    public let description = "A profile with no dates is treated as possibly living, but family dates prove a birth more than a century ago."
    public let fireCondition = "No birth AND no death date, and siblings/spouse/children imply birth no later than 100 years ago."
    public let warningCondition: String? = nil
    public let workedExample = "Elizabeth Keyworth (no dates) shows \u{201C}living\u{201D}, but brother William Henry was born 1875 — she was born no later than ~1895."
    public let defaultSeverity = Severity.warning
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard profile.birthDate == nil, profile.deathDate == nil else { return [] }
        guard let bound = Self.bornNoLaterThan(profile: profile, snapshot: snapshot) else { return [] }
        let currentYear = Calendar.current.component(.year, from: Date())
        guard bound.year + 100 < currentYear else { return [] }
        let display = profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "(unnamed)" : profile.displayName
        return [AuditResult(
            profileID: profile.id, profileName: display,
            severity: .warning, category: .gap, ruleID: id,
            message: "\(display) — no dates recorded, so they read as possibly living; but \(bound.anchor) means they were born no later than ~\(bound.year), over a century ago. Add an estimated birth or death year so privacy and research treat them correctly."
        )]
    }

    /// Conservative latest-plausible birth year from family anchors, with the
    /// anchor that produced the tightest bound. Nil when no dated relatives.
    static func bornNoLaterThan(profile: Profile, snapshot: FamilyGraphSnapshot) -> (year: Int, anchor: String)? {
        var bounds: [(year: Int, anchor: String)] = []
        let siblingYears = snapshot.siblingsOf(profile.id).compactMap { $0.birthDate?.bestYear }
        if let latest = siblingYears.max() {
            bounds.append((latest + 20, "a sibling born \(latest)"))
        }
        let spouseYears = snapshot.spousesOf(profile.id).compactMap { $0.birthDate?.bestYear }
        if let latest = spouseYears.max() {
            bounds.append((latest + 20, "a spouse born \(latest)"))
        }
        let childYears = snapshot.childrenOf(profile.id).compactMap { $0.birthDate?.bestYear }
        if let earliest = childYears.min() {
            bounds.append((earliest - 14, "a child born \(earliest)"))
        }
        return bounds.min { $0.year < $1.year }
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
    public let category: AuditCategory = .research
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
                severity: .info, category: .research, ruleID: id,
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
    public let description = "A profile whose birth or death evidence spans more years than one person's could — usually a conflicting or namesake date has been applied (sometimes two same-named relatives were merged onto one node)."
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
                message: "\(profile.displayName) — \(label.lowercased()) date needs checking: attestations span \(earliest)–\(latest) (\(latest - earliest) years), recorded as '\(date.original)'. That's too wide for one person — a conflicting or namesake \(label.lowercased()) record is likely applied."
            ))
        }
        return results
    }
}

// MARK: - Rival Birth Registrations (two GRO entries on one birth)

/// Two or more DIFFERENT civil-registration birth entries cited on the same
/// profile's birth date. A person is registered once, so whichever entry is
/// theirs the others belong to somebody else — a namesake absorbed onto the
/// profile. Live specimen (owner dogfood 2026-08-25): Emma Gladwin held both
/// Dec 1867 (7b/513) and Dec 1865 (7b/515) as cited birth dates at once.
///
/// The confirmed-facts twin of `ContradictoryFactsAudit`, which contests the
/// evidence store. A cited fact can reach `field_sources` by paths that leave
/// no scoring row behind — the firewall's pending-facts queue, an import
/// carrying its own citation — and no exclusivity pass can demote a rival it
/// cannot see. This rule reads only what is ON the profile, so it holds
/// whatever the evidence store does or doesn't remember.
///
/// Index TWINS are not rivals: one registration is indexed under several row
/// ids, so entries group by the same registration identity the scorer's own
/// exclusivity pass uses (`RecordScorer.isSameRegistration`): quarter +
/// district + volume + page, tolerant of a citation that omits a component.
public nonisolated struct RivalBirthRegistrationsRule: AuditRuleDefinition {
    public init() {}

    public let id = "rivalBirthRegistrations"
    public let category: AuditCategory = .issue
    public let displayName = "Rival Birth Registrations"
    public let description = "Two or more different GRO birth-index entries are cited on one profile's birth date — but a person is registered once."
    public let fireCondition = "birthDate carries cited birth-index references identifying 2+ distinct registrations (quarter + district + volume/page)."
    public let warningCondition: String? = nil
    public let workedExample = "Emma Gladwin's birth date cited both \u{201C}Dec 1867, Belper, vol. 7b/513\u{201D} and \u{201C}Dec 1865, Belper, vol. 7b/515\u{201D} — two babies, one profile."
    public let defaultSeverity = Severity.error

    /// One cited GRO birth-index entry: the volume/page that identifies the
    /// registration, and the value the citing fact put on the profile.
    public struct Registration: Sendable, Equatable {
        public let reference: String    // normalised "7b/513"
        public let value: String
    }

    /// The DISTINCT birth registrations cited on a profile's birth date, in
    /// first-seen order. Shared by the rule and any fix that resolves it, so
    /// the finding and the action can never disagree about which entries rival.
    ///
    /// EV1-14 follow-up (review M3): vol/page ALONE is not a registration
    /// identity — FreeBMD volume/page numbering restarts every quarter, so
    /// "Dec 1865, Chesterfield, vol. 7b/513" and "Jun 1868, Chesterfield,
    /// vol. 7b/513" are two different babies, and one district's page range
    /// can collide with another's inside a quarter. Identity here mirrors
    /// `RecordScorer.isSameRegistration` (type + quarter + district + vol +
    /// page): entries sharing a vol/page are ONE registration unless a
    /// discriminator — quarter, year, or district — is present on BOTH sides
    /// and differs. A citation that OMITS a discriminator cannot be told apart
    /// on that basis and is never split off for the omission.
    public static func registrations(for profile: Profile) -> [Registration] {
        struct Entry {
            let reference: String
            var quarter: Int?
            var year: Int?
            var district: String?
            let value: String
        }
        var entries: [Entry] = []
        for source in profile.sources[.birthDate] ?? [] {
            guard let text = birthRegistrationCitationText(source),
                  let match = volumePageMatch(in: text) else { continue }
            let raw = source.raw.trimmingCharacters(in: .whitespaces)
            // Quarter/year from the short VALUE string first — citation prose
            // also carries an access date ("accessed 21 Jul 2026") and the
            // collection's nominal year, either of which would poison a
            // prose-wide scan. The citation's own date component (read
            // shape-anchored beside the vol/page) fills in for an unstated one.
            let shape = citedDateAndDistrict(in: text, before: match.range)
            var (quarter, year) = quarterYear(in: raw)
            if quarter == nil { quarter = shape.quarter }
            if year == nil { year = shape.year }
            let candidate = Entry(
                reference: match.reference, quarter: quarter, year: year,
                district: shape.district,
                value: raw.isEmpty ? "unstated date" : raw)
            if let i = entries.firstIndex(where: { existing in
                existing.reference == candidate.reference
                    && !conflicts(existing.quarter, candidate.quarter)
                    && !conflicts(existing.year, candidate.year)
                    && !conflicts(existing.district, candidate.district)
            }) {
                // The same registration seen through another index row — adopt
                // any discriminator this row carries that the first sighting
                // lacked, so later rows are judged against the fullest identity.
                if entries[i].quarter == nil { entries[i].quarter = candidate.quarter }
                if entries[i].year == nil { entries[i].year = candidate.year }
                if entries[i].district == nil { entries[i].district = candidate.district }
            } else {
                entries.append(candidate)
            }
        }
        return entries.map { Registration(reference: $0.reference, value: $0.value) }
    }

    /// Omission-tolerant inequality: a discriminator separates two entries only
    /// when BOTH sides carry it — mirroring `RecordScorer.isSameRegistration`'s
    /// quarter handling.
    private static func conflicts<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
        guard let a, let b else { return false }
        return a != b
    }

    /// The `volume/page` of a field source's citation when that citation is a
    /// civil-registration BIRTH index entry. Nil for anything else: a baptism
    /// carries no vol/page at all, and a death or marriage reference that
    /// reached the birth date (an age-at-death backfill cites the DEATH) is not
    /// a rival birth registration.
    static func birthRegistrationReference(_ source: FieldSource) -> String? {
        birthRegistrationCitationText(source).flatMap { volumePageMatch(in: $0)?.reference }
    }

    /// The citation's searchable text when it cites a civil-registration BIRTH
    /// index entry; nil for anything else (baptism/christening, or a death or
    /// marriage reference that reached the birth date).
    static func birthRegistrationCitationText(_ source: FieldSource) -> String? {
        guard let citation = source.citation else { return nil }
        let text = [citation.collection, citation.title, citation.page, citation.notes]
            .compactMap { $0 }.joined(separator: " ")
        let lower = text.lowercased()
        guard lower.contains("birth") else { return nil }
        guard !lower.contains("baptis"), !lower.contains("christen") else { return nil }
        return text
    }

    /// "vol. 7b/513" (rendered citations) or "Volume 7b, page 513" (hand-entered
    /// ones) → "7b/513". Nil when the text carries no index reference.
    static func volumePage(in text: String) -> String? {
        volumePageMatch(in: text)?.reference
    }

    /// The vol/page reference and WHERE it sits in the text — the range lets
    /// `citedDateAndDistrict` anchor on the citation's own rendered shape
    /// rather than scanning prose (review M3).
    static func volumePageMatch(in text: String) -> (reference: String, range: NSRange)? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let patterns = [
            #"vol\.?\s*([0-9]+[a-z]?)\s*/\s*([0-9]+[a-z]?)"#,
            #"volume\s*([0-9]+[a-z]?)\s*,?\s*(?:page|pp?\.)\s*([0-9]+[a-z]?)"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: whole), m.numberOfRanges == 3 else { continue }
            let ref = (ns.substring(with: m.range(at: 1)) + "/" + ns.substring(with: m.range(at: 2))).lowercased()
            return (ref, m.range)
        }
        return nil
    }

    /// The date component and district a citation names beside its vol/page
    /// reference, read from the app's own rendered shapes:
    ///   "…, <name>, Dec 1867, Belper, vol. 7b/513; accessed …"
    ///   "…, Belper registration district, March quarter 1834, volume 7b, page 213"
    /// Of the two comma-separated components immediately before the reference,
    /// exactly one parses as a quarter/year; the other — all letters — is the
    /// district. Any other shape yields nils: a discriminator we cannot read
    /// stays non-discriminating (omission tolerance), never guessed from prose
    /// — no hardcoded place names, only the renderer's own field order.
    static func citedDateAndDistrict(
        in text: String, before matchRange: NSRange
    ) -> (quarter: Int?, year: Int?, district: String?) {
        let prefix = (text as NSString).substring(to: matchRange.location)
        let comps = prefix.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard comps.count >= 2 else { return (nil, nil, nil) }
        let last = comps[comps.count - 1]
        let prev = comps[comps.count - 2]
        let lastDate = quarterYear(in: last)
        let prevDate = quarterYear(in: prev)
        let date: (quarter: Int?, year: Int?)
        let place: String
        switch (lastDate.quarter != nil || lastDate.year != nil,
                prevDate.quarter != nil || prevDate.year != nil) {
        case (false, true): date = prevDate; place = last     // "…, Dec 1867, Belper, vol. …"
        case (true, false): date = lastDate; place = prev     // "…, Belper registration district, March quarter 1834, volume …"
        default: return (nil, nil, nil)
        }
        var district = place.lowercased()
        if district.hasSuffix(" registration district") {
            district = String(district.dropLast(" registration district".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard !district.isEmpty, district.allSatisfy({
            $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" || $0 == "." || $0 == "&"
        }) else { return (date.quarter, date.year, nil) }
        return (date.quarter, date.year, district)
    }

    /// The GRO quarter (1–4) and year in a short date string — "Dec 1865" →
    /// (4, 1865), "Q4 1867" → (4, 1867), "March quarter 1834" → (1, 1834),
    /// "CAL 1866" → (nil, 1866). Word-bounded month tokens, so a district like
    /// "Marylebone" never reads as March.
    static func quarterYear(in text: String) -> (quarter: Int?, year: Int?) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let monthsByToken: [String: Int] = [
            "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
            "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
            "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
        ]
        var quarter: Int?
        let monthPattern = #"\b("#
            + monthsByToken.keys.sorted { $0.count > $1.count }.joined(separator: "|")
            + #")\b"#
        if let re = try? NSRegularExpression(pattern: monthPattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: whole),
           let month = monthsByToken[ns.substring(with: m.range(at: 1)).lowercased()] {
            quarter = (month + 2) / 3      // GRO quarters end Mar/Jun/Sep/Dec
        } else if let re = try? NSRegularExpression(pattern: #"\bq([1-4])\b"#, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: whole) {
            quarter = Int(ns.substring(with: m.range(at: 1)))
        }
        var year: Int?
        if let re = try? NSRegularExpression(pattern: #"\b(1[5-9][0-9]{2}|20[0-9]{2})\b"#),
           let m = re.firstMatch(in: text, range: whole) {
            year = Int(ns.substring(with: m.range(at: 1)))
        }
        return (quarter, year)
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let registrations = Self.registrations(for: profile)
        guard registrations.count > 1 else { return [] }
        let listed = registrations
            .map { "\($0.value) (vol. \($0.reference))" }
            .joined(separator: " vs ")
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .error, category: .issue, ruleID: id,
            message: "\(profile.displayName) — \(registrations.count) different birth registrations are cited on the birth date: \(listed). A birth is registered once, so at most one is theirs; keep the corroborated entry and send the rest back to leads."
        )]
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
    public let category: AuditCategory = .research
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
                severity: .warning, category: .research, ruleID: id,
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
    public let category: AuditCategory = .research
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
                severity: .warning, category: .research, ruleID: id,
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
    public let category: AuditCategory = .research
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
                severity: .info, category: .research, ruleID: id,
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
    public let category: AuditCategory = .research
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
                severity: .warning, category: .research, ruleID: id,
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
    public let category: AuditCategory = .research
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
                severity: .info, category: .research, ruleID: id,
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
            if Self.hasDirectParentChildEdge(profile.id, otherID, snapshot: snapshot) {
                continue
            }

            let score = similarityScore(profile, other)
            if score >= Self.threshold {
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

    /// Similarity at or above which a pair is surfaced as a possible duplicate.
    /// Named (was a bare 0.7 literal) so `SiblingIdentityCollisionRule` can ask
    /// the SAME question this rule answers rather than re-deriving the number —
    /// the two rules must partition the pair space, not overlap it (EV17,
    /// 2026-08-26).
    static let threshold = 0.7

    /// Would this rule surface `a`+`b` as a possible duplicate on score alone?
    /// Public so a sibling rule can stay strictly ORTHOGONAL to this one: a pair
    /// this rule already flags must not also be flagged as a sibling identity
    /// collision, or one row becomes two (EV17, 2026-08-26). Score only — the
    /// dismissal / parent-child suppressions are applied independently by each
    /// caller, from the same snapshot.
    public static func flags(_ a: Profile, _ b: Profile) -> Bool {
        DuplicateDetectionRule().similarityScore(a, b) >= threshold
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
    ///
    /// `static` (was a private instance method) so `SiblingIdentityCollisionRule`
    /// reuses the identical predicate instead of keeping a second copy that could
    /// drift out of step with MergeSafety (EV17, 2026-08-26). Behaviour unchanged.
    static func hasDirectParentChildEdge(_ a: String, _ b: String, snapshot: FamilyGraphSnapshot) -> Bool {
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

// MARK: - Sibling Identity Collision (EV17, owner dogfood 2026-08-26)

/// Two children of the SAME parents who may be one child recorded twice under
/// two different forenames — the region `DuplicateDetectionRule` is
/// structurally blind to.
///
/// That blindness is deliberate and correct where it was written: the hard
/// forename gate (`givenSim == 0 → score 0`) exists so a Dorothy and a Florence
/// sharing a surname and a birth year are NOT proposed as duplicates, because
/// same-surname siblings are the commonest false positive on a dense tree. But
/// the gate is applied BEFORE surname (0.4) and birth-year overlap (0.3) are
/// added, and `evaluate` consults only name and birthDate — never parent edges,
/// sibship, or evidence sets. So shared parents, disjoint evidence and
/// never-co-resident contribute nothing at all, and the pair scores 0. The live
/// firing pattern confirms it: every duplicateDetection finding on the owner's
/// tree pairs SAME-forename profiles.
///
/// The gate is NOT removed. This is the separate rule covering the region it
/// excludes, and it is far stricter than duplicate detection in every other
/// axis: IDENTICAL parent sets (not "shares a parent"), same recorded sex,
/// colliding birth windows, DISJOINT evidence, and never seated on one census
/// roster. That combination is orthogonal to the known namesake over-fire —
/// those pairs have the SAME forename (this rule requires dissimilarity) and
/// DIFFERENT parents (this rule requires identity) — so it cannot worsen it.
///
/// The output is an OPEN QUESTION, never a merge proposal. "Two brothers" is a
/// legitimate resolution, and a merge here is irreversible; the rule deliberately
/// carries no `duplicateDetection` rule id, so none of the merge affordances
/// keyed on that id attach to it.
///
/// Live specimen: John H Gladwin (b. CAL 1861, known only from the 1871 roster)
/// and Thomas H Gladwin (b. 1861, known only from the 1881 roster) — same
/// parents, same sex, same birth year, disjoint evidence, never co-resident.
public nonisolated struct SiblingIdentityCollisionRule: AuditRuleDefinition {
    public let id = "siblingIdentityCollision"
    // `.issue`, not `.gap` or `.research`: if the two records are one boy the
    // tree currently holds a person who never existed — the data is WRONG, which
    // is the `.issue` definition. It is not evidence half-carried (`.gap`), and
    // it is not a prompt to go and find something (`.research`); the evidence is
    // already in hand and it is the tree's own structure that is in question.
    public let category: AuditCategory = .issue
    public let displayName = "One Child Or Two?"
    public let description = "Two children of the same parents, same sex, with colliding birth years, who appear on disjoint records and never together on any household roster the tree holds — they may be one child recorded twice."
    public let fireCondition = "Identical linked-parent sets; same recorded sex; birth windows collide; DISSIMILAR forenames (< 0.7); disjoint citation sets; never two rows of one census household; not already dismissed, not a duplicate-detection pair, no direct parent-child edge."
    public let warningCondition: String? = nil
    public let workedExample = "John H Gladwin (b. CAL 1861) appears only on the 1871 Whittington roster; Thomas H Gladwin (b. 1861) only on the 1881 Handsworth roster. Same parents, same sex, same birth year, no record ever shows both."
    public let defaultSeverity = Severity.warning
    public init() {}

    /// Forename similarity BELOW which the pair enters this rule's region.
    /// `nameSimilarity` already credits nicknames, containment and single-edit
    /// typos, so JACK/JOHN (0.85) and GLAYS/GLADYS (0.7) stay out — they are
    /// duplicate detection's business, not this rule's.
    static let dissimilarForename = 0.7

    /// Slack when two `bestYear` estimates are compared directly. One year: a
    /// census age and a registration year routinely differ by one for the same
    /// child; two would start swallowing genuine Irish-twin siblings.
    static let birthYearSlack = 1

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        Self.collisions(for: profile, in: snapshot).map { pair in
            AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .issue, ruleID: id,
                message: Self.message(a: profile, b: pair.other,
                                      aYears: pair.aYears, bYears: pair.bYears,
                                      parents: snapshot.parentsOf(profile.id)),
                relatedProfileIDs: [pair.other.id])
        }
    }

    public struct Collision: Sendable {
        public let other: Profile
        /// Census years whose household roster seats the subject.
        public let aYears: Set<Int>
        /// Census years whose household roster seats `other`.
        public let bYears: Set<Int>
    }

    /// The sibling(s) `profile` may actually BE. Reported once per pair, from
    /// the alphabetically-first id (the same convention `DuplicateDetectionRule`
    /// uses), so one question never renders as two rows.
    ///
    /// Guard order is cost-ordered on purpose: every O(1) profile-local test
    /// runs before the first graph read. The engine evaluates every rule against
    /// every profile, and `parentsOf` is a linear scan of the whole relationship
    /// array — running it per sibling on a large tree would dominate the audit.
    public static func collisions(for profile: Profile, in snapshot: FamilyGraphSnapshot) -> [Collision] {
        // A soft-deleted profile is not a live identity — neither side.
        guard !profile.isDeleted else { return [] }
        // Condition 2 — same sex, both known. `.unknown` is a recorded ABSENCE
        // of sex, and `.other` carries no discriminating signal for a Victorian
        // roster, so neither counts as "known" here.
        guard let sex = profile.gender, sex == .male || sex == .female else { return [] }
        // Condition 3 needs a real window on both sides. Two undated children of
        // one couple carry no birth-year signal at all, and an unbounded window
        // would "intersect" everything — which is how a rule like this turns
        // into tree-wide noise.
        guard profile.birthDate?.bestYear != nil else { return [] }

        let candidates = snapshot.siblingsOf(profile.id).filter { other in
            // Report once, from the alphabetically-first id.
            guard other.id > profile.id, !other.isDeleted else { return false }
            guard other.gender == sex else { return false }                 // condition 2
            guard Self.birthWindowsCollide(profile, other) else { return false }  // condition 3
            guard Self.forenamesDiffer(profile, other) else { return false }      // condition 7
            // Condition 6 — the user has already answered "different people",
            // which is the `not_duplicate_of` verdict MCP reports and the
            // `dismissed_duplicates` table stores.
            guard !snapshot.dismissedDuplicatePairs.contains(
                DuplicatePairKey(profile.id, other.id)) else { return false }
            // Condition 6 — a direct parent-child edge asserts two people.
            guard !DuplicateDetectionRule.hasDirectParentChildEdge(
                profile.id, other.id, snapshot: snapshot) else { return false }
            // Orthogonality, enforced not merely asserted: a pair duplicate
            // detection ALREADY surfaces must not surface twice. With a shared
            // surname and overlapping birth ranges that rule scores
            // 0.4 + 0.3 + 0.3·given ≥ 0.7 for ANY non-zero forename similarity,
            // so the genuinely blind region is narrower than "forename < 0.7" —
            // this hands the difference back to the rule that already owns it.
            return !DuplicateDetectionRule.flags(profile, other)
        }
        guard !candidates.isEmpty else { return [] }

        // Graph + evidence reads only once a candidate has survived the screen.
        let parents = Set(snapshot.parentsOf(profile.id).map(\.id))
        guard !parents.isEmpty else { return [] }
        let mine = Self.citedRecords(of: profile, in: snapshot)
        // Condition 4 refinement: BOTH sides must actually cite something. Two
        // uncited GEDCOM stubs have no evidence to be disjoint, and the finding's
        // own wording ("appearing on disjoint records") would be a false claim.
        guard !mine.isEmpty else { return [] }

        var out: [Collision] = []
        for other in candidates {
            // Condition 1 — IDENTICAL, not merely overlapping: neither may have a
            // parent the other lacks. `siblingsOf` only guarantees ONE shared
            // parent, which is exactly how half-siblings and step-families get
            // proposed as one person.
            guard Set(snapshot.parentsOf(other.id).map(\.id)) == parents else { continue }
            let theirs = Self.citedRecords(of: other, in: snapshot)
            guard !theirs.isEmpty, mine.isDisjoint(with: theirs) else { continue }   // condition 4
            let rosters = Self.rosterOverlap(profile, other, in: snapshot)
            guard !rosters.coResident else { continue }                              // condition 5
            out.append(Collision(other: other, aYears: rosters.aYears, bYears: rosters.bYears))
        }
        return out
    }

    /// Condition 7 — the TRIGGER. Fires on forename DISSIMILARITY, the region
    /// duplicate detection discards before it ever looks at surname or dates.
    /// A missing forename on either side is not dissimilarity: it is absence,
    /// and `IncompleteNameRule` owns that.
    static func forenamesDiffer(_ a: Profile, _ b: Profile) -> Bool {
        let ga = (a.firstName ?? "").trimmingCharacters(in: .whitespaces)
        let gb = (b.firstName ?? "").trimmingCharacters(in: .whitespaces)
        guard !ga.isEmpty, !gb.isEmpty else { return false }
        return nameSimilarity(ga, gb) < dissimilarForename
    }

    /// Condition 3 — birth-year windows intersect, OR the two best-year
    /// estimates sit within `birthYearSlack`. The second arm matters because a
    /// "CAL 1861" (±1) and a bare "1861" do intersect, but a bare "1860" and a
    /// bare "1861" do not — and a one-year gap between a census age and a
    /// registration is the commonest way one child is recorded as two.
    static func birthWindowsCollide(_ a: Profile, _ b: Profile) -> Bool {
        guard let da = a.birthDate, let db = b.birthDate,
              let ya = da.bestYear, let yb = db.bestYear else { return false }
        if abs(ya - yb) <= birthYearSlack { return true }
        let aLo = da.earliest ?? ya, aHi = da.latest ?? ya
        let bLo = db.earliest ?? yb, bHi = db.latest ?? yb
        return aLo <= bHi && bLo <= aHi
    }

    /// Every record this profile's evidence points at, as stable locators —
    /// field-source citations plus life-event sources. Condition 4 asks whether
    /// two profiles were discovered from DIFFERENT records; the locator is the
    /// unit of "a record".
    static func citedRecords(of profile: Profile, in snapshot: FamilyGraphSnapshot) -> Set<String> {
        var out: Set<String> = []
        for source in profile.sources.values.flatMap({ $0 }) {
            if let locator = recordLocator(source) { out.insert(locator) }
        }
        for event in snapshot.lifeEvents[profile.id] ?? [] {
            for source in event.sources {
                if let locator = recordLocator(source) { out.insert(locator) }
            }
        }
        return out
    }

    /// The stable identity of a cited record. When the URL carries an `ark:/…`
    /// path segment that segment IS the identity — the same FamilySearch record
    /// is reachable under several host spellings and query strings, and two
    /// spellings of one record must never read as two independent records.
    /// Otherwise the whole URL, case- and trailing-slash-normalised.
    static func recordLocator(_ source: FieldSource) -> String? {
        guard let raw = source.citation?.url?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if let ark = lower.range(of: "ark:/") { return String(lower[ark.lowerBound...]) }
        return lower.hasSuffix("/") ? String(lower.dropLast()) : lower
    }

    /// One pass over every census roster the tree holds, answering both
    /// questions the finding needs: were `a` and `b` ever seated on the SAME
    /// household as two DISTINCT rows, and which census years does each appear
    /// on at all (which is what makes the message concrete)?
    ///
    /// Rows resolve to profiles through
    /// `CensusRelationshipReconciler.matchesTreeWide` — the app's own tree-wide
    /// "is this roster row already this person?" predicate — so the audit and
    /// the census net-new guard can never disagree about who is on a roster.
    /// Deliberately the STRICT (year- or birthplace-corroborated) matcher rather
    /// than the role-scoped one that falls back to a bare name: the 1871 Gladwin
    /// household seats both "John H Gladwin" (Son, 10) and "Thomas Gladwin"
    /// (Father, 70 — the grandfather), and a name-only fallback would read the
    /// grandfather's row as Thomas H b.1861, conclude the brothers were
    /// co-resident, and silently swallow the finding this rule exists to raise.
    static func rosterOverlap(_ a: Profile, _ b: Profile, in snapshot: FamilyGraphSnapshot)
        -> (coResident: Bool, aYears: Set<Int>, bYears: Set<Int>) {
        var coResident = false
        var aYears: Set<Int> = []
        var bYears: Set<Int> = []
        for events in snapshot.lifeEvents.values {
            for event in events where event.type == .census {
                guard case .census(let details)? = event.details, !details.household.isEmpty else { continue }
                let year = event.date?.bestYear ?? event.endDate?.bestYear
                let aRows = Set(details.household.indices.filter {
                    CensusRelationshipReconciler.matchesTreeWide(
                        member: details.household[$0], profile: a, censusYear: year)
                })
                let bRows = Set(details.household.indices.filter {
                    CensusRelationshipReconciler.matchesTreeWide(
                        member: details.household[$0], profile: b, censusYear: year)
                })
                if let year {
                    if !aRows.isEmpty { aYears.insert(year) }
                    if !bRows.isEmpty { bYears.insert(year) }
                }
                // TWO DISTINCT rows — a single row that matches both is an
                // ambiguous transcription, not proof of two people at one table.
                if aRows.contains(where: { i in bRows.contains { $0 != i } }) { coResident = true }
            }
        }
        return (coResident, aYears, bYears)
    }

    /// An open question in the owner's words — never "merge these". The shape is
    /// fixed by EV17: same parents, same sex, overlapping birth windows, disjoint
    /// records, never together on a roster → one child or two?
    static func message(a: Profile, b: Profile,
                        aYears: Set<Int>, bYears: Set<Int>,
                        parents: [Profile]) -> String {
        func born(_ p: Profile) -> String {
            p.birthDate?.bestYear.map { "b.\($0)" } ?? "no birth year"
        }
        func rosterPhrase(_ p: Profile, _ years: Set<Int>) -> String? {
            guard !years.isEmpty else { return nil }
            let list = years.sorted().map { String($0) }.joined(separator: ", ")
            return "\(p.firstName ?? p.displayName) only on \(list)"
        }
        let parentNames = parents.map(\.displayName).sorted().joined(separator: " and ")
        let of = parentNames.isEmpty ? "the same parents" : parentNames
        let phrases = [rosterPhrase(a, aYears), rosterPhrase(b, bYears)].compactMap { $0 }
        let records = phrases.isEmpty
            ? "on disjoint records"
            : "on disjoint records (\(phrases.joined(separator: "; ")))"
        let siblingWord = a.gender == .female ? "Two sisters" : "Two brothers"
        return "\(a.displayName) (\(born(a))) and \(b.displayName) (\(born(b))) are both recorded as children of \(of), the same sex, with overlapping birth windows — and they appear \(records), never together on any roster the tree holds. One child or two? \(siblingWord) is a legitimate answer; establish which before merging, because a merge cannot be undone."
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

    // Nickname equivalents — checked BEFORE containment: a known pet-form
    // pair (SAM/SAMUEL, JOE/JOSEPH) is stronger evidence than raw substring
    // containment, and the containment rung's 0.8 would otherwise shadow the
    // 0.85 these pairs deserve (dedup thresholds at 0.85 — owner dogfood
    // 2026-08-14, Ernest Wheeldon's household).
    let nicknames: [String: String] = [
        "JACK": "JOHN", "JOHN": "JACK",
        "HARRY": "HENRY", "HENRY": "HARRY",
        "BILL": "WILLIAM", "WILLIAM": "BILL",
        "TED": "EDWARD", "EDWARD": "TED",
        "DICK": "RICHARD", "RICHARD": "DICK",
        "POLLY": "MARY", "MARY": "POLLY",
        "PEGGY": "MARGARET", "MARGARET": "PEGGY",
        "BETTY": "ELIZABETH", "ELIZABETH": "BETTY",
        // Sally/Sarah, Nancy/Ann, Molly/Mary — same pet-form construction as
        // the three pairs above (owner dogfood 2026-08-15: a Warslow baptism
        // indexed as "Sally Wain" was invisible to every search for SARAH).
        // MOLLY is one-way — MARY already maps to POLLY and a duplicate key
        // would crash the literal; the shared-canonical rung covers the rest.
        "SALLY": "SARAH", "SARAH": "SALLY",
        "NANCY": "ANN", "ANN": "NANCY",
        "MOLLY": "MARY",
        "NELL": "ELLEN", "ELLEN": "NELL",
        "JOE": "JOSEPH", "JOSEPH": "JOE",
        "SAM": "SAMUEL", "SAMUEL": "SAM",
        "KATE": "CATHERINE", "CATHERINE": "KATE", "KATHLEEN": "KATE",
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
    // Two diminutives of one formal name (WILLIE ~ BILL via WILLIAM) — the
    // flat pair table can't express transitivity; the shared canonical can
    // (kept in step with ScoringRules.givenNameVariants' cluster walk).
    if let canonA = nicknames[a], let canonB = nicknames[b], canonA == canonB { return 0.85 }

    // One contains the other (Mary Ann / Mary)
    if a.contains(b) || b.contains(a) { return 0.8 }


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
    public let category: AuditCategory = .research
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
                severity: .warning, category: .research, ruleID: id,
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
    public let category: AuditCategory = .research
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
            severity: .info, category: .research, ruleID: id,
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
        // EV18 (2026-08-26): an unconfirmed name match counts as outstanding
        // business too. `.nearMatch` emits no `Finding` (it must never nag the
        // owner to add someone they already have) and the absorption count drops
        // the row, so a household whose ONLY open row was a near-match had no
        // trigger left and disappeared from every surface — the app quietly
        // keeping an identity question to itself. This panel is where both
        // answers ("Same person" / "Add separately") live.
        let nearMatches = CensusRelationshipReconciler.nearMatchProposals(for: profile, in: snapshot)
        if !missing.isEmpty || !unlinked.isEmpty || !inLawLeads.isEmpty || !nearMatches.isEmpty {
            results.append(AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .gap, ruleID: id,
                message: Self.gapMessage(subject: profile, missing: missing,
                                         unlinked: unlinked, inLaw: inLawLeads,
                                         nearMatches: nearMatches)))
        }
        return results
    }

    /// EV33 follow-up (review C5): true iff the reconciliation panel the Health
    /// list hosts beneath this rule's `.info` gap row renders at least one
    /// DETERMINISTIC one-click fix. The quick-win registry
    /// (`HealthTriage.isOneClickFinding`) must mirror every one-click the list
    /// renders, and the panel offers three, one per roster status:
    ///   - `.missing`        → "Add <relation>" (renders only with a relation);
    ///   - `.unlinkedInTree` → "Link <name>" (its action fires only with a
    ///                          relation);
    ///   - `.inLawOfSpouse`  → "Add <spouse>'s mother/father" (relation-free —
    ///                          the roster's "-in-law" is relative to the head).
    /// `.nearMatch` is deliberately EXCLUDED: its "Same person" / "Add
    /// separately" pair is a judgement about an identity nobody has established
    /// (EV18), never a quick win. One pass over the same roster statuses the
    /// panel switches on, kept here beside the rule so the registry and the
    /// row-render logic cannot drift apart again.
    public static func hasOneClickReconciliation(
        for profile: Profile, in snapshot: FamilyGraphSnapshot
    ) -> Bool {
        for recon in CensusRelationshipReconciler.reconciliations(for: profile, in: snapshot) {
            for entry in recon.entries {
                switch entry.status {
                case .missing, .unlinkedInTree:
                    if entry.censusRelation != nil { return true }
                case .inLawOfSpouse:
                    return true
                case .subject, .inTree, .contradiction, .nearMatch, .outOfScope:
                    break
                }
            }
        }
        return false
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
                           inLaw: [CensusRelationshipReconciler.InLawLead],
                           nearMatches: [CensusRelationshipReconciler.NearMatchProposal]) -> String {
        var parts: [String] = []
        if !missing.isEmpty { parts.append(missingMessage(subject: subject, missing: missing)) }
        if !unlinked.isEmpty { parts.append(unlinkedMessage(subject: subject, unlinked: unlinked)) }
        if !inLaw.isEmpty { parts.append(inLawMessage(subject: subject, inLaw: inLaw)) }
        if !nearMatches.isEmpty { parts.append(nearMatchMessage(subject: subject, nearMatches: nearMatches)) }
        return parts.joined(separator: " ")
    }

    /// "A census names 1 row on William's household whose identity is
    /// unconfirmed — the forename differs from a relative already linked:
    /// John H Gladwin (child). Confirm or add separately."
    static func nearMatchMessage(subject: Profile,
                                 nearMatches: [CensusRelationshipReconciler.NearMatchProposal]) -> String {
        let subjectName = subject.firstName ?? subject.displayName
        let list = nearMatches.map { "\($0.member.name) (\(relationPhrase($0.relation)))" }
            .joined(separator: ", ")
        let n = nearMatches.count
        return "A census names \(n) row\(n == 1 ? "" : "s") on \(subjectName)'s household whose identity is unconfirmed — the forename differs from a relative already linked: \(list). Confirm or add separately."
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

// MARK: - Census citation reader (EV17 sibling task, 2026-08-26)

/// Recognises "this cited record IS the census of year Y" from a `FieldSource`.
///
/// Why this lives here and not on `SourceTierRegistry`: that registry is the
/// single source of truth for what a URL's TRUST TIER is (a load-bearing
/// invariant — nothing else may assert a tier), but it answers only that
/// question, it has no notion of record type or census year, and it lives in the
/// app module which AncestorKit cannot import. So this reader deliberately
/// asserts NO tier. It borrows only the registry's domain list — the same hosts,
/// split by whether their collections can contain census returns at all — and
/// takes the YEAR from the citation's own structured text via the existing
/// `CensusType` catalogue, never from an invented year list.
///
/// Two-stage on purpose. The URL decides whether the record COULD be a census
/// (a freebmd.org.uk index or a freereg.org.uk parish register never is, by
/// construction); the citation text then has to SAY census — a bare four-digit
/// year is not enough, because a FreeBMD birth index for a child born in 1861
/// carries "1861" in its title and would otherwise read as the 1861 census.
public nonisolated enum CensusCitationReader {

    /// The census year this source cites, or nil when the source is not
    /// recognisably a census record (or names more than one census, which is
    /// ambiguous — say nothing rather than guess).
    public static func censusYear(of source: FieldSource) -> Int? {
        guard let url = source.citation?.url, isCensusBearing(url: url) == true else { return nil }

        var text = [source.citation?.collection, source.citation?.title,
                    source.citation?.page, source.citation?.notes]
            .compactMap { $0 }
        // `raw` is usually a pre-formatted citation string ("1881 England
        // Census, Handsworth … RG11 4669/172 p.20 line 14") and is the only
        // place some paths record the class piece. Skip it when it is a bare URL
        // — record ids are digit runs and would pollute the year scan.
        if !source.raw.contains("://"), !source.raw.contains("ark:/") {
            text.append(source.raw)
        }
        let parts = tokens(in: text.joined(separator: " "))

        // Census-ness: the word itself, or a TNA class that IS a census return.
        let classYears = Set(parts.compactMap { censusClassYears[$0] })
        let ambiguousClass = parts.contains { ambiguousCensusClasses.contains($0) }
        guard parts.contains("CENSUS") || !classYears.isEmpty || ambiguousClass else { return nil }

        let statedYears = Set(parts.compactMap { Int($0) }.filter { censusYears.contains($0) })
        if classYears.count > 1 { return nil }              // two classes — incoherent
        if let fromClass = classYears.first {
            // A stated year contradicting the class piece means the citation is
            // internally inconsistent; a wrong year would send the user to the
            // wrong census, so stay silent.
            return statedYears.isEmpty || statedYears == [fromClass] ? fromClass : nil
        }
        return statedYears.count == 1 ? statedYears.first : nil
    }

    /// The decennial years the app knows about, taken from the existing
    /// `CensusType` catalogue rather than a second hand-written list.
    static let censusYears: Set<Int> = Set(CensusType.allCases.compactMap(\.year))

    /// TNA record classes that ARE the census returns. National classes — no
    /// region is encoded anywhere here. Full digit runs are compared, so the
    /// 1939 Register's RG101 does not collide with RG10 (1871).
    static let censusClassYears: [String: Int] = [
        "RG9": 1861, "RG10": 1871, "RG11": 1881,
        "RG12": 1891, "RG13": 1901, "RG14": 1911,
    ]

    /// Census classes whose year is AMBIGUOUS — HO107 covers both 1841 and
    /// 1851. They establish census-ness but cannot pin the year alone.
    static let ambiguousCensusClasses: Set<String> = ["HO107"]

    /// Hosts whose collections are, by construction, never census returns —
    /// civil-registration indexes, parish registers, probate calendars, war
    /// graves, memorials. Same domains the app's `SourceTierRegistry` knows.
    static let nonCensusHosts: Set<String> = [
        "freebmd.org.uk", "freereg.org.uk", "probatesearch.service.gov.uk",
        "cwgc.org", "findagrave.com", "legislation.gov.uk",
    ]

    /// Hosts that DO publish census returns. `freecen.org.uk` is census-only;
    /// the rest hold mixed collections, which is why the citation text still has
    /// to say census.
    static let censusBearingHosts: Set<String> = [
        "freecen.org.uk", "familysearch.org", "nationalarchives.gov.uk",
        "ancestry.co.uk", "ancestry.com", "findmypast.co.uk", "thegenealogist.co.uk",
    ]

    /// `true` = the host can carry census returns, `false` = it definitively
    /// cannot, `nil` = unrecognised, so the record is not RECOGNISABLY a census
    /// and this reader declines to guess.
    static func isCensusBearing(url: String) -> Bool? {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return nil }
        // A bare `ark:/…` path segment with no host is a FamilySearch record
        // locator — `ExternalIdentifier` stores FS ids in exactly that form, so
        // a citation may carry it without the host.
        if lower.hasPrefix("ark:/") { return true }
        guard let host = hostName(of: lower) else { return nil }
        func matches(_ set: Set<String>) -> Bool {
            set.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
        if matches(nonCensusHosts) { return false }
        if matches(censusBearingHosts) { return true }
        return nil
    }

    /// Host, `www.`-stripped. Mirrors `SourceTierRegistry.extractHost` including
    /// its fallback for strings `URL` refuses to parse.
    static func hostName(of url: String) -> String? {
        var found = URL(string: url)?.host
        if found == nil {
            var s = url
            if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
            if let slash = s.range(of: "/") { s = String(s[..<slash.lowerBound]) }
            found = s.isEmpty ? nil : s
        }
        guard var h = found?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// Alphanumeric runs, upper-cased. Keeps "RG11" and "HO107" whole while
    /// splitting "RG11 4669/172 p.20" into its parts.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.uppercased() }
    }
}

// MARK: - Cited Census Without Event (owner dogfood 2026-08-26)

/// A census is cited as the SOURCE of a profile field, but no census event for
/// that year sits on the profile — the citation is carrying a record that the
/// tree otherwise cannot see.
///
/// Live specimen: Hannah Hewkin's `lastName` fact "Hewkin" cites the 1841
/// Dronfield census (HO107 195/20 book 6 p.8 line 21, ark:/61903/1:1:M7SB-YZJ) —
/// the evidence that corrected her surname from Wheatman. She had no 1841 census
/// event, so the citation sat on a field with nothing behind it: the 1841 census
/// was invisible to her timeline, to the roster machinery, to the family-context
/// gate and to completeness. Nothing surfaced it. A human found it by reading
/// citation URLs by eye.
///
/// `.gap`, at info: the evidence IS in the project and is only incompletely
/// applied, which is the `.gap` definition, so it renders in Health rather than
/// being filed as a research prompt.
///
/// Distinct from `censusUnabsorbed`, which describes the opposite situation — a
/// census that HAS been applied and whose household names relatives not yet on
/// the tree. This rule requires the ABSENCE of a census event for the year, so
/// per (profile, year) the two cannot both be describing the same row. They can
/// still both fire on one PROFILE for different years; see
/// `missingCensusEventYears`, which the Health assembly can use to dedupe.
public nonisolated struct CitedCensusWithoutEventRule: AuditRuleDefinition {
    public let id = "citedCensusWithoutEvent"
    public let category: AuditCategory = .gap
    public let displayName = "Census Cited, Never Added"
    public let description = "A profile field cites a census record, but the profile has no census event for that year — so the census is invisible to the timeline, the household roster and completeness."
    public let fireCondition = "A field_source citation resolves to a census of year Y, and no census life event on the profile covers Y (nor cites the same record)."
    public let warningCondition: String? = nil
    public let workedExample = "Hannah Hewkin's surname cites the 1841 Dronfield census (HO107 195/20), but she has no 1841 census event — the household behind the correction was never added."
    public let defaultSeverity = Severity.info
    public init() {}

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        let missing = Self.missingCensusEventYears(for: profile, in: snapshot)
        guard !missing.isEmpty else { return [] }
        return [AuditResult(
            profileID: profile.id, profileName: profile.displayName,
            severity: .info, category: .gap, ruleID: id,
            message: Self.message(profile: profile, missing: missing))]
    }

    /// Census years cited by this profile's field sources that no census event
    /// on the profile carries — ascending, with the fields that cite each.
    ///
    /// Public so the Health assembly can dedupe a `censusUnabsorbed` row against
    /// this one by (profile, year) without parsing prose. `censusUnabsorbed`
    /// treats a census as APPLIED when a confirmed fact cites its detail URL,
    /// even with no life event (`AppState.censusHouseholdProposal`'s
    /// `citedByFact` arm) — which is exactly Hannah's shape, so a profile whose
    /// cited-but-eventless census ALSO has un-absorbed household members can
    /// raise both rules.
    public static func missingCensusEventYears(for profile: Profile, in snapshot: FamilyGraphSnapshot)
        -> [(year: Int, fields: [ProfileField])] {
        // Sorted so the message is stable across runs — dictionary order is not.
        let sources = profile.sources
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { entry in entry.value.map { (field: entry.key, source: $0) } }
        guard !sources.isEmpty else { return [] }

        let events = (snapshot.lifeEvents[profile.id] ?? []).filter { $0.type == .census }
        // The record identities already carried by a census EVENT. Belt to the
        // year check's braces: if the very record cited on the field is what
        // backs an existing census event, there is something behind the citation
        // whatever year the two disagree on.
        let eventRecords = Set(events.flatMap(\.sources)
            .compactMap { SiblingIdentityCollisionRule.recordLocator($0) })

        var fieldsByYear: [Int: [ProfileField]] = [:]
        for (field, source) in sources {
            guard let year = CensusCitationReader.censusYear(of: source) else { continue }
            if let locator = SiblingIdentityCollisionRule.recordLocator(source),
               eventRecords.contains(locator) { continue }
            // YEAR, not date-string equality: an event dated "6 Jun 1841" and a
            // citation saying "1841" are the same census, and must not fire.
            if events.contains(where: { covers($0, year) }) { continue }
            var fields = fieldsByYear[year] ?? []
            if !fields.contains(field) { fields.append(field) }
            fieldsByYear[year] = fields
        }
        return fieldsByYear.keys.sorted().map { (year: $0, fields: fieldsByYear[$0] ?? []) }
    }

    /// Does this event's date range cover `year`? Reads the parsed year bounds,
    /// never the original string, so "6 Jun 1841", "1841" and "ABT 1841" all
    /// cover 1841.
    static func covers(_ event: LifeEvent, _ year: Int) -> Bool {
        for date in [event.date, event.endDate].compactMap({ $0 }) {
            let lo = date.earliest ?? date.latest
            let hi = date.latest ?? date.earliest
            if let lo, let hi, lo <= year, year <= hi { return true }
        }
        return false
    }

    static func message(profile: Profile, missing: [(year: Int, fields: [ProfileField])]) -> String {
        let years = missing.map { String($0.year) }
        // Key paths cannot address tuple components, so flatMap explicitly.
        let fields = Array(Set(missing.flatMap { $0.fields }))
            .sorted { $0.rawValue < $1.rawValue }
            .map { fieldLabel($0) }
        let plural = missing.count > 1
        let citation = plural
            ? "citations on \(list(fields)) point at the \(list(years)) censuses"
            : "a citation on \(list(fields)) points at the \(years.first ?? "") census"
        return "\(profile.displayName) — \(citation), but no matching census event sits on the timeline. Until the census is added, the timeline, the household roster, the family-context gate and completeness cannot see it."
    }

    /// "a, b and c" — Oxford-free, matching the prose style of the other rules.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Human field names. `ProfileField.rawValue` is camelCase and reads as
    /// code in a Health row.
    static func fieldLabel(_ field: ProfileField) -> String {
        switch field {
        case .firstName: return "the given name"
        case .middleName: return "the middle name"
        case .lastName: return "the surname"
        case .marriedSurname: return "the married surname"
        case .nickName: return "the nickname"
        case .mothersMaidenName: return "the mother's maiden name"
        case .gender: return "the sex"
        case .birthDate: return "the birth date"
        case .birthLocation: return "the birthplace"
        case .deathDate: return "the death date"
        case .deathLocation: return "the death place"
        case .bio: return "the biography"
        case .nameForms: return "the name variants"
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

// MARK: - Conflict-layer wrappers (Conflict layer CL2)

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


/// Import dedupe Change 1 — surfaces orphan-stub duplicates (a
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

/// Import dedupe Change 4 — surfaces phantom-spouse stubs (a dateless,
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

// MARK: - Rule: 1911 fertility statement vs tree (FreeREG integration)

/// The 1911 census asked each married woman, about her PRESENT marriage:
/// years married, children born alive, children still living (and deceased,
/// except Scotland/Ireland). It is the mother's own statement of how many
/// children the tree should hold — including children who died young and
/// appear in no other census. This rule compares her corroborated 1911
/// roster row's statement with the tree and surfaces any shortfall as a
/// research prompt (severity .info, category .research — FreeBMD can find
/// the missing children); a second finding cross-checks 1911 − yearsMarried
/// against the recorded marriage year (±2 tolerance) — that one is a
/// contradiction with applied evidence, so it stays category .issue.
///
/// Deliberately UNDER-firing (the anti-duplicate-detection posture):
/// unknown-birth-year children count toward the tree tally, the tally uses
/// ALL her children (not the couple intersection, which undercounts
/// half-linked children and would inflate a shortfall), step/adoptive
/// edges are excluded, and an internally inconsistent statement fires
/// nothing.
public nonisolated struct FertilityGapRule: AuditRuleDefinition {
    public let id = "fertilityGap"
    public let category: AuditCategory = .research
    public let displayName = "1911 Fertility Statement"
    public let description = "A woman's 1911 census statement of children born alive exceeds her children recorded in the tree, or implies a different marriage year."
    public let fireCondition = "Her corroborated 1911 census row states more children born alive than the tree records born before 1911 (internally consistent statements only), or 1911 − years-married differs from the recorded marriage year by more than 2."
    public let warningCondition: String? = nil
    public let workedExample = "Sarah stated 5 children born alive (4 living, 1 died); the tree has 3 born before 1911 — 2 unaccounted, incl. 1 who died young."
    public let defaultSeverity = Severity.info
    public init() {}

    /// Her corroborated 1911 row + the household it sits in. Searches her
    /// own census events first, then her spouses' (the roster often lives
    /// on the husband's event — the `CensusAgeBirthYearRule` precedent).
    /// Corroboration = the reconciler's name + birth-year predicates;
    /// `isTarget` is NOT required (it flags the searched person, usually
    /// the husband).
    static func statement(for profile: Profile, in snapshot: FamilyGraphSnapshot)
        -> (row: HouseholdMember, household: [HouseholdMember])? {
        var carriers: [Profile] = [profile]
        carriers += snapshot.spousesOf(profile.id)
        for carrier in carriers {
            for event in snapshot.lifeEvents[carrier.id] ?? [] where event.type == .census {
                guard case .census(let details)? = event.details,
                      event.date?.bestYear == 1911 else { continue }
                if let row = details.household.first(where: {
                    $0.childrenBornAlive != nil &&
                    CensusRelationshipReconciler.matches(member: $0, profile: profile, censusYear: 1911)
                }) {
                    return (row, details.household)
                }
            }
        }
        return nil
    }

    /// Internal consistency of the stated figures: born == living + died
    /// when all three present; born ≥ living when died is absent
    /// (Scotland/Ireland 1911 omit the deceased column). An inconsistent
    /// statement is transcription doubt → never fires.
    static func isConsistent(_ row: HouseholdMember) -> Bool {
        guard let born = row.childrenBornAlive, born >= 0 else { return false }
        if let living = row.childrenLiving, let died = row.childrenDeceased {
            return living + died == born
        }
        if let living = row.childrenLiving { return born >= living }
        return true
    }

    /// Her children in the tree, counted UNDER-firing: all her non-step,
    /// non-adoptive, non-deleted children; unknown birth years count as
    /// born-before-1912 (assume accounted-for, never inflate a shortfall).
    static func treeChildTally(for profile: Profile, in snapshot: FamilyGraphSnapshot) -> Int {
        snapshot.relationships
            .filter { $0.type == .parent && $0.from == profile.id
                      && $0.subtype != .step && $0.subtype != .adoptive }
            .compactMap { snapshot.profiles[$0.to] }
            .filter { !$0.isDeleted }
            .filter { ($0.birthDate?.bestYear).map { $0 <= 1911 } ?? true }
            .count
    }

    /// 1911 − yearsMarried vs the recorded marriage year. The census
    /// husband's marriage edge is chosen only when unambiguous: her sole
    /// dated marriage, or (multiple dated marriages) the dated edge to
    /// the spouse who matches the roster's Head row. Anything ambiguous
    /// → nil, no finding.
    static func marriageYearMismatch(
        for profile: Profile, in snapshot: FamilyGraphSnapshot,
        row: HouseholdMember, household: [HouseholdMember]
    ) -> (implied: Int, recorded: Int)? {
        guard let text = row.yearsMarried?.trimmingCharacters(in: .whitespaces),
              let years = Int(text), years >= 0, years < 80 else { return nil }
        let implied = 1911 - years

        let edges = snapshot.relationships.filter {
            $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
        }
        let dated: [(edge: Relationship, year: Int)] = edges.compactMap { e in
            e.marriageDate?.bestYear.map { (e, $0) }
        }
        let recorded: Int?
        if dated.count == 1 {
            recorded = dated[0].year
        } else if let head = household.first(where: { $0.relationship.lowercased() == "head" }),
                  head != row {
            let headSpouses = snapshot.spousesOf(profile.id).filter {
                CensusRelationshipReconciler.matches(member: head, profile: $0, censusYear: 1911)
            }
            if headSpouses.count == 1 {
                let spouseID = headSpouses[0].id
                let matching = dated.filter { $0.edge.from == spouseID || $0.edge.to == spouseID }
                recorded = matching.count == 1 ? matching[0].year : nil
            } else {
                recorded = nil
            }
        } else {
            recorded = nil
        }

        guard let recorded, abs(implied - recorded) > 2 else { return nil }
        return (implied, recorded)
    }

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let (row, household) = Self.statement(for: profile, in: snapshot),
              Self.isConsistent(row) else { return [] }
        var results: [AuditResult] = []

        if let born = row.childrenBornAlive {
            let tally = Self.treeChildTally(for: profile, in: snapshot)
            if tally < born {
                var stated = "\(born) children born alive"
                if let living = row.childrenLiving, let died = row.childrenDeceased {
                    stated += " (\(living) living, \(died) died)"
                } else if let living = row.childrenLiving {
                    stated += " (\(living) living)"
                }
                var message = "1911: \(profile.displayName) stated \(stated); the tree has \(tally) born before 1911 — \(born - tally) unaccounted"
                if let died = row.childrenDeceased, died > 0 {
                    message += " (incl. \(died) who died young, likely absent from all censuses)"
                }
                message += "."
                results.append(AuditResult(
                    profileID: profile.id, profileName: profile.displayName,
                    severity: .info, category: .research, ruleID: id,
                    message: message))
            }
        }

        if let (implied, recorded) = Self.marriageYearMismatch(
            for: profile, in: snapshot, row: row, household: household) {
            results.append(AuditResult(
                profileID: profile.id, profileName: profile.displayName,
                severity: .info, category: .issue, ruleID: id,
                message: "1911: \(profile.displayName)'s census implies marriage ~\(implied) (\(row.yearsMarried ?? "?") years married); the tree records \(recorded)."))
        }
        return results
    }

    public func guidanceMessage(profile: Profile) -> String? {
        "FreeBMD birth and death indexes between \(profile.displayName)'s marriage and 1911 often surface children who died young."
    }
}
