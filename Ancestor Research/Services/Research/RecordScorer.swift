import Foundation

// MARK: - Accept policy

/// THE record-level accept predicate — the single source of truth for
/// "should an accepted cluster/record write this record's data to the
/// tree?". Lives beside `RecordVerdict` so every consumer (cluster-review
/// badges and Apply button, `applyCluster`'s loop, any future auto-apply
/// path) applies the identical bar; it previously lived on
/// `ResearchViewModel` with a "if you change one, change both" comment.
///
/// Distinct from the MCP §14.3 auto-approval gate and the run-watcher's
/// proposal-promotion gate — those govern *autonomy* (may the machine act
/// without a human?) and are deliberately stricter; this governs record
/// quality only.
extension RecordScorer {

    /// True when the record is a marriage AND the scorer's `familyContext`
    /// gate passed because the record's spouse matches the subject's known
    /// spouse. Used to bypass the `verdict == .fact` filter for the
    /// subject-marriage-to-existing-spouse-edge case where FreeBMD
    /// transcription gaps demote an otherwise-correct match to `.lead`.
    nonisolated static func recognisesKnownSpouse(_ scored: ScoredRecord) -> Bool {
        guard case .marriage = scored.record else { return false }
        return scored.gates.contains { $0.gate == .familyContext && $0.outcome == .pass }
    }

    /// Would applying this record write its data to the profile?
    nonisolated static func wouldApply(_ scored: ScoredRecord) -> Bool {
        scored.verdict == .fact || recognisesKnownSpouse(scored)
    }
}

/// Deterministic record classifier — fact, lead, or impossible.
/// Faithfully ported from Python's agent/scorer.py.
///
/// A record is a FACT only if ALL gates pass. If any gate fails
/// but the record looks promising, it's a LEAD. If a hard rule
/// is violated, it's IMPOSSIBLE.
nonisolated struct RecordScorer {

    /// Classify a source record against a known person.
    static func classify(
        record: SourceRecord,
        subject: ResearchSubject,
        searchType: RecordType
    ) -> ScoredRecord {
        var gates: [GateResult] = []
        var failed: [ScoringGate] = []

        // GATE 1: NAME
        let nameResult = checkName(record: record, subject: subject)
        gates.append(nameResult)
        if nameResult.outcome == .fail { failed.append(.name) }

        // GATE 2: DATE
        let dateResult = checkDate(record: record, subject: subject, searchType: searchType)
        gates.append(dateResult)
        if dateResult.outcome == .impossible {
            return ScoredRecord(
                id: record.id, record: record, verdict: .impossible,
                gates: gates, summary: summarise(record: record, searchType: searchType)
            )
        }
        if dateResult.outcome == .fail { failed.append(.date) }

        // GATE 3: GEOGRAPHY
        let geoResult = checkGeography(record: record, subject: subject)
        gates.append(geoResult)
        if geoResult.outcome == .fail { failed.append(.geography) }

        // GATE 4: FAMILY CONTEXT (bonus)
        let familyResult = checkFamilyContext(record: record, subject: subject)
        if familyResult.outcome != .skip {
            gates.append(familyResult)
        }

        // VERDICT
        // Hard fail on name → impossible (wrong person).
        // Hard fail on geography → mode-dependent:
        //   * Verify / Extend / Discover are focused; a record explicitly
        //     in another country is noise the user doesn't want cluttering
        //     a Belper-area sweep → `.impossible`, filtered from clustering.
        //   * `.all` is the "throw everything at it" mode — the user has
        //     opted in to maximum recall, so demote to `.lead` and let the
        //     user assess (covers emigration / overseas service / postings
        //     that legitimately produce foreign records).
        // All gates pass with no softFails → fact.
        // All gates pass but has softFails (geography unknown-district /
        // family-context noise) → lead.
        let hasSoftFails = gates.contains { $0.outcome == .softFail }
        let baseVerdict: RecordVerdict
        if failed.isEmpty && !hasSoftFails {
            baseVerdict = .fact
        } else if failed.isEmpty && hasSoftFails {
            baseVerdict = .lead
        } else if failed.contains(.name) {
            baseVerdict = .impossible
        } else if failed.contains(.geography) {
            baseVerdict = subject.mode == .all ? .lead : .impossible
        } else {
            baseVerdict = .lead
        }

        // Thin-subject verdict cap (ENGINE_FOUNDATION_SPEC #Change1).
        // When the subject has no given name (or a 25+-year birth-year
        // window), the gates can't meaningfully discriminate — a passing
        // record is one of many surname-sharers. Refuse to assert .fact;
        // demote to .lead so convergence (or placeholder write-back per
        // #Change2) decides. Hard fails (.impossible) flow through.
        let verdict: RecordVerdict
        if baseVerdict == .fact && InformationDensity.from(subject: subject) == .thin {
            verdict = .lead
        } else {
            verdict = baseVerdict
        }

        return ScoredRecord(
            id: record.id, record: record, verdict: verdict,
            gates: gates, summary: summarise(record: record, searchType: searchType)
        )
    }

    // MARK: - Gate 1: Name

    private static func checkName(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        let personSurname = (subject.surname ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let personGivenRaw = (subject.givenName ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let personMiddleField = (subject.middleName ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        // Mirrors the dispatcher's `surnamesToProbe` widenings — every
        // surname put on the wire must be accepted back, otherwise a
        // legitimate record returned under the alternate form fails the
        // name gate and lands `.impossible`. Two widening paths:
        //
        // * **Married axis** — for death-shape + census record types,
        //   the subject's `marriedSurname` is equally acceptable. UK
        //   indexes file deceased married women under married surname
        //   (probate, FreeBMD post-1969 deaths, FAG memorials).
        //
        // * **Maiden axis** — for pre-marriage record types (birth,
        //   baptism, christening, marriage, parish, census), an
        //   inverted-imported female (surname = married, maiden
        //   recoverable as `familyContext.fatherSurname`) has the
        //   maiden surname on the wire too. Without acceptance here,
        //   FreeBMD's "Elizabeth CALDWELL Mar 1845" gets rejected as
        //   name-mismatch against subject.surname "Beighton".
        let acceptableSurnames: [String] = {
            var set: [String] = []
            if !personSurname.isEmpty { set.append(personSurname) }

            let married = (subject.marriedSurname ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            if !married.isEmpty, married != personSurname {
                let acceptsMarried: Bool = switch record.recordType {
                case .death, .burial, .probate, .military, .census: true
                default: false
                }
                if acceptsMarried { set.append(married) }
            }

            if subject.gender == .female,
               let fatherRaw = subject.familyContext?.fatherSurname {
                let father = fatherRaw.uppercased().trimmingCharacters(in: .whitespaces)
                if !father.isEmpty, father != personSurname {
                    let acceptsMaiden: Bool = switch record.recordType {
                    case .birth, .baptism, .christening, .marriage, .parish, .census: true
                    default: false
                    }
                    if acceptsMaiden { set.append(father) }
                }
            }

            return set
        }()

        // Derive effective given + middle for matching. GEDCOM import puts
        // the full given string (e.g. "Ernest Victor") into firstName and
        // leaves middleName empty — `GEDCOMParser.parseGEDCOMName` returns
        // the whole pre-surname segment as one string, no middle split.
        // Without compensation, the middle-name guard at line ~191 below
        // never fires for any imported profile, and an "Ernest Peter"
        // record would pass the gate against an "Ernest Victor" subject
        // because both share "ERNEST" as their first token.
        //
        // Rule: when `subject.middleName` is explicitly set, trust it.
        // Otherwise, if `subject.givenName` has multiple tokens, treat
        // the first token as effective given and the rest as effective
        // middle.
        let personGiven: String
        let personMiddle: String
        if !personMiddleField.isEmpty {
            personGiven = personGivenRaw
            personMiddle = personMiddleField
        } else {
            let givenTokens = personGivenRaw.split(separator: " ").map(String.init)
            if givenTokens.count >= 2 {
                personGiven = givenTokens[0]
                personMiddle = givenTokens.dropFirst().joined(separator: " ")
            } else {
                personGiven = personGivenRaw
                personMiddle = ""
            }
        }

        var recordSurname = (record.surname ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        var recordGiven = (record.givenName ?? record.name ?? "").uppercased().trimmingCharacters(in: .whitespaces)

        // FreeCen returns full name in "name" field — split it
        if recordSurname.isEmpty && !recordGiven.isEmpty {
            let parts = recordGiven.split(separator: " ")
            if parts.count >= 2 {
                recordGiven = String(parts[0])
                recordSurname = String(parts.last!)
            }
        }

        if recordSurname.isEmpty || acceptableSurnames.isEmpty {
            return GateResult(gate: .name, outcome: .fail, reason: "cannot compare — missing surname")
        }

        // Best score across acceptable surnames (maiden + optionally married
        // for death-shape record types). Pass if any clears the 0.7 threshold.
        let bestSurnameScore = acceptableSurnames
            .map { ScoringRules.nameSimilarity(recordSurname, $0) }
            .max() ?? 0
        if bestSurnameScore < 0.7 {
            let candidates = acceptableSurnames.joined(separator: "/")
            return GateResult(gate: .name, outcome: .fail, reason: "surname mismatch: \(recordSurname) vs \(candidates)")
        }
        let surnameScore = bestSurnameScore

        var givenScore = 0.5
        if !recordGiven.isEmpty && !personGiven.isEmpty {
            // Compare against just the first token of the record's given-name
            // field so a record like "JENNIFER M HOLMES" (surname split off
            // already, leaving "JENNIFER M") still matches subject given name
            // "JENNIFER" without being penalised by the middle initial.
            let recordFirstGiven = recordGiven.split(separator: " ").first.map(String.init) ?? recordGiven
            givenScore = ScoringRules.nameSimilarity(recordFirstGiven, personGiven)
            if givenScore < 0.7 {
                return GateResult(gate: .name, outcome: .fail, reason: "given name mismatch: \(recordGiven) vs \(personGiven)")
            }
        } else if recordGiven.isEmpty {
            return GateResult(gate: .name, outcome: .fail, reason: "no given name in record to compare")
        }

        // Middle-name guard. When subject has a middle name and the record
        // carries middle content too, require that content to be consistent
        // — same initial or substring match. Records with no middle content
        // pass (a bare "Jennifer Holmes" entry shouldn't be rejected for a
        // "Jennifer Margaret" subject). Closes the May 2026 ambiguity where
        // five candidate Jennifer Holmes 1947-49 births all passed the gate
        // because middle initials weren't compared.
        if !personMiddle.isEmpty, let recordMiddle = extractMiddleContent(from: recordGiven) {
            if !middleNameMatches(subjectMiddle: personMiddle, recordMiddle: recordMiddle) {
                return GateResult(gate: .name, outcome: .fail, reason: "middle name mismatch: subject=\(personMiddle) vs record=\(recordMiddle)")
            }
        }

        return GateResult(gate: .name, outcome: .pass, reason: String(format: "surname=%.2f, given=%.2f", surnameScore, givenScore))
    }

    /// Extract whatever sits between the first token and the last token of
    /// the record's given-name field. For "JENNIFER M HOLMES" we already
    /// split surname off earlier, leaving recordGiven = "JENNIFER M" (or
    /// "JENNIFER MARGARET"). Return "M" / "MARGARET", or nil when there's
    /// no middle content to compare.
    private static func extractMiddleContent(from recordGiven: String) -> String? {
        let tokens = recordGiven.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        // Everything after the first token is middle content (FreeBMD usually
        // gives the surname separately so all extra tokens here are middle).
        return tokens.dropFirst().joined(separator: " ")
    }

    /// True when the record's middle content is consistent with the subject's
    /// middle name. Same first initial = match. Substring match (subject
    /// "MARGARET" contains record "M", or vice versa) = match. Otherwise no.
    /// Case is already upper at call site.
    private static func middleNameMatches(subjectMiddle: String, recordMiddle: String) -> Bool {
        // Compare token-by-token so multi-middle names ("MARY ANN") still work.
        let subjectTokens = subjectMiddle.split(separator: " ").map(String.init)
        let recordTokens = recordMiddle.split(separator: " ").map(String.init)
        // Pair them up; if the subject has more tokens than the record, the
        // record's content is a prefix subset (subject "MARY ANN", record "M"
        // → compare M to MARY → first-initial match → pass).
        let pairs = zip(subjectTokens, recordTokens)
        for (sub, rec) in pairs {
            guard let subFirst = sub.first, let recFirst = rec.first else { continue }
            if subFirst != recFirst { return false }
            // Full token comparison when both are longer than initials.
            if sub.count > 1 && rec.count > 1 && sub != rec
               && !sub.hasPrefix(rec) && !rec.hasPrefix(sub) {
                return false
            }
        }
        return true
    }

    // MARK: - Gate 2: Date

    private static func checkDate(record: SourceRecord, subject: ResearchSubject, searchType: RecordType) -> GateResult {
        guard let birthLow = subject.birthYearFrom else {
            return GateResult(gate: .date, outcome: .fail, reason: "insufficient date information")
        }
        // Birth-year *window* — when subject is an accepted proposed relative,
        // `birthYearFrom`/`birthYearTo` form a range (e.g. 1931–1958, derived
        // from `subjectBirthYear ± parentAgeWindow`). Previously this gate
        // checked only against `birthYearFrom`, which made a 1948 record
        // fail despite landing inside the plausible 1931–1958 window —
        // blocking recursive auto-promote on every wizard- or proposal-
        // created ghost profile. The gate now passes for any record year
        // inside `[low - tol, high + tol]`; the cluster-level hypothesis
        // verdict downgrades the resulting `.fact` to a `.lead`-equivalent
        // when the window is wide and corroboration is thin.
        let birthHigh = subject.birthYearTo ?? birthLow

        let recordYear = extractYear(from: record)
        guard let recordYear else {
            return GateResult(gate: .date, outcome: .fail, reason: "insufficient date information")
        }

        let deathYear = subject.deathYearFrom
        // Validate against the *low* bound to mirror Python parity — pre-
        // window the engine used birthYearFrom as the single anchor, so
        // `validateRecord` was always called with that value. Keeping
        // parity here means existing IMPOSSIBLE rules (married before
        // birth, died before birth, etc.) still fire.
        let validation = ScoringRules.validateRecord(recordYear: recordYear, birthYear: birthLow, deathYear: deathYear, recordType: searchType.rawValue)
        if validation.hasPrefix("impossible") {
            return GateResult(gate: .date, outcome: .impossible, reason: validation)
        }

        let windowLabel = birthLow == birthHigh ? "~\(birthLow)" : "\(birthLow)–\(birthHigh)"

        switch searchType {
        case .death, .probate, .burial:
            // Probate/burial records carry a death year too (per
            // `extractYear` they return `deathYear`), so the death-axis
            // logic applies — record year is the death year, not a birth
            // year. Without this branch a 2017 probate record on a 1919-
            // born subject failed the default birth-window check by 98
            // years → impossible. With this branch the same record passes
            // when ageAtDeath is plausible. Spec §22 follow-up.

            // First constraint: when subject's death year is known,
            // record year must match it within tolerance. Closes the
            // Ernest-Sr-1959 false positive against Ernest-Victor-died-
            // 2017 — both are plausible ageAtDeath against birth 1919,
            // but only the 2017 record actually concerns this subject.
            // Without explicit deathYear (estimated subject or research
            // still discovering it), skip this constraint and fall to
            // ageAtDeath plausibility below.
            if let known = subject.deathYearFrom {
                let knownHigh = subject.deathYearTo ?? known
                // Per-type tolerance: .death is tight (±1), .probate/.burial
                // wider (±2) because grant/burial dates can lag death by
                // months and slip across the year boundary.
                let deathTol = ScoringRules.tolerance(for: searchType)
                let lower = known - deathTol
                let upper = knownHigh + deathTol
                if recordYear < lower || recordYear > upper {
                    let diff = recordYear < lower ? (lower - recordYear) : (recordYear - upper)
                    return GateResult(gate: .date, outcome: .fail, reason: "death year \(recordYear) is \(diff) years outside subject's known death window \(known)–\(knownHigh)")
                }
            }

            // Age at death is a *range* when birth is a window: ageAtDeath ∈
            // [recordYear - high, recordYear - low]. Either bound can fire
            // an impossible rule; pass when any plausible age in the range
            // falls in the [15, 100] band.
            let ageAtDeathHigh = recordYear - birthLow
            let ageAtDeathLow  = recordYear - birthHigh
            // Recorded age comes from different fields per record shape:
            // death records use `age`, probate records use `ageAtDeath`,
            // burial records typically have no recorded age.
            let recordedAge: Int? = {
                if case .death(let dr) = record { return dr.age }
                if case .probate(let pr) = record { return pr.ageAtDeath }
                return nil
            }()
            if let recordedAge {
                let matchesAnyAge = (ageAtDeathLow ... ageAtDeathHigh).contains { ScoringRules.yearsMatch(recordedAge, $0, tolerance: 2) }
                if matchesAnyAge {
                    return GateResult(gate: .date, outcome: .pass, reason: "age at death \(recordedAge) consistent with birth \(windowLabel)")
                }
                return GateResult(gate: .date, outcome: .fail, reason: "age at death \(recordedAge) inconsistent with birth \(windowLabel)")
            }
            // No recorded age — accept when the ageAtDeath range intersects
            // the plausible-lifespan band [15, 100].
            let rangeOverlapsPlausible = ageAtDeathHigh >= 15 && ageAtDeathLow <= 100
            if rangeOverlapsPlausible {
                return GateResult(gate: .date, outcome: .pass, reason: "died \(recordYear), age range \(max(15, ageAtDeathLow))–\(min(100, ageAtDeathHigh)) plausible (birth \(windowLabel))")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "died \(recordYear), age range inconsistent with birth \(windowLabel)")

        case .marriage:
            // Marriage age against a birth window:
            //   ageHigh = recordYear - birthLow   (oldest plausible age)
            //   ageLow  = recordYear - birthHigh  (youngest plausible age)
            // `checkMarriageAge` returns false when (year - birth) < 16. If
            // even the OLDEST plausible age is below 16, marriage is
            // impossible — preserves the parity-with-Python rule that
            // "married at age 6" is .impossible regardless of mode.
            let ageHigh = recordYear - birthLow
            let ageLow  = recordYear - birthHigh
            if !ScoringRules.checkMarriageAge(birthYear: birthLow, marriageYear: recordYear) {
                return GateResult(gate: .date, outcome: .impossible, reason: "married \(recordYear) at max age ~\(ageHigh) (birth \(windowLabel))")
            }
            if ageLow > 70 {
                return GateResult(gate: .date, outcome: .impossible, reason: "married \(recordYear) at minimum age ~\(ageLow) (birth \(windowLabel))")
            }
            let typicalOverlap = ageHigh >= 16 && ageLow <= 60
            if typicalOverlap {
                return GateResult(gate: .date, outcome: .pass, reason: "married \(recordYear), age range \(max(16, ageLow))–\(min(60, ageHigh)) typical (birth \(windowLabel))")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "married \(recordYear), age range inconsistent with birth \(windowLabel)")

        case .census:
            if case .census(let cr) = record, let censusBirth = cr.birthYear {
                // Census age misreporting is endemic in 19th-c. enumeration
                // (round numbers, mis-remembered ages, intentional fudges).
                // ±5 is the honest band — previous ±2 was rejecting genuine
                // census matches whose enumerated age was off by 3–4 years.
                let tol = ScoringRules.tolerance(for: .census)
                let inWindow = censusBirth >= birthLow - tol && censusBirth <= birthHigh + tol
                if inWindow {
                    return GateResult(gate: .date, outcome: .pass, reason: "census birth year \(censusBirth) inside window \(windowLabel) ±\(tol)")
                }
                let diff = censusBirth < birthLow ? birthLow - censusBirth : censusBirth - birthHigh
                return GateResult(gate: .date, outcome: .fail, reason: "census birth year \(censusBirth) is \(diff) years outside window \(windowLabel)")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "no birth year in census record")

        default:
            // Birth or unknown — pass when recordYear lands inside the
            // birth window (±tolerance). The verdict layer treats a pass
            // here as `.fact`; the cluster's hypothesis verdict then
            // re-grades wide-window facts to "weakly supported" so they
            // don't auto-promote on a single record.
            //
            // Per-type tolerance: .birth is tight (±1 — covers the Q4-
            // birth/Q1-following-year-registration boundary slip); baptism
            // and christening are loose (±5 — children can be baptised
            // years after birth, adult baptism happens). Subject's date
            // precision is already encoded in the from/to window above.
            let tol = ScoringRules.tolerance(for: searchType)
            let inWindow = recordYear >= birthLow - tol && recordYear <= birthHigh + tol
            if inWindow {
                return GateResult(gate: .date, outcome: .pass, reason: "year \(recordYear) inside window \(windowLabel) ±\(tol)")
            }
            let diff = recordYear < birthLow ? birthLow - recordYear : recordYear - birthHigh
            if diff <= 5 {
                return GateResult(gate: .date, outcome: .fail, reason: "year \(recordYear) is \(diff) years outside window \(windowLabel)")
            }
            return GateResult(gate: .date, outcome: .impossible, reason: "year \(recordYear) is \(diff) years outside window \(windowLabel)")
        }
    }

    // MARK: - Gate 3: Geography

    private static func checkGeography(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        // CWGC casualty records carry cemetery + country of death, not
        // UK residence — they exist *because* civil GRO has no record
        // for casualties who died abroad. The geography gate has no
        // useful UK signal to match against; demanding one would
        // soft-fail every CWGC record as "no location data" and lose
        // the military_service signal. Pass by class — the date and
        // name gates still police identity. Same carve-out the verdict
        // logic applies for CWGC fact-promotion (commit 83706f6).
        if case .military = record {
            return GateResult(
                gate: .geography, outcome: .pass,
                reason: "CWGC casualty — UK residence not on record by class invariant"
            )
        }

        // Foreign-metadata short-circuit. Scan the two strongest scope
        // signals on a FamilySearch record:
        //   1. `collection.title` — identifies which country's
        //      government produced the records ("United States,
        //      Census, 1920"; "United States, Social Security
        //      Numerical Identification Files (NUMIDENT)").
        //   2. Any `fact.*.place` raw field — the FamilySearch
        //      GEDCOMx fact-level places ("New York City, New York,
        //      United States" on a fact.Immigration.place) carry an
        //      explicit country marker even when the collection
        //      title only names a state ("New York Passenger and
        //      Crew Lists" — no "United States" verbatim).
        //
        // When either signal matches a foreignCountryTokens marker,
        // fail regardless of persona-level place fields. The rare
        // legitimate-emigrant case is sacrificed to keep Triage clean
        // for the typical UK-rooted research run.
        // Sort with collection.title first — it's the strongest scope
        // signal (whole-collection origin) and yields the most useful
        // failure reason. Place-fields second, alphabetised for
        // deterministic ordering across Dictionary iteration runs.
        let foreignMetadataKeys = record.rawFields.keys
            .filter { $0 == "collection.title" || $0.hasSuffix(".place") }
            .sorted { lhs, rhs in
                if lhs == "collection.title" { return true }
                if rhs == "collection.title" { return false }
                return lhs < rhs
            }
        for key in foreignMetadataKeys {
            guard let value = record.rawFields[key],
                  Self.isObviouslyForeign(value) else { continue }
            return GateResult(
                gate: .geography, outcome: .fail,
                reason: "non-UK \(key): \(String(value.prefix(50)))"
            )
        }

        // Extract district from record
        var district = ""
        switch record {
        case .birth(let r): district = r.district ?? ""
        case .death(let r): district = r.district ?? ""
        case .marriage(let r): district = r.district ?? ""
        case .census(let r): district = r.district ?? ""
        default: break
        }

        if district.isEmpty {
            // Check FamilySearch-style place fields. Mirrors Python
            // `_check_geography` in `agent/scorer.py:273-281`, which reads
            // `birth_place / residence_place / census_county / birth_county`
            // as a fallback chain when district is absent. Without the
            // BMD-side fallbacks below, a FamilySearch BirthRecord with
            // `birthPlace: "South Carolina"` (no UK district) slipped
            // through as "no location data" → softFail → lead instead of
            // being failed as foreign. Death/Marriage need the same
            // treatment for symmetry; FamilySearch doesn't populate UK
            // districts on out-of-area BMD records either.
            var county = ""
            switch record {
            case .birth(let r): county = r.birthPlace ?? ""
            case .death(let r): county = r.deathPlace ?? ""
            case .marriage(let r): county = r.marriagePlace ?? ""
            case .census(let r): county = r.birthCounty ?? r.birthPlace ?? ""
            case .burial(let r): county = r.burialLocation ?? ""
            case .probate(let r): county = r.address ?? ""
            default: break
            }
            // Hard-fail explicitly non-UK locations when the subject's
            // home Chapman code is UK. Sources like FindAGrave don't honour
            // scope at the query layer, so a Toronto burial can slip into
            // the result set even on a county-limited Derbyshire run.
            // Without this check the gate only soft-fails ("location: …"),
            // the record becomes a `.lead`, and clutters Triage. The verdict
            // logic translates geography `.fail` into `.impossible` so the
            // record is filtered out of clustering entirely.
            if !county.isEmpty, Self.isObviouslyForeign(county) {
                return GateResult(gate: .geography, outcome: .fail, reason: "non-UK location: \(String(county.prefix(50)))")
            }
            if county.lowercased().contains("derby") {
                return GateResult(gate: .geography, outcome: .pass, reason: "Derbyshire")
            }
            // Slice 8 — parish-level lookup. A census record reporting
            // birthplace "Windley" or "Mugginton" doesn't contain the
            // word "Derbyshire" verbatim, but maps via the parishes-
            // catalogue to Belper district → local. Without this check
            // such records soft-fail at the geography gate and clutter
            // Triage with leads that should have promoted to facts. Try
            // the first place-name token (most specific) and the full
            // string to handle both "Windley" and "Windley, Derbyshire".
            if !county.isEmpty {
                let primaryToken = county
                    .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? county
                if ScoringRules.isLocalParish(primaryToken, forHomeChapman: subject.homeChapmanCode) {
                    return GateResult(
                        gate: .geography, outcome: .pass,
                        reason: "parish \(primaryToken) is in research-area district"
                    )
                }
                return GateResult(gate: .geography, outcome: .softFail, reason: "location: \(String(county.prefix(50)))")
            }
            // No location data on the record. For UK Probate Calendar
            // specifically — every record is by class invariant in England
            // & Wales (ProbateSource.coverageRegions). But blanket-passing
            // on that grounds is too loose: a "John Smith" probate from
            // anywhere in the UK would auto-promote to .fact for any
            // Cauldwell subject. Use record-side registry data first (most
            // specific), then subject-side death-location context as a
            // fallback. Spec §23.
            if case .probate(let r) = record {
                // Registry catchment — strongest signal when known.
                // Manchester registry covers DBY/LAN/CHS/CUL/WES/GTM;
                // a Manchester-grant for a Derbyshire subject passes.
                // A Brighton-grant for a Derbyshire subject would softFail
                // here (catchment mismatch suggests a different person of
                // the same name from a different region).
                if let catchment = ProbateRegistryCatchment.chapmanCodes(forRegistry: r.registry) {
                    if catchment.contains(subject.homeChapmanCode.uppercased()) {
                        return GateResult(gate: .geography, outcome: .pass, reason: "registry \(r.registry ?? "?") covers \(subject.homeChapmanCode)")
                    }
                    return GateResult(gate: .geography, outcome: .softFail, reason: "registry \(r.registry ?? "?") catchment doesn't cover \(subject.homeChapmanCode)")
                }
                // Registry unknown — fall back to subject's free-text death
                // location. Less precise than a structured catchment match
                // but useful when the registry is missing or our map
                // doesn't cover it.
                if let dl = subject.deathLocation, dl.lowercased().contains("derby") {
                    return GateResult(gate: .geography, outcome: .pass, reason: "subject's death location \(dl) overlaps Probate UK coverage")
                }
            }
            return GateResult(gate: .geography, outcome: .softFail, reason: "no location data")
        }

        let districtClean = district.replacingOccurrences(of: " district", with: "").trimmingCharacters(in: .whitespaces)

        // Same foreign-country check on the structured district field —
        // covers sources that put a country name in the district slot
        // rather than the dedicated location field.
        if Self.isObviouslyForeign(districtClean) {
            return GateResult(gate: .geography, outcome: .fail, reason: "non-UK district: \(districtClean)")
        }

        if let nonLocal = ScoringRules.isNonLocal(districtClean, forHomeChapman: subject.homeChapmanCode) {
            return GateResult(gate: .geography, outcome: .softFail, reason: "\(districtClean) is in \(nonLocal), not local")
        }

        if ScoringRules.isLocalDistrict(districtClean, forHomeChapman: subject.homeChapmanCode) {
            return GateResult(gate: .geography, outcome: .pass, reason: "\(districtClean) is in research area")
        }

        return GateResult(gate: .geography, outcome: .softFail, reason: "unknown district: \(districtClean)")
    }

    /// Recognise locations that are clearly outside the UK so the gate can
    /// hard-fail them. Word-boundary-padded so short tokens like "USA"
    /// don't accidentally match substrings (e.g. "Kusano"). Conservative
    /// list — Scotland / Wales / Ireland are *not* included because they
    /// have their own Chapman codes and a subject can legitimately have
    /// records there; this is for definitely-overseas-from-the-UK matches.
    nonisolated private static let foreignCountryTokens: [String] = [
        "canada", "australia", "new zealand", "united states",
        "usa", "south africa", "india",
        "pakistan", "argentina", "brazil", "mexico", "germany",
        "france", "spain", "italy", "netherlands", "belgium",
        "norway", "sweden", "denmark", "china", "japan",
        "philippines", "kenya", "nigeria", "jamaica", "barbados",
    ]

    nonisolated private static func isObviouslyForeign(_ text: String) -> Bool {
        // Pad with separators so short tokens only match as whole words
        // (avoids "usa" matching "kusano"). Cheap given the modest token list.
        let lower = " " + text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            + " "
        for token in foreignCountryTokens {
            if lower.contains(" \(token) ") { return true }
        }
        return false
    }

    // MARK: - Gate 4: Family Context

    private static func checkFamilyContext(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        guard let context = subject.familyContext else {
            return GateResult(gate: .familyContext, outcome: .skip, reason: "no family context available")
        }

        // Check census household for known family members
        if case .census(let census) = record, let household = census.household {
            // Spouse match
            if let spouseName = context.spouseName {
                let spouseInHousehold = household.contains { member in
                    let rel = member.relationship.lowercased()
                    let isSpouse = rel.contains("wife") || rel.contains("husband")
                    return isSpouse && ScoringRules.nameSimilarity(member.name.uppercased(), spouseName.uppercased()) >= 0.7
                }
                if spouseInHousehold {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse \(spouseName) found in household")
                }
            }

            // Child match
            for childName in context.childNames {
                let childInHousehold = household.contains { member in
                    let rel = member.relationship.lowercased()
                    let isChild = rel.contains("son") || rel.contains("daughter") || rel.contains("child")
                    return isChild && ScoringRules.nameSimilarity(member.name.uppercased(), childName.uppercased()) >= 0.7
                }
                if childInHousehold {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "child \(childName) found in household")
                }
            }

            // No family members found — soft fail (suspicious but not disqualifying)
            if context.spouseName != nil || !context.childNames.isEmpty {
                return GateResult(gate: .familyContext, outcome: .softFail, reason: "no known family members in household")
            }
        }

        // Marriage record — check spouse name match
        if case .marriage(let marriage) = record {
            if let spouseName = marriage.spouseName {
                if let knownSpouse = context.spouseName {
                    if ScoringRules.nameSimilarity(spouseName.uppercased(), knownSpouse.uppercased()) >= 0.7 {
                        return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse matches: \(spouseName)")
                    }
                }
                if let knownSurname = context.spouseSurname {
                    let parts = spouseName.uppercased().split(separator: " ")
                    if let recordSurname = parts.last, ScoringRules.nameSimilarity(String(recordSurname), knownSurname.uppercased()) >= 0.7 {
                        return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse surname matches: \(recordSurname)")
                    }
                }
            }
            // Same-page partner inference: fires when `spouseName` is nil
            // (pre-Sep-1912 marriages, where FreeBMD's spouse column was
            // not yet recorded) or didn't match above. The pipeline's
            // same-page pairing pass populates `partnerSurnameFromSamePage`
            // from a separately-fetched spouse-side entry at the same
            // (vol, page) — deterministic identification of the marriage's
            // other party. Compare against both the recorded spouse surname
            // and the spouse's maiden form (for inverted-import cases where
            // the wife's lastName carries her married surname).
            if let inferred = marriage.partnerSurnameFromSamePage?
                .trimmingCharacters(in: .whitespaces), !inferred.isEmpty {
                let inferredUpper = inferred.uppercased()
                let knownSurnames: [String] = [
                    context.spouseSurname,
                    context.spouseFatherSurname
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                for known in knownSurnames {
                    if ScoringRules.nameSimilarity(inferredUpper, known.uppercased()) >= 0.7 {
                        let ref = [marriage.volume, marriage.page]
                            .compactMap { $0 }
                            .joined(separator: "/")
                        let location = ref.isEmpty ? "" : " at \(ref)"
                        return GateResult(
                            gate: .familyContext, outcome: .pass,
                            reason: "partner surname inferred from same-page entry\(location): \(inferred) matches known \(known)"
                        )
                    }
                }
            }
        }

        // Slice 9 — validate-enrichment-parents.
        // Mirrors Python `validate_enrichment_parents` (`agent/rules.py:525`).
        // When a record carries the mother's maiden surname AND the subject
        // has a linked mother on the tree (so `familyContext.motherSurname`
        // is populated), compare them. A mismatch — record claims MMN=Smith
        // but linked mother is Land — is the classic wrong-person
        // enrichment signature. Soft-fail rather than fail; the user can
        // still review and override if the linked mother turns out to be
        // wrong, but the record won't silently auto-promote to a fact.
        if let recordMMN: String = {
            switch record {
            case .birth(let r): return r.mothersMaidenName
            default: return nil
            }
        }(),
           !recordMMN.trimmingCharacters(in: .whitespaces).isEmpty,
           let knownMotherSurname = context.motherSurname,
           !knownMotherSurname.trimmingCharacters(in: .whitespaces).isEmpty {
            let rec = recordMMN.trimmingCharacters(in: .whitespaces).uppercased()
            let known = knownMotherSurname.trimmingCharacters(in: .whitespaces).uppercased()
            let similarity = ScoringRules.nameSimilarity(rec, known)
            if similarity >= 0.7 {
                return GateResult(
                    gate: .familyContext, outcome: .pass,
                    reason: "MMN \(recordMMN) matches linked mother \(knownMotherSurname)"
                )
            } else {
                return GateResult(
                    gate: .familyContext, outcome: .softFail,
                    reason: "record MMN \(recordMMN) conflicts with linked mother surname \(knownMotherSurname) — possible wrong-person enrichment"
                )
            }
        }

        return GateResult(gate: .familyContext, outcome: .skip, reason: "no family context applicable for this record type")
    }

    // MARK: - Helpers

    /// Extract a year from a SourceRecord based on its type.
    private static func extractYear(from record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .death(let r): return r.deathYear
        case .marriage(let r): return r.marriageYear
        case .census(let r): return r.censusYear
        case .burial(let r): return r.deathYear ?? r.birthYear
        case .military(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        case .parish(let r): return r.eventYear
        case .pedigree(let r): return r.birthYear
        }
    }

    /// Create a one-line summary of a record.
    static func summarise(record: SourceRecord, searchType: RecordType) -> String {
        switch record {
        case .birth(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            return "\(name), \(r.quarter ?? "") \(r.birthYear.map(String.init) ?? "?"), \(r.district ?? "")"
        case .death(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            let ageStr = r.age.map { ", age \($0)" } ?? ""
            return "\(name), \(r.quarter ?? "") \(r.deathYear.map(String.init) ?? "?"), \(r.district ?? "")\(ageStr)"
        case .marriage(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            let spouseStr = r.spouseName.map { ", spouse \($0)" } ?? ""
            return "\(name), \(r.quarter ?? "") \(r.marriageYear.map(String.init) ?? "?")\(spouseStr)"
        case .census(let r):
            return "\(r.common.name ?? "?"), census \(r.censusYear), born \(r.birthYear.map(String.init) ?? "?") \(r.birthPlace ?? "")"
        case .military(let r):
            return "\(r.common.name ?? "?"), \(r.rank ?? "") \(r.regiment ?? ""), died \(r.dateOfDeath ?? "?")"
        case .burial(let r):
            return "\(r.common.name ?? "?"), \(r.cemetery ?? "")"
        case .probate(let r):
            return "\(r.common.name ?? "?"), \(r.grantType ?? "probate") \(r.probateDate ?? "")"
        case .parish(let r):
            return "\(r.common.name ?? "?"), \(r.eventType ?? "") \(r.eventYear.map(String.init) ?? "?")"
        case .pedigree(let r):
            return "\(r.common.name ?? "?"), b.\(r.birthYear.map(String.init) ?? "?") \(r.location ?? "")"
        }
    }
}
