import Foundation

/// Shared scoring primitives consumed by both AuditEngine and RecordScorer.
/// Faithfully ported from Python's agent/rules.py.
///
/// Hard rules: always true, mechanically enforced.
/// Soft rules: scoring, not rejecting.
/// Source rules: what each data source can/can't tell you.
/// Pattern rules: genealogical patterns suggesting follow-up research.
nonisolated struct ScoringRules {

    // MARK: - Hard Rules

    static func checkBirthBeforeDeath(birthYear: Int, deathYear: Int) -> Bool {
        birthYear <= deathYear
    }

    static func checkParentAgeGap(parentBirth: Int, childBirth: Int) -> Bool {
        (childBirth - parentBirth) >= 14
    }

    static func checkMarriageAge(birthYear: Int, marriageYear: Int) -> Bool {
        (marriageYear - birthYear) >= 16
    }

    static func checkLifespan(birthYear: Int, deathYear: Int) -> Bool {
        (deathYear - birthYear) <= 110
    }

    static func checkNotMarriedAfterDeath(marriageYear: Int, deathYear: Int) -> Bool {
        marriageYear <= deathYear
    }

    /// Check if an event is temporally possible for a person.
    /// Returns nil if OK, or a string describing the impossibility.
    static func checkTemporalPossibility(birthYear: Int, eventYear: Int, eventType: String) -> String? {
        switch eventType {
        case "birth":
            let diff = abs(eventYear - birthYear)
            if diff > 5 {
                return "birth year \(eventYear) is \(diff) years from expected ~\(birthYear)"
            }

        case "death":
            if eventYear < birthYear {
                return "died \(eventYear) before birth \(birthYear)"
            }
            let age = eventYear - birthYear
            if age > 110 {
                return "died \(eventYear), would be \(age) years old"
            }

        case "marriage":
            if eventYear < birthYear + 16 {
                return "married \(eventYear), would be \(eventYear - birthYear) years old"
            }
            if eventYear > birthYear + 80 {
                return "married \(eventYear), would be \(eventYear - birthYear) years old"
            }

        case "census":
            if eventYear < birthYear {
                return "census \(eventYear) is before birth \(birthYear)"
            }

        default:
            break
        }
        return nil
    }

    /// Validate a record against known dates.
    /// Returns "valid", "impossible: reason", or "implausible: reason".
    static func validateRecord(recordYear: Int, birthYear: Int?, deathYear: Int?, recordType: String) -> String {
        guard let birthYear else { return "valid" }

        if let issue = checkTemporalPossibility(birthYear: birthYear, eventYear: recordYear, eventType: recordType) {
            if issue.contains("before birth") {
                return "impossible: \(issue)"
            }
            return "implausible: \(issue)"
        }

        if let deathYear {
            if recordType == "marriage" && recordYear > deathYear {
                return "impossible: married \(recordYear) after death \(deathYear)"
            }
            if recordType == "census" && recordYear > deathYear {
                return "impossible: census \(recordYear) after death \(deathYear)"
            }
        }

        return "valid"
    }

    // MARK: - Tolerances

    /// Legacy single-constant tolerances. Retained for the `yearsMatch`
    /// default parameter and the (one) call site that hasn't migrated to
    /// `tolerance(for:)`. New code should prefer the per-type function so
    /// the tolerance reflects the inherent fuzziness of each record kind:
    /// civil registrations are tight (±1 for the Q4-birth/Q1-registration
    /// boundary slip), census is loose (±5 because age misreporting in
    /// 19th-century enumeration is endemic), baptism is loose (children
    /// baptised years after birth, adult baptism), pedigree is exact.
    static let censusAgeTolerance = 2
    static let birthYearTolerance = 2
    static let deathAgeTolerance = 1

    /// Tolerance (in years) for the scorer's date gate when comparing a
    /// record's year against the subject's known year window. Tiered by
    /// record type — not by subject precision, because subject precision
    /// is already encoded in `birthYearFrom`/`birthYearTo` (a "ABT 1880"
    /// subject already has from=1875, to=1885).
    static func tolerance(for recordType: RecordType) -> Int {
        switch recordType {
        case .birth, .death, .military: return 1
        case .probate, .burial: return 2
        case .baptism, .christening, .census: return 5
        case .parish: return 3
        case .marriage: return 1
        case .pedigree: return 0
        }
    }

    static func yearsMatch(_ yearA: Int, _ yearB: Int, tolerance: Int = birthYearTolerance) -> Bool {
        abs(yearA - yearB) <= tolerance
    }

    // MARK: - Source Rules

    static let civilRegistrationStart = 1837
    static let mothersMaidenNameStart = 1911
    static let spouseSurnameStart = 1912
    static let freebmdBakewellCutoff = 1941
    static let censusYears = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921]
    static let ww1Eligibility = 1880...1900
    static let ww2Eligibility = 1900...1927

    static func militaryEligible(birthYear: Int, gender: Gender?) -> [String] {
        guard gender == .male else { return [] }
        var wars: [String] = []
        if ww1Eligibility.contains(birthYear) { wars.append("WW1") }
        if ww2Eligibility.contains(birthYear) { wars.append("WW2") }
        return wars
    }

    static func preRegistrationBirth(_ birthYear: Int?) -> Bool {
        guard let birthYear else { return false }
        return birthYear < civilRegistrationStart
    }

    static func militaryDeathNotInCivilRegister(_ deathLocation: String) -> Bool {
        let abroadKeywords = ["france", "belgium", "flanders", "gallipoli",
                              "tunisia", "italy", "egypt", "burma", "germany"]
        let lower = deathLocation.lowercased()
        return abroadKeywords.contains { lower.contains($0) }
    }

    // MARK: - Name Similarity (0.0–1.0)

    /// Score name similarity handling common genealogical variations.
    /// Ported faithfully from Python's name_similarity_score().
    /// User-learned name equivalences keyed by project UUID (M25). Each
    /// project's learnings stay isolated from others — important when the
    /// user has multiple project windows open simultaneously. The
    /// `nil`-keyed bucket is reserved for tests and pre-project callers.
    nonisolated(unsafe) private static var equivalencesByProject: [UUID?: Set<String>] = [:]
    private static let equivalencesLock = NSLock()

    /// Test/legacy accessor — returns the `nil`-keyed (project-less) bucket.
    /// Production code should use `learnedEquivalences(for:)` with a real
    /// project UUID instead.
    static var learnedEquivalences: Set<String> {
        get {
            equivalencesLock.lock()
            defer { equivalencesLock.unlock() }
            return equivalencesByProject[nil] ?? []
        }
        set {
            equivalencesLock.lock()
            defer { equivalencesLock.unlock() }
            equivalencesByProject[nil] = newValue
        }
    }

    /// Returns the equivalence set for a given project, or the legacy
    /// project-less bucket if `projectID` is nil.
    static func learnedEquivalences(for projectID: UUID?) -> Set<String> {
        equivalencesLock.lock()
        defer { equivalencesLock.unlock() }
        return equivalencesByProject[projectID] ?? []
    }

    /// Register a learned equivalence pair (e.g. "ROBERT" ↔ "BOB"). Stored
    /// against `projectID` if provided so multi-window scenarios stay
    /// isolated; pass nil for the legacy global bucket.
    static func addLearnedEquivalence(_ nameA: String, _ nameB: String, projectID: UUID? = nil) {
        let a = nameA.uppercased()
        let b = nameB.uppercased()
        equivalencesLock.lock()
        defer { equivalencesLock.unlock() }
        equivalencesByProject[projectID, default: []].insert("\(a)=\(b)")
        equivalencesByProject[projectID, default: []].insert("\(b)=\(a)")
    }

    static func nameSimilarity(_ nameA: String, _ nameB: String, projectID: UUID? = nil) -> Double {
        let a = nameA.uppercased().trimmingCharacters(in: .whitespaces)
        let b = nameB.uppercased().trimmingCharacters(in: .whitespaces)

        if a == b { return 1.0 }

        // User-learned equivalences (highest priority after exact match).
        // M25: scoped per project so multi-window with different open
        // projects doesn't cross-pollinate equivalences.
        if learnedEquivalences(for: projectID).contains("\(a)=\(b)") { return 0.9 }

        // Spelling normalisation (AU/A, OU/O swaps)
        let aNorm = a.replacingOccurrences(of: "AU", with: "A")
                     .replacingOccurrences(of: "OU", with: "O")
        let bNorm = b.replacingOccurrences(of: "AU", with: "A")
                     .replacingOccurrences(of: "OU", with: "O")
        if aNorm == bNorm { return 0.95 }

        // One contains the other
        if a.contains(b) || b.contains(a) { return 0.8 }

        // Nickname equivalents
        if nicknameEquivalents[a] == b || nicknameEquivalents[b] == a { return 0.85 }
        // Two diminutives of one formal name match each other too
        // (BETTY ~ ELSIE via ELIZABETH, WILLIE ~ BILL via WILLIAM) — the
        // flat pair table can't express transitivity, the shared
        // canonical can.
        if let canonicalA = nicknameEquivalents[a],
           let canonicalB = nicknameEquivalents[b],
           canonicalA == canonicalB { return 0.85 }

        // Single character difference (typo/transcription)
        if a.count == b.count {
            let diffs = zip(a, b).filter { $0 != $1 }.count
            if diffs == 1 { return 0.7 }
        }

        return 0.0
    }

    /// Bidirectional nickname lookup — ported from Python exactly.
    static let nicknameEquivalents: [String: String] = [
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
        // Elsie began as an Elizabeth/Elspeth diminutive before becoming a
        // standalone name (owner case 2026-07-15: Elsie Twyford, known as
        // Betty — either could be the registered form).
        "ELSIE": "ELIZABETH",
        "FLORRIE": "FLORENCE", "FLORENCE": "FLORRIE",
    ]

    // MARK: - Pattern Rules

    /// If mother-in-law has a different surname, that's the wife's maiden name.
    static func maidenNameFromMotherInLaw(household: [HouseholdMember], headSurname: String) -> String? {
        for member in household {
            let rel = member.relationship.lowercased()
            if rel.contains("mother") && rel.contains("law") {
                let milParts = member.name.split(separator: " ")
                if let milSurname = milParts.last {
                    let upper = milSurname.uppercased()
                    if upper != headSurname.uppercased() {
                        return String(upper)
                    }
                }
            }
        }
        return nil
    }

    /// Gaps >threshold years between children suggest infant deaths.
    static func childGapSuggestsDeath(birthYears: [Int], threshold: Int = 3) -> [(Int, Int)] {
        guard birthYears.count >= 2 else { return [] }
        let sorted = birthYears.sorted()
        var gaps: [(Int, Int)] = []
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1] - sorted[i]
            if gap > threshold {
                gaps.append((sorted[i], sorted[i + 1]))
            }
        }
        return gaps
    }

    /// Person present in one census but absent from next — suggests death/emigration/marriage/military.
    static func absentFromCensusSuggests(birthYear: Int, lastSeenYear: Int, gender: Gender?) -> [String] {
        var suggestions = ["death", "emigration"]
        if gender == .female {
            suggestions.append("marriage (changed surname)")
        }
        if gender == .male {
            let wars = militaryEligible(birthYear: birthYear, gender: .male)
            if !wars.isEmpty {
                suggestions.append("military service (\(wars.joined(separator: ", ")))")
            }
        }
        return suggestions
    }

    // MARK: - Convergence Scoring

    /// More independent sources confirming the same fact = higher confidence.
    static func convergenceScore(matchingSources: Int) -> Double {
        if matchingSources <= 0 { return 0.0 }
        if matchingSources == 1 { return 0.5 }
        if matchingSources == 2 { return 0.75 }
        return min(0.9 + Double(matchingSources - 3) * 0.03, 1.0)
    }

    // MARK: - Location Validation

    /// Normalise a location string — ensures English counties end with ", England".
    static func normaliseLocation(_ location: String) -> String {
        guard !location.isEmpty else { return location }

        let parts = location.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let last = parts.last?.lowercased() ?? ""

        if ["england", "united kingdom", "wales", "scotland"].contains(last) {
            return parts.joined(separator: ", ")
        }

        if englishCounties.contains(last) {
            return (parts + ["England"]).joined(separator: ", ")
        }

        return parts.joined(separator: ", ")
    }

    /// Reject enrichment if the proposed record is from a different county.
    /// Returns nil if compatible, or an error string.
    static func validateEnrichmentLocation(proposedPlace: String, profileBirthLocation: String) -> String? {
        guard !proposedPlace.isEmpty, !profileBirthLocation.isEmpty else { return nil }

        let knownLower = profileBirthLocation.lowercased()
        let proposedLower = proposedPlace.lowercased()

        // Find profile's county
        var profileCounty: String?
        for county in englishCounties {
            if knownLower.contains(county) {
                profileCounty = county
                break
            }
        }
        guard let profileCounty else { return nil }

        // Same county?
        if proposedLower.contains(profileCounty) { return nil }

        // Different county?
        for county in englishCounties {
            if proposedLower.contains(county) && county != profileCounty {
                return "record from \(county) but profile is from \(profileCounty)"
            }
        }

        return nil
    }

    // MARK: - Date Validation for Enrichment

    /// Validate proposed date value against known birth/death.
    /// Returns nil if valid, or error string.
    static func validateEnrichmentDate(field: String, proposedValue: String,
                                       currentBirth: String = "", currentDeath: String = "") -> String? {
        let proposedYear = extractYear(from: proposedValue)
        guard let proposedYear else {
            return "no valid year in '\(proposedValue)'"
        }

        let birthYear = extractYear(from: currentBirth)
        let deathYear = extractYear(from: currentDeath)

        if (field == "DeathDate" || field == "death_date"), let birthYear {
            if proposedYear < birthYear {
                return "death \(proposedYear) before birth \(birthYear)"
            }
        }

        if (field == "BirthDate" || field == "birth_date"), let deathYear {
            if proposedYear > deathYear {
                return "birth \(proposedYear) after death \(deathYear)"
            }
        }

        return nil
    }

    /// Extract a 4-digit year (1000-2029) from a string.
    static func extractYear(from string: String) -> Int? {
        let pattern = #"\b(1[0-9]\d{2}|20[0-2]\d)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return Int(string[range])
    }

    // MARK: - Geography (delegates to RegionConfig)
    //
    // Each helper takes the subject's home Chapman code (e.g. "DBY", "LEI").
    // For codes whose RegionConfig isn't yet populated, the rich helpers
    // (parishes, non-local map) return empty / nil — the scorer downgrades
    // local-boosting accordingly rather than mis-classifying everything as
    // "local-Derbyshire" the way it did before parameterisation.
    // See RESEARCH_AXES_SPEC.md §3 / §8 Change 1.

    /// Check if a district is in the subject's home county.
    /// Two-tier lookup: the rich per-county RegionConfig (only DBY today)
    /// matches against its hand-curated districtParishes; for any other
    /// home county, falls through to FreeBMDDistrictCatalogue's tagged
    /// entries. Catalogue lookup is case-insensitive on district name.
    static func isLocalDistrict(_ district: String, forHomeChapman code: String) -> Bool {
        if let config = RegionConfig.config(forChapmanCode: code),
           config.isLocalDistrict(district) {
            return true
        }
        let needle = district.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "", options: .caseInsensitive)
            .lowercased()
        let upper = code.uppercased()
        return FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: upper)
            .contains { $0.name.lowercased() == needle }
    }

    /// Returns the location name if district is outside the home county, else nil.
    static func isNonLocal(_ district: String, forHomeChapman code: String) -> String? {
        guard let config = RegionConfig.config(forChapmanCode: code) else { return nil }
        return config.nonLocalLocation(for: district)
    }

    /// The Chapman code of the historical county a registration district belongs
    /// to — for ANY county, not just the home one (national
    /// `FreeBMDDistrictCatalogue`). Lets clustering judge whether two records
    /// are in the same county even when that county is foreign to the subject
    /// (ROADMAP clustering item b). nil when the district isn't in the
    /// catalogue. No hardcoded regions — the mapping is data, not code.
    static func countyCode(forDistrict district: String) -> String? {
        FreeBMDDistrictCatalogue.shared.district(named: district)?.chapmanCode?.uppercased()
    }

    /// Return parishes covered by a registration district within the home county.
    /// Prefers the rich per-county RegionConfig when available (DBY only);
    /// falls through to the FreeBMDDistrictCatalogue's nationally-enriched
    /// parish lists for everywhere else.
    static func parishesInDistrict(_ district: String, forHomeChapman code: String) -> [String] {
        if let config = RegionConfig.config(forChapmanCode: code) {
            let local = config.parishes(in: district)
            if !local.isEmpty { return local }
        }
        return FreeBMDDistrictCatalogue.shared.district(named: district)?.parishes ?? []
    }

    /// Find which registration district covers a parish within the home county.
    /// Same two-tier fallback as `parishesInDistrict`.
    static func districtForParish(_ parish: String, forHomeChapman code: String) -> String? {
        if let config = RegionConfig.config(forChapmanCode: code),
           let local = config.district(for: parish) {
            return local
        }
        return FreeBMDDistrictCatalogue.shared
            .district(forParish: parish, inChapman: code)?.name
    }

    /// Slice 8 — parish-level geography tolerance.
    /// True when `parish` resolves to a registration district that's
    /// local to the home county. Mirrors Python `is_derbyshire_district`
    /// but at parish granularity: a census record reporting birthplace
    /// "Windley" doesn't contain the word "Derbyshire" verbatim, so the
    /// district-level geography gate's substring check misses it — even
    /// though Windley is in Belper district which is in DBY. This helper
    /// closes that gap.
    static func isLocalParish(_ parish: String, forHomeChapman code: String) -> Bool {
        guard let district = districtForParish(parish, forHomeChapman: code) else {
            return false
        }
        return isLocalDistrict(district, forHomeChapman: code)
    }

    /// Slice 8 — adjacent-parish tolerance for census birthplace
    /// variance. Mirrors Python `census_birthplace_reliability`'s
    /// "Mugginton/Windley are adjacent parishes — not contradictions"
    /// concern. Two parishes are treated as adjacent when they share
    /// the same registration district (the cheap, MVP heuristic — a
    /// hand-curated parish-adjacency JSON would be more precise but
    /// "same district" captures most of the value because UK registration
    /// districts were sized around walking distance).
    ///
    /// Returns true on case-insensitive name equality (trivially adjacent
    /// to themselves) and when both names resolve to the same local
    /// district. Returns false for unknown parishes or cross-district
    /// pairs (those are real geographic discrepancies and should not
    /// be quietly tolerated).
    static func parishesShareLocalDistrict(
        _ parishA: String,
        _ parishB: String,
        forHomeChapman code: String
    ) -> Bool {
        let trimmedA = parishA.trimmingCharacters(in: .whitespaces)
        let trimmedB = parishB.trimmingCharacters(in: .whitespaces)
        guard !trimmedA.isEmpty, !trimmedB.isEmpty else { return false }
        if trimmedA.caseInsensitiveCompare(trimmedB) == .orderedSame {
            return true
        }
        guard let districtA = districtForParish(trimmedA, forHomeChapman: code),
              let districtB = districtForParish(trimmedB, forHomeChapman: code)
        else { return false }
        return districtA.caseInsensitiveCompare(districtB) == .orderedSame
            && isLocalDistrict(districtA, forHomeChapman: code)
    }

    // MARK: - Reference Data

    static let englishCounties: Set<String> = [
        "derbyshire", "nottinghamshire", "staffordshire", "leicestershire",
        "yorkshire", "lancashire", "cheshire", "warwickshire", "lincolnshire",
        "kent", "surrey", "middlesex", "sussex", "essex", "suffolk", "norfolk",
        "cambridgeshire", "oxfordshire", "berkshire", "hampshire", "dorset",
        "somerset", "devon", "cornwall", "wiltshire", "gloucestershire",
        "worcestershire", "herefordshire", "shropshire", "rutland",
        "huntingdonshire", "bedfordshire", "hertfordshire", "buckinghamshire",
        "northamptonshire", "westmorland", "cumberland", "durham",
        "northumberland",
    ]
}
