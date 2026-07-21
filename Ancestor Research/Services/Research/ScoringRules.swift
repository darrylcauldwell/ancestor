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

        // Scribal contractions and Latin register forms (DS-05): resolve
        // either side to its canonical modern form and match when they agree
        // — 'WM' vs 'WILLIAM', 'THOS' vs 'THOMAS', 'GULIELMUS' vs 'WILLIAM'.
        if let canonA = scribalContractions[a], canonA == b { return 0.85 }
        if let canonB = scribalContractions[b], canonB == a { return 0.85 }
        if let canonA = scribalContractions[a],
           let canonB = scribalContractions[b],
           canonA == canonB { return 0.85 }

        // Single character difference (typo/transcription)
        if a.count == b.count {
            let diffs = zip(a, b).filter { $0 != $1 }.count
            if diffs == 1 { return 0.7 }
        }

        // Single insertion/deletion — unequal-length transcription variant
        // (DS-06): BROOKES/BROOKS, SIMMS/SIMS, the most common UK surname
        // variant class, previously scored 0.0 and hard-failed the gate.
        // Levenshtein-1 across a length difference of exactly one.
        if isSingleIndel(a, b) { return 0.7 }

        return 0.0
    }

    /// True when `a` and `b` differ by a single insertion/deletion — their
    /// lengths differ by exactly one and the shorter is the longer with one
    /// character removed. (Edit distance 1 for the unequal-length case; the
    /// equal-length single-substitution case is handled separately.)
    static func isSingleIndel(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        guard long.count - short.count == 1 else { return false }
        var i = 0, j = 0
        var skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] {
                i += 1; j += 1
            } else {
                if skipped { return false }   // a second mismatch → distance > 1
                skipped = true
                j += 1                         // consume the extra char in `long`
            }
        }
        return true
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
        // Owner case 2026-07-21: Geoff Bonsall's marriage record was
        // registered "Geoffrey" — pair them so scoring rates the pair as
        // nickname-grade AND outbound queries fan Geoff→GEOFFREY.
        "GEOFF": "GEOFFREY", "GEOFFREY": "GEOFF",
        // Ada — a hugely popular standalone Victorian/Edwardian name that is
        // ALSO a diminutive of Adelaide / Adeline / Adela / Adelina. Mapping
        // the long forms to a shared "ADA" canonical lets a subject known as
        // "Ada" match a record registered under any of the fuller names, and
        // the fuller names match each other (owner case 2026-07-19: Aunty Ada,
        // wife of Eric Cauldwell, may be registered as Adelaide/Adeline).
        "ADELAIDE": "ADA",
        "ADELINE": "ADA",
        "ADELA": "ADA",
        "ADELINA": "ADA",
    ]

    /// Scribal contractions and Latin register forms → canonical modern
    /// given name (DS-05). Enumerator shorthand ('Wm', 'Thos', 'Jno') and
    /// pre-1733 parish-register Latin ('Gulielmus', 'Johannes') scored 0.0
    /// against the modern form because they are neither a contiguous
    /// substring nor an equal-length single-char typo. Only unambiguous
    /// entries: forms that are also standalone modern names (Maria, Anna,
    /// Eliza) are deliberately excluded — a false match writes the wrong
    /// person, a miss only defers a record to a lead. Substring-recoverable
    /// contractions (Geo⊂George, Thoˢ handled, Eliz⊂Elizabeth) are omitted
    /// because the containment rung already catches them.
    static let scribalContractions: [String: String] = [
        // Census / register contractions
        "WM": "WILLIAM", "WILLM": "WILLIAM",
        "JNO": "JOHN",
        "THOS": "THOMAS",
        "CHAS": "CHARLES",
        "JAS": "JAMES",
        "RICHD": "RICHARD", "RICD": "RICHARD",
        "ROBT": "ROBERT",
        "EDWD": "EDWARD",
        "SAML": "SAMUEL",
        "BENJ": "BENJAMIN",
        "DANL": "DANIEL",
        "MARGT": "MARGARET",
        "FREDK": "FREDERICK",
        "ALEXR": "ALEXANDER",
        "HENY": "HENRY",
        // Latin register forms (parish registers, largely pre-1733)
        "GULIELMUS": "WILLIAM", "GUILIELMUS": "WILLIAM",
        "JOHANNES": "JOHN", "JOHANNIS": "JOHN",
        "JACOBUS": "JAMES",
        "CAROLUS": "CHARLES",
        "GEORGIUS": "GEORGE",
        "HENRICUS": "HENRY",
        "RICARDUS": "RICHARD",
        "ROBERTUS": "ROBERT",
        "EDWARDUS": "EDWARD",
        "RADULPHUS": "RALPH",
        "GALFRIDUS": "GEOFFREY",
        "ELIZABETHA": "ELIZABETH",
        "MARGARETA": "MARGARET",
    ]

    /// True when `record` (a record's FIRST given-name token) is a FULLER
    /// FORM of the profile's stored given name — "GEOFF" → "GEOFFREY"
    /// (prefix expansion), "ADA" → "ADELAIDE" (known nickname family,
    /// longer form). Equality is NOT fuller. Prefix expansion requires at
    /// least 3 stored characters so "Jo" can't claim every John / Joseph /
    /// Joan record. Drives the name-enrichment absorption (a fuller form on
    /// an APPLIED record is worth capturing; the overwrite policy decides
    /// whether it writes or lands as a cited alternative).
    static func isFullerGivenForm(record: String, profile: String) -> Bool {
        let r = record.uppercased().trimmingCharacters(in: .whitespaces)
        let p = profile.uppercased().trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty, !p.isEmpty, r != p else { return false }
        if p.count >= 3 && r.hasPrefix(p) { return true }
        if r.count > p.count && givenNameVariants(of: p).contains(r) { return true }
        return false
    }

    /// Emission-grade variant of `isFullerGivenForm`: the record form must be
    /// an ATTESTED equivalent of the stored name (a member of its nickname
    /// cluster), not a raw prefix expansion. Raw prefixes bless outright
    /// renames — JOSEPH→JOSEPHINE, ANN→ANNE, CHRISTIAN→CHRISTIANA — which
    /// matters because the absorption plan can OVERWRITE an import-tier first
    /// name. `isFullerGivenForm` remains the looser *compatibility* check;
    /// this gate decides what the plan actually emits as a write.
    static func isAttestedFullerGivenForm(record: String, profile: String) -> Bool {
        let r = record.uppercased().trimmingCharacters(in: .whitespaces)
        let p = profile.uppercased().trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty, !p.isEmpty, r != p, r.count > p.count else { return false }
        return givenNameVariants(of: p).contains(r)
    }

    /// True when `record` middle content STRICTLY EXPANDS the stored middle:
    /// every stored token is a prefix of the corresponding record token
    /// ("W" → "William", "W" → "William Henry") and the record adds real
    /// content. Directional — "W" never qualifies against a stored "William",
    /// so a record's initial can never degrade a full middle name.
    static func isFullerMiddleForm(record: String, stored: String) -> Bool {
        let rTokens = record.uppercased().split(separator: " ").map(String.init)
        let sTokens = stored.uppercased().split(separator: " ").map(String.init)
        guard !rTokens.isEmpty, !sTokens.isEmpty, rTokens.count >= sTokens.count else { return false }
        var expands = rTokens.count > sTokens.count
        for (s, r) in zip(sTokens, rTokens) {
            guard r.hasPrefix(s) else { return false }
            if r.count > s.count { expands = true }
        }
        return expands
    }

    /// All given-name equivalents of `name` for outbound query fan-out — so a
    /// person registered under a formal name (Harry→HENRY) or a sibling
    /// nickname (Elsie→ELIZABETH, and thence BETTY/LIZZIE) is found by the
    /// sources, not just recognised in returned records. The nickname table
    /// mixes bidirectional pairs and many-nicknames→one-canonical, so this
    /// walks the transitive equivalence cluster (BFS) rather than a single
    /// lookup. Uppercased; empty for names with no equivalents. Bounded — the
    /// table is small and clusters are tiny.
    static func givenNameVariants(of name: String) -> [String] {
        let start = name.uppercased().trimmingCharacters(in: .whitespaces)
        guard !start.isEmpty else { return [] }
        var cluster: Set<String> = [start]
        var frontier: Set<String> = [start]
        var guardCount = 0
        while !frontier.isEmpty && guardCount < 20 {
            guardCount += 1
            var next: Set<String> = []
            for n in frontier {
                // Forward: this name's mapped equivalent.
                if let mapped = nicknameEquivalents[n], !cluster.contains(mapped) { next.insert(mapped) }
                // Reverse: every name that maps INTO this one.
                for (nick, canon) in nicknameEquivalents where canon == n && !cluster.contains(nick) {
                    next.insert(nick)
                }
            }
            cluster.formUnion(next)
            frontier = next
        }
        cluster.remove(start)
        return cluster.sorted()
    }

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
