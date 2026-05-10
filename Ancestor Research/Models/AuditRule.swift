import Foundation

/// Protocol — all rules (built-in and future user-defined) conform.
/// Each rule is its own struct, independently testable.
nonisolated protocol AuditRuleDefinition: Sendable {
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
    var category: AuditCategory { .issue }

    /// Default: no tunable thresholds. Rules opt-in by overriding.
    var tunableThresholds: [TunableThreshold] { [] }

    /// Default: ignore thresholds and call the zero-arg evaluate.
    /// Threshold-honouring rules override this.
    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot)
    }

    /// Default: no guidance variant. Rules opt-in by overriding.
    func guidanceMessage(profile: Profile) -> String? { nil }
}

/// Registry of built-in rules.
nonisolated enum AuditRules {
    static let builtIn: [AuditRuleDefinition] = [
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
    ]
}

// MARK: - Completeness Score Rule

nonisolated struct CompletenessScoreRule: AuditRuleDefinition {
    let id = "completenessScore"
    let category: AuditCategory = .gap
    let displayName = "Completeness Score"
    let description = "Profiles are scored 0-7 based on populated fields."
    let fireCondition = "Score below maximum for that profile type."
    let warningCondition: String? = nil
    let workedExample = "Profile with name, birth date, birth location but no death info, no bio, no parents → 3/7"
    let defaultSeverity = Severity.info

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct BirthBeforeDeathRule: AuditRuleDefinition {
    let id = "birthBeforeDeath"
    let displayName = "Birth Before Death"
    let description = "A person must be born before they die."
    let fireCondition = "birth.earliest > death.latest"
    let warningCondition: String? = "birth.bestYear > death.bestYear"
    let workedExample = "Birth 'AFT 1920' (earliest=1920), Death 'BEF 1668' (latest=1668): 1920 > 1668 → ERROR"
    let defaultSeverity = Severity.error

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct ParentAgeGapRule: AuditRuleDefinition {
    let id = "parentAgeGap"
    let displayName = "Parent Age Gap"
    let description = "A biological parent must be at least 14 years older than their child."
    let fireCondition = "parent.birthDate.latest + 14 > child.birthDate.earliest"
    let warningCondition: String? = "parent.bestYear + 14 > child.bestYear"
    let workedExample = "Parent '1874' (latest=1874), Child '1887' (earliest=1887): 1874+14=1888 > 1887 → ERROR (gap is 13)"
    let defaultSeverity = Severity.error

    var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "minYearsGap",
            displayName: "Minimum parent-child age gap",
            defaultValue: 14, minimum: 8, maximum: 20, unit: "years"
        )]
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
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

nonisolated struct MarriageAgeRule: AuditRuleDefinition {
    let id = "marriageAge"
    let displayName = "Marriage Age"
    let description = "A person must be at least 16 to marry."
    let fireCondition = "marriage.earliest < birth.latest + 16"
    let warningCondition: String? = "marriage.bestYear < birth.bestYear + 16"
    let workedExample = "Birth 'ABT 1870' (latest=1875), Marriage '1880': 1880 < 1875+16=1891 → ok. Marriage '1882': bestYear check → WARNING"
    let defaultSeverity = Severity.error

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct LifespanRule: AuditRuleDefinition {
    let id = "lifespan"
    let displayName = "Lifespan"
    let description = "No person lives beyond 110 years."
    let fireCondition = "death.earliest - birth.latest > 110"
    let warningCondition: String? = "death.bestYear - birth.bestYear > 110"
    let workedExample = "Birth '1800' (latest=1800), Death 'AFT 1920' (earliest=1920): 1920-1800=120 > 110 → ERROR"
    let defaultSeverity = Severity.error

    var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "maxLifespan",
            displayName: "Maximum plausible lifespan",
            defaultValue: 110, minimum: 90, maximum: 130, unit: "years"
        )]
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
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

nonisolated struct NoMarriageAfterDeathRule: AuditRuleDefinition {
    let id = "noMarriageAfterDeath"
    let displayName = "No Marriage After Death"
    let description = "A person cannot marry after they die."
    let fireCondition = "marriage.earliest > death.latest"
    let warningCondition: String? = "marriage.bestYear > death.bestYear"
    let workedExample = "Marriage '1890', Death 'BEF 1885' (latest=1885): 1890 > 1885 → ERROR"
    let defaultSeverity = Severity.error

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct MissingParentsRule: AuditRuleDefinition {
    let id = "missingParents"
    let category: AuditCategory = .gap
    let displayName = "Missing Parents"
    let description = "Profile has no parent links."
    let fireCondition = "No parent edges for this profile."
    let warningCondition: String? = nil
    let workedExample = ""
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

    func guidanceMessage(profile: Profile) -> String? {
        "Consider adding \(profile.displayName)'s parents — their parish records often unlock further generations."
    }
}

nonisolated struct MissingBirthDateRule: AuditRuleDefinition {
    let id = "missingBirthDate"
    let category: AuditCategory = .gap
    let displayName = "Missing Birth Date"
    let description = "Profile has no birth date."
    let fireCondition = "birthDate is nil."
    let warningCondition: String? = nil
    let workedExample = ""
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        if profile.birthDate == nil {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no birth date"
            )]
        }
        return []
    }

    func guidanceMessage(profile: Profile) -> String? {
        "What you might add next: birth date for \(profile.displayName)."
    }
}

nonisolated struct MissingDeathDateRule: AuditRuleDefinition {
    let id = "missingDeathDate"
    let category: AuditCategory = .gap
    let displayName = "Missing Death Date"
    let description = "Profile has no death date (may still be living)."
    let fireCondition = "deathDate is nil and not potentially living."
    let warningCondition: String? = nil
    let workedExample = ""
    let defaultSeverity = Severity.info

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

    func guidanceMessage(profile: Profile) -> String? {
        "What you might add next: death date for \(profile.displayName)."
    }
}

nonisolated struct MissingBirthLocationRule: AuditRuleDefinition {
    let id = "missingBirthLocation"
    let category: AuditCategory = .gap
    let displayName = "Missing Birth Location"
    let description = "Profile has no birth location."
    let fireCondition = "birthLocation is nil."
    let warningCondition: String? = nil
    let workedExample = ""
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        if profile.birthLocation == nil {
            return [AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, category: .gap, ruleID: id,
                message: "\(profile.displayName) — no birth location"
            )]
        }
        return []
    }

    func guidanceMessage(profile: Profile) -> String? {
        "You could note where \(profile.displayName) was born when you next find a record."
    }
}

nonisolated struct MissingBioRule: AuditRuleDefinition {
    let id = "missingBio"
    let category: AuditCategory = .gap
    let displayName = "Missing Biography"
    let description = "Profile has no biography."
    let fireCondition = "bio is nil or empty."
    let warningCondition: String? = nil
    let workedExample = ""
    let defaultSeverity = Severity.info

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct DuplicateDetectionRule: AuditRuleDefinition {
    let id = "duplicateDetection"
    let displayName = "Possible Duplicates"
    let description = "Two profiles with similar names and overlapping birth years may be the same person."
    let fireCondition = "Similarity score ≥ 0.7 between two profiles."
    let warningCondition: String? = nil
    let workedExample = "MABEL CAULDWELL b.1897 exists as both Cauldwell-148 and Cauldwell-145"
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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
nonisolated func nameSimilarity(_ a: String, _ b: String) -> Double {
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

nonisolated struct ParentDiedBeforeChildRule: AuditRuleDefinition {
    let id = "parentDiedBeforeChild"
    let displayName = "Parent Died Before Child Born"
    let description = "A parent cannot have died before their child was born (1-year posthumous allowance)."
    let fireCondition = "parent.deathDate.latest < child.birthDate.earliest - 1"
    let warningCondition: String? = "parent.deathDate.bestYear < child.birthDate.bestYear - 1"
    let workedExample = "Parent died 1880, child born 1885: 1880 < 1884 → ERROR"
    let defaultSeverity = Severity.error

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct ParentSuspiciouslyOldRule: AuditRuleDefinition {
    let id = "parentSuspiciouslyOld"
    let displayName = "Parent Suspiciously Old"
    let description = "A parent more than 55 years older than their child is unusual and worth checking."
    let fireCondition = "child.birthDate.earliest - parent.birthDate.latest > 55"
    let warningCondition: String? = "child.birthDate.bestYear - parent.birthDate.bestYear > 55"
    let workedExample = "Parent born 1820, child born 1880: gap 60 → WARNING (unusual but possible)"
    let defaultSeverity = Severity.warning

    var tunableThresholds: [TunableThreshold] {
        [TunableThreshold(
            key: "maxYearsGap",
            displayName: "Maximum parent-child age gap",
            defaultValue: 55, minimum: 40, maximum: 80, unit: "years"
        )]
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        evaluate(profile: profile, snapshot: snapshot, thresholds: [:])
    }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot, thresholds: [String: Double]) -> [AuditResult] {
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

nonisolated struct SelfSpouseRule: AuditRuleDefinition {
    let id = "selfSpouse"
    let displayName = "Self-Spouse"
    let description = "A person cannot be linked as their own spouse."
    let fireCondition = "Spouse edge where from == to."
    let warningCondition: String? = nil
    let workedExample = "Profile X has a spouse link pointing to itself"
    let defaultSeverity = Severity.error

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct UnsourcedBioRule: AuditRuleDefinition {
    let id = "unsourcedBio"
    let displayName = "Unsourced Biography"
    let description = "Biography exists but has no source citations — may be unverified GEDCOM data."
    let fireCondition = "Bio present (>50 chars) but no <ref> tags or Sources section."
    let warningCondition: String? = nil
    let workedExample = "Profile has 200-char bio but no references or Sources heading"
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct MissingDeathLocationRule: AuditRuleDefinition {
    let id = "missingDeathLocation"
    let category: AuditCategory = .gap
    let displayName = "Missing Death Location"
    let description = "Profile has a death date but no death location."
    let fireCondition = "deathDate is set but deathLocation is nil."
    let warningCondition: String? = nil
    let workedExample = "Profile has death date 1960 but no death location recorded"
    let defaultSeverity = Severity.warning

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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

nonisolated struct AncestorExtensionRule: AuditRuleDefinition {
    let id = "ancestorExtension"
    let category: AuditCategory = .gap
    let displayName = "End-of-Line Ancestor"
    let description = "Profile has no parents and was born before 1920 — tree can be extended via parish/civil records."
    let fireCondition = "No parent edges, birth year < 1920, name is not 'Unknown'."
    let warningCondition: String? = nil
    let workedExample = "John Smith born 1880 with no parents → search christening records"
    let defaultSeverity = Severity.info

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
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
