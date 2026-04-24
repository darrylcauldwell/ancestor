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

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult]
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
    ]
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
        guard let birth = profile.birthDate, let death = profile.deathDate else { return [] }
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

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let childBirth = profile.birthDate else { return [] }
        var results: [AuditResult] = []

        let parentRels = snapshot.relationships.filter {
            $0.type == .parent && $0.to == profile.id && $0.subtype == .biological
        }

        for rel in parentRels {
            guard let parent = snapshot.profiles[rel.from],
                  let parentBirth = parent.birthDate else { continue }

            if let pl = parentBirth.latest, let ce = childBirth.earliest, pl + 14 > ce {
                results.append(AuditResult(
                    id: UUID(), profileID: profile.id, profileName: profile.displayName,
                    severity: .error, ruleID: id,
                    message: "\(parent.displayName) (born \(parentBirth.original)) is parent of \(profile.displayName) (born \(childBirth.original)) — gap may be less than 14 years"
                ))
            } else if let pby = parentBirth.bestYear, let cby = childBirth.bestYear, pby + 14 > cby {
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
        guard let birth = profile.birthDate else { return [] }
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

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult] {
        guard let birth = profile.birthDate, let death = profile.deathDate else { return [] }
        var results: [AuditResult] = []

        if let de = death.earliest, let bl = birth.latest, de - bl > 110 {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .error, ruleID: id,
                message: "\(profile.displayName) lifespan \(de - bl) years (born \(birth.original), died \(death.original)) — exceeds 110"
            ))
        } else if let dby = death.bestYear, let bby = birth.bestYear, dby - bby > 110 {
            results.append(AuditResult(
                id: UUID(), profileID: profile.id, profileName: profile.displayName,
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) probable lifespan ~\(dby - bby) years — exceeds 110"
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
        guard let death = profile.deathDate else { return [] }
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
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) — no parents"
            )]
        }
        return []
    }
}

nonisolated struct MissingBirthDateRule: AuditRuleDefinition {
    let id = "missingBirthDate"
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
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) — no birth date"
            )]
        }
        return []
    }
}

nonisolated struct MissingDeathDateRule: AuditRuleDefinition {
    let id = "missingDeathDate"
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
                severity: .info, ruleID: id,
                message: "\(profile.displayName) — no death date"
            )]
        }
        return []
    }
}

nonisolated struct MissingBirthLocationRule: AuditRuleDefinition {
    let id = "missingBirthLocation"
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
                severity: .warning, ruleID: id,
                message: "\(profile.displayName) — no birth location"
            )]
        }
        return []
    }
}

nonisolated struct MissingBioRule: AuditRuleDefinition {
    let id = "missingBio"
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
                severity: .info, ruleID: id,
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
                    message: "Possible duplicate: \(profile.displayName) and \(other.displayName) (score: \(String(format: "%.2f", score)))"
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
