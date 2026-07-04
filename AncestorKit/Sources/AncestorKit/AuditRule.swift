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
        ParentAgeGapRule(),
        MarriageAgeRule(),
        LifespanRule(),
        NoMarriageAfterDeathRule(),
        MissingParentsRule(),
        MissingBirthDateRule(),
        MissingDeathDateRule(),
        MissingBirthLocationRule(),
        MissingBioRule(),
        DuplicateDetectionRule(),
        CompletenessScoreRule(),
        ParentDiedBeforeChildRule(),
        ParentSuspiciouslyOldRule(),
        SelfSpouseRule(),
        UnsourcedBioRule(),
        MissingDeathLocationRule(),
        AncestorExtensionRule(),
        UnlinkedSpouseForFemaleSubjectRule(),
    ]
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

public nonisolated struct MarriageAgeRule: AuditRuleDefinition {
    public init() {}

    public let id = "marriageAge"
    public let displayName = "Marriage Age"
    public let description = "A person must be at least 16 to marry."
    public let fireCondition = "marriage.earliest < birth.latest + 16"
    public let warningCondition: String? = "marriage.bestYear < birth.bestYear + 16"
    public let workedExample = "Birth 'ABT 1870' (latest=1875), Marriage '1880': 1880 < 1875+16=1891 → ok. Marriage '1882': bestYear check → WARNING"
    public let defaultSeverity = Severity.error

    public func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let birth = profile.effectiveDate(.birthDate) else { return [] }
        var results: [AuditResult] = []

        let spouseRels = snapshot.relationships.filter {
            $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
        }

        for rel in spouseRels {
            guard let marriage = rel.marriageDate else { continue }

            if let me = marriage.earliest, let bl = birth.latest, me < bl + 16 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(profile.displayName) married \(marriage.original) but born \(birth.original) — married before age 16"
                ))
            } else if let mby = marriage.bestYear, let bby = birth.bestYear, mby < bby + 16 {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .warning, ruleID: id,
                    message: "\(profile.displayName) may have married (~\(mby)) before age 16 (born ~\(bby))"
                ))
            }
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
        var score = 0.0

        // Surname similarity
        if let surnameA = a.lastName, let surnameB = b.lastName {
            score += nameSimilarity(surnameA, surnameB) * 0.4
        }

        // Given name similarity
        if let givenA = a.firstName, let givenB = b.firstName {
            score += nameSimilarity(givenA, givenB) * 0.3
        }

        // Birth year overlap
        if let birthA = a.birthDate, let birthB = b.birthDate {
            if rangesOverlap(birthA, birthB) {
                score += 0.3
            }
        }

        return score
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
    ]
    if nicknames[a] == b || nicknames[b] == a { return 0.85 }

    // Single character difference (typo/transcription)
    if a.count == b.count {
        let diffs = zip(a, b).filter { $0 != $1 }.count
        if diffs == 1 { return 0.7 }
    }

    return 0.0
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
