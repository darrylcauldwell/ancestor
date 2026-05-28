import Foundation

/// One candidate birth record's biographical fit against the subject's
/// known life timeline. Output of `BiographicalFitEvaluator.evaluate`.
///
/// `plausibility` is a 0.0-1.0 deterministic score. 0.0 means the
/// candidate is biologically impossible (e.g. they died as an infant
/// but the subject is known to have lived into adulthood, or the
/// candidate's birth year would make the subject fathering children
/// outside the 14-65 window). 1.0 means every check passes. Values
/// in between reflect partial mismatches that warrant attention but
/// not outright rejection.
nonisolated struct BiographicalFitResult: Sendable {
    let candidate: ScoredRecord
    let candidateBirthYear: Int
    let plausibility: Double
    /// Count of independent corroborating signals — currently rule 2
    /// age-at-death matches against same-named death records. Used by
    /// the pipeline's narrowing gate to distinguish "candidate with
    /// strong positive evidence" from "candidate that simply wasn't
    /// ruled out". A candidate with 5 matches and plausibility 1.00
    /// is a different story to one with 0 matches and plausibility
    /// 1.00 (the latter just happens to lack contradicting evidence).
    let corroboratingMatches: Int
    /// One short sentence per check that fired (passed or failed),
    /// joined with " · ". Surfaced in the pipeline log so the user
    /// can see why one candidate was ruled out and another wasn't.
    let reasoning: String
}

/// Slice C — deterministic cross-record reasoning that picks the
/// biographically-consistent birth candidate out of a set of FreeBMD
/// (etc.) birth records sharing the subject's name and region.
///
/// Closes the gap between Python-style orchestrated reasoning and the
/// Swift app's broad-fan-out-and-cluster paradigm. Where Python's
/// orchestrator (the human) would look at multiple "George Brooks"
/// births in Belper and pick the one whose biography fits the known
/// timeline, this evaluator does the same cross-checks deterministically:
///
/// 1. **Infant-death elimination.** If the candidate has a corresponding
///    death record within ~15 years of birth, but the subject is known to
///    have produced children well after that age, the candidate cannot
///    be the subject.
///
/// 2. **Age-at-death back-calculation.** If a death record on the subject
///    carries an `age` field, `deathYear - age` should match the
///    candidate's birth year within ±2 years (census-age rounding).
///
/// 3. **Children-age plausibility.** A father aged <14 or >65 at his
///    first known child's birth is biologically implausible. The
///    candidate's birth year must put the subject in the 14-65 window
///    when his earliest known child was born.
///
/// Determinism contract: this is pure arithmetic over typed record
/// fields + tree snapshot data. No MLX involvement. The pipeline uses
/// the output to refine the subject's birth window (if a single
/// plausible candidate emerges) and to log why other candidates were
/// ruled out.
nonisolated enum BiographicalFitEvaluator {

    /// Minimum age difference between father and child for the birth to
    /// be biologically plausible. UK 19th-century population data shows
    /// the floor reliably at 14; some records below this are
    /// transcription errors or non-biological relationships.
    private static let minParentAge: Int = 14

    /// Maximum father-age at child-birth. Higher than female fertility
    /// upper bound because the candidate's gender may be male. Tuneable
    /// — 65 errs toward inclusion; older fathers exist but are rare.
    private static let maxParentAge: Int = 65

    /// Window within which an infant death rules the candidate out. A
    /// person who died at age 0-15 cannot later have children, so any
    /// candidate whose death record falls within this window of their
    /// birth is eliminated when the subject is known to have produced
    /// children.
    private static let infantDeathWindow: Int = 15

    /// Tolerance for rule 2's age-at-death back-calculation match.
    /// Census ages drift ±1 commonly; BMD death-certificate ages are
    /// usually exact but can be ±2 in transcription. Used to decide
    /// "match" vs "near-miss" once we've already established the
    /// death likely concerns this candidate (via the relevance window).
    private static let ageAtDeathTolerance: Int = 2

    /// Tighter tolerance for rule 1's infant-death elimination. A
    /// 1884 death of an infant (age 2 → implied birth 1882) and a
    /// 1883 candidate are *different children* — close birth years
    /// don't equal same person at infant-death precision. Killing a
    /// candidate is more aggressive than nudging its plausibility, so
    /// require an exact implied-birth match before eliminating.
    private static let infantDeathMatchTolerance: Int = 0

    /// Window within which a death record is considered to *possibly*
    /// be about the same person as a candidate birth. Wider than the
    /// match-tolerance because we want to distinguish "match" (counts
    /// as supporting evidence) from "near-miss" (suspicious — counts
    /// as contradicting evidence) from "different person entirely"
    /// (irrelevant — skip). A 1871 infant death and an 1883 candidate
    /// birth are 12 years apart at implied-birth level — clearly
    /// different people; we don't want the 1871 death's existence to
    /// downgrade the 1883 candidate.
    private static let deathRelevanceWindow: Int = 5

    /// Evaluate each birth-shape candidate against the subject's known
    /// life timeline. Returns one result per evaluable candidate, sorted
    /// by plausibility descending. Candidates without a usable
    /// `birthYear` are skipped (not included in the returned array).
    ///
    /// `censusRecords` is optional (defaults to empty) so existing
    /// callers (slice C subject-self-narrowing) don't need to change.
    /// When supplied, Rule 4 cross-checks each census record's
    /// `(censusYear - age)` back-calculation against each candidate
    /// — matches increment `corroboratingMatches`. Census ages drift
    /// (UK 19c enumeration is endemic ±5), so census mismatch does
    /// NOT apply a plausibility penalty; it just doesn't corroborate.
    /// Multiple corroborating census records pile up on whichever
    /// candidate they actually attest to, surfacing the right one
    /// through the corroboration-based tie-break the grader applies.
    static func evaluate(
        candidates: [ScoredRecord],
        subject: ResearchSubject,
        deathRecords: [ScoredRecord],
        snapshot: FamilyGraphSnapshot,
        censusRecords: [ScoredRecord] = []
    ) -> [BiographicalFitResult] {
        let context = SubjectContext.build(subject: subject, snapshot: snapshot)
        // Anchor the same-identity check on the subject's home county so
        // cross-county namesakes don't get counted as evidence (the bug
        // that scrambled George Brooks's 1883 vs 1870 disambiguation —
        // many "George Brooks" records nationwide were corroborating /
        // penalising the wrong candidate). Permissive when records lack
        // a derivable chapman code (most don't outside BMD/census, and
        // we don't want to silently drop those).
        let subjectChapman = subject.homeChapmanCode
        var results: [BiographicalFitResult] = []
        for c in candidates {
            guard let birthYear = candidateBirthYear(c) else { continue }
            results.append(
                evaluateOne(
                    candidate: c,
                    candidateBirthYear: birthYear,
                    context: context,
                    deathRecords: deathRecords,
                    censusRecords: censusRecords,
                    subjectChapmanCode: subjectChapman
                )
            )
        }
        return results.sorted { $0.plausibility > $1.plausibility }
    }

    // MARK: - Per-candidate evaluation

    private static func evaluateOne(
        candidate: ScoredRecord,
        candidateBirthYear: Int,
        context: SubjectContext,
        deathRecords: [ScoredRecord],
        censusRecords: [ScoredRecord] = [],
        subjectChapmanCode: String = ""
    ) -> BiographicalFitResult {
        var plausibility: Double = 1.0
        var notes: [String] = []
        var corroboratingMatches: Int = 0

        // Rule 1 — infant-death elimination.
        //
        // A death is *evidence about this candidate* only when the
        // death's `age` field plausibly matches the candidate's birth
        // year (i.e. `deathYear - age` ≈ candidate's birth). Without
        // that match, the death is about a same-named different
        // person (commonly observed: 1886 death of George Brooks
        // aged 50 → implied birth 1836 → unrelated to a 1883
        // candidate, even though the surname + year-proximity check
        // alone would falsely match).
        //
        // Given a same-person match, eliminate only when the deceased
        // was a child (age ≤ infantDeathWindow) AND died before the
        // subject's known first child was born.
        if let earliestChild = context.earliestChildYear {
            for d in deathRecords where sameIdentity(candidate.record, d.record, subjectChapmanCode: subjectChapmanCode) {
                guard let deathYear = recordDeathYear(d),
                      let age = recordAgeAtDeath(d)
                else { continue }
                let impliedBirth = deathYear - age
                // Only count as this-candidate's death if implied
                // birth lines up *exactly*. Killing a candidate is
                // more aggressive than just downgrading confidence,
                // so use the tighter `infantDeathMatchTolerance`
                // (typically 0). A 1884 death age 2 (implied birth
                // 1882) and a 1883 candidate are different children
                // even though the years are close.
                guard abs(impliedBirth - candidateBirthYear) <= infantDeathMatchTolerance else { continue }
                if age <= infantDeathWindow, deathYear + minParentAge < earliestChild {
                    plausibility = 0.0
                    notes.append("ruled out: died \(deathYear) age \(age), too young to father child born \(earliestChild)")
                    break
                }
            }
        }

        // Rule 2 — age-at-death back-calculation.
        // Only consider deaths whose implied birth year is *near* the
        // candidate — beyond the relevance window, the death is about
        // a different same-named person and shouldn't downgrade this
        // candidate (canonical case: 1871 infant death vs 1883 birth
        // candidate, 12 years apart at implied-birth level → skip).
        if plausibility > 0 {
            for d in deathRecords {
                guard sameIdentity(candidate.record, d.record, subjectChapmanCode: subjectChapmanCode),
                      let dy = recordDeathYear(d),
                      let age = recordAgeAtDeath(d) else { continue }
                let implied = dy - age
                let gap = abs(implied - candidateBirthYear)
                if gap > deathRelevanceWindow { continue }
                if gap <= ageAtDeathTolerance {
                    notes.append("age-at-death match: died \(dy) age \(age) implies birth ~\(implied)")
                    corroboratingMatches += 1
                } else {
                    plausibility *= 0.4
                    notes.append("age-at-death mismatch: died \(dy) age \(age) implies birth ~\(implied), candidate is \(candidateBirthYear)")
                }
            }
        }

        // Rule 3 — children-age plausibility.
        if plausibility > 0, let earliestChild = context.earliestChildYear {
            let parentAge = earliestChild - candidateBirthYear
            if parentAge < minParentAge {
                plausibility = 0.0
                notes.append("ruled out: would be \(parentAge) at first child's birth (\(earliestChild))")
            } else if parentAge > maxParentAge {
                plausibility = 0.0
                notes.append("ruled out: would be \(parentAge) at first child's birth (\(earliestChild))")
            } else {
                notes.append("parent-age plausible: \(parentAge) at first child's birth (\(earliestChild))")
            }
        }

        // Rule 4 — census-age back-calculation (corroboration only).
        //
        // For each census record passing `sameIdentity`, compute
        // `censusYear - age` and compare to the candidate's birth year.
        // Within `censusAgeTolerance` (±2) → counts as a corroborating
        // match (increments the counter, no plausibility change).
        // Outside the relevance window (gap > deathRelevanceWindow=5) →
        // skip entirely: the census record is about a different
        // same-named person at a different generation.
        //
        // Unlike rule 2, mismatch within the relevance window does NOT
        // apply a plausibility penalty. UK 19c census ages drift ±5
        // routinely (illiteracy, vanity, enumerator estimation), and a
        // single off-by-3 age is weak evidence even at face value.
        // Census records contribute only POSITIVELY — letting
        // corroboration pile up on whichever candidate the records
        // actually attest to. The `.birthYearCandidate` grader's
        // corroboration-based tie-break then surfaces the winner.
        if plausibility > 0 {
            for c in censusRecords {
                guard sameIdentity(candidate.record, c.record, subjectChapmanCode: subjectChapmanCode),
                      case .census(let censusBody) = c.record
                else { continue }
                let age: Int
                let impliedBirth: Int
                if let recordedBirth = censusBody.birthYear {
                    // FreeCen sometimes carries the implied birth year
                    // directly (chapman-level imports compute it on
                    // ingest). Prefer it when present.
                    impliedBirth = recordedBirth
                    age = censusBody.censusYear - recordedBirth
                } else if let recordedAge = censusBody.age {
                    age = recordedAge
                    impliedBirth = censusBody.censusYear - recordedAge
                } else {
                    continue   // no age data → can't compare
                }
                let gap = abs(impliedBirth - candidateBirthYear)
                if gap > deathRelevanceWindow { continue }
                if gap <= ScoringRules.censusAgeTolerance {
                    notes.append("census-age corroboration: \(censusBody.censusYear) age \(age) implies birth ~\(impliedBirth)")
                    corroboratingMatches += 1
                } else {
                    notes.append("census-age near-miss: \(censusBody.censusYear) age \(age) implies birth ~\(impliedBirth), candidate is \(candidateBirthYear) — no penalty (census drift endemic)")
                }
            }
        }

        if notes.isEmpty {
            notes.append("no biographical anchors available — plausibility unchanged")
        }

        return BiographicalFitResult(
            candidate: candidate,
            candidateBirthYear: candidateBirthYear,
            plausibility: plausibility,
            corroboratingMatches: corroboratingMatches,
            reasoning: notes.joined(separator: " · ")
        )
    }

    // MARK: - Subject context

    /// Resolved view of the subject's known biographical anchors at the
    /// moment of evaluation. Cheap to compute once and re-use per
    /// candidate.
    private struct SubjectContext {
        let earliestChildYear: Int?
        let subjectDeathYear: Int?

        static func build(
            subject: ResearchSubject, snapshot: FamilyGraphSnapshot
        ) -> SubjectContext {
            let earliestChild: Int? = subject.profileID.flatMap { id in
                let years = snapshot.childrenOf(id).compactMap { $0.birthDate?.earliest }
                return years.min()
            }
            return SubjectContext(
                earliestChildYear: earliestChild,
                subjectDeathYear: subject.deathYearFrom
            )
        }
    }

    // MARK: - Record helpers

    /// Returns the birth year a candidate record advertises, if any.
    /// Currently only `.birth` records are considered candidates —
    /// census/burial back-calculations contribute to the subject's
    /// scoring pool but aren't first-class birth candidates.
    private static func candidateBirthYear(_ scored: ScoredRecord) -> Int? {
        if case .birth(let r) = scored.record { return r.birthYear }
        return nil
    }

    private static func recordDeathYear(_ scored: ScoredRecord) -> Int? {
        switch scored.record {
        case .death(let r): return r.deathYear
        case .burial(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        case .military(let r): return r.deathYear
        default: return nil
        }
    }

    private static func recordAgeAtDeath(_ scored: ScoredRecord) -> Int? {
        switch scored.record {
        case .death(let r): return r.age
        case .burial(let r):
            // BurialRecord doesn't carry an age field directly, but if
            // both deathYear and birthYear are set, derive the age.
            if let dy = r.deathYear, let by = r.birthYear { return dy - by }
            return nil
        case .probate(let r): return r.ageAtDeath
        case .military(let r): return r.age
        default: return nil
        }
    }

    /// Subject-anchored identity check. Used to gate the cross-reference
    /// logic — we only want to back-calculate a death's age (or
    /// census's age) against a birth that plausibly names the SUBJECT,
    /// not a same-named different person in a different county.
    ///
    /// Three-stage check:
    ///   1. Surname must match (case-insensitive) on both sides
    ///   2. Given-name first-token must match on both sides
    ///      (permissive — handles "Geo." / "George" via first-token
    ///       comparison would still fail; that's a known gap. The
    ///       current gate is a first-token equality after lowercasing,
    ///       matching the legacy semantics.)
    ///   3. If `record` (the b-side — typically the evidence record:
    ///      death, census, etc.) carries derivable location data → its
    ///      chapman code must match `subjectChapmanCode`. When the
    ///      record's location is missing or not mappable, this stage
    ///      is permissive (passes) — many record types don't carry a
    ///      reliable chapman-code anchor (probate registry is the
    ///      registry's location, not the testator's; burial cemetery
    ///      can be anywhere). Filter on the data that's reliable;
    ///      don't penalise gaps in source coverage.
    ///
    /// `subjectChapmanCode` defaults to "" so callers that pass nothing
    /// fall through to the legacy (pre-stage-3) behaviour. Production
    /// callers via `evaluate()` always pass the subject's home chapman.
    private static func sameIdentity(
        _ a: SourceRecord,
        _ b: SourceRecord,
        subjectChapmanCode: String = ""
    ) -> Bool {
        let aSurname = (a.surname ?? "").lowercased()
        let bSurname = (b.surname ?? "").lowercased()
        guard !aSurname.isEmpty, aSurname == bSurname else { return false }
        let aGiven = (a.givenName ?? "").lowercased()
        let bGiven = (b.givenName ?? "").lowercased()
        // Given-name match is permissive: either side may have an extra
        // initial / middle name. Match on the first token of each.
        let aFirst = aGiven.split(separator: " ").first.map(String.init) ?? ""
        let bFirst = bGiven.split(separator: " ").first.map(String.init) ?? ""
        guard !aFirst.isEmpty, aFirst == bFirst else { return false }

        // Stage 3 — chapman-code anchor. Permissive when caller doesn't
        // supply a subject chapman (back-compat) OR the record's
        // location isn't mappable (covers probate/burial/military).
        guard !subjectChapmanCode.isEmpty else { return true }
        guard let recordChapman = chapmanCode(of: b) else { return true }
        return recordChapman.uppercased() == subjectChapmanCode.uppercased()
    }

    /// Map a record's location field(s) to a Chapman code, when one is
    /// derivable. Returns `nil` when the record has no location data,
    /// when the location isn't in `FreeBMDDistrictCatalogue`, or when
    /// the field's semantics don't align with "where the person lived
    /// at the time of the event" (probate registry, burial cemetery).
    ///
    /// Coverage policy (slice 4 robustness pass, 2026-05-28):
    ///   • BMD birth/death/marriage indexes → district → catalogue lookup
    ///   • Census records → birthCounty (when already a 3-letter code)
    ///     OR district → catalogue lookup
    ///   • Other types → nil (permissive)
    ///
    /// Probate `registry` is deliberately NOT mapped — wills can be
    /// registered at the London Principal Registry for a Belper testator,
    /// so registry chapman code doesn't reliably anchor to where the
    /// person lived. Burial `cemetery`/`burialLocation` is similarly
    /// ambiguous (a person can be buried far from where they lived).
    ///
    /// Internal access (not `private`) so unit tests can verify the
    /// mapping behaviour directly.
    static func chapmanCode(of record: SourceRecord) -> String? {
        switch record {
        case .birth(let r):
            return chapmanCodeForDistrict(r.district)
        case .death(let r):
            return chapmanCodeForDistrict(r.district)
        case .marriage(let r):
            return chapmanCodeForDistrict(r.district)
        case .census(let r):
            if let bc = r.birthCounty?.trimmingCharacters(in: .whitespaces),
               bc.count == 3, bc == bc.uppercased() {
                return bc   // already a chapman code
            }
            return chapmanCodeForDistrict(r.district)
        case .burial, .probate, .military, .parish, .pedigree:
            return nil
        }
    }

    private static func chapmanCodeForDistrict(_ district: String?) -> String? {
        guard let name = district?.trimmingCharacters(in: .whitespaces), !name.isEmpty
        else { return nil }
        return FreeBMDDistrictCatalogue.shared.district(named: name)?.chapmanCode
    }
}
