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

    /// Tolerance for age-at-death back-calculation. Census ages drift
    /// ±1 commonly, BMD death age is usually exact but can be ±2 in
    /// transcription.
    private static let ageAtDeathTolerance: Int = 2

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
    static func evaluate(
        candidates: [ScoredRecord],
        subject: ResearchSubject,
        deathRecords: [ScoredRecord],
        snapshot: FamilyGraphSnapshot
    ) -> [BiographicalFitResult] {
        let context = SubjectContext.build(subject: subject, snapshot: snapshot)
        var results: [BiographicalFitResult] = []
        for c in candidates {
            guard let birthYear = candidateBirthYear(c) else { continue }
            results.append(
                evaluateOne(
                    candidate: c,
                    candidateBirthYear: birthYear,
                    context: context,
                    deathRecords: deathRecords
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
        deathRecords: [ScoredRecord]
    ) -> BiographicalFitResult {
        var plausibility: Double = 1.0
        var notes: [String] = []

        // Rule 1 — infant-death elimination.
        if let earliestChild = context.earliestChildYear {
            let matchingDeaths = deathRecords.compactMap { scored -> Int? in
                guard let year = recordDeathYear(scored) else { return nil }
                // Within infant-window of the candidate's birth?
                guard year - candidateBirthYear <= infantDeathWindow,
                      year >= candidateBirthYear
                else { return nil }
                // Only count deaths plausibly matching the candidate's
                // identity. Belt-and-braces: require same surname + same
                // given name as the candidate.
                guard sameIdentity(candidate.record, scored.record) else { return nil }
                return year
            }
            if let infantDeathYear = matchingDeaths.first,
               infantDeathYear + minParentAge < earliestChild {
                plausibility = 0.0
                notes.append("ruled out: died \(infantDeathYear), too young to father child born \(earliestChild)")
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
                guard sameIdentity(candidate.record, d.record),
                      let dy = recordDeathYear(d),
                      let age = recordAgeAtDeath(d) else { continue }
                let implied = dy - age
                let gap = abs(implied - candidateBirthYear)
                if gap > deathRelevanceWindow { continue }
                if gap <= ageAtDeathTolerance {
                    notes.append("age-at-death match: died \(dy) age \(age) implies birth ~\(implied)")
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

        if notes.isEmpty {
            notes.append("no biographical anchors available — plausibility unchanged")
        }

        return BiographicalFitResult(
            candidate: candidate,
            candidateBirthYear: candidateBirthYear,
            plausibility: plausibility,
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

    /// Loose identity check between two source records. Used to gate
    /// the cross-reference logic — we only want to back-calculate a
    /// death's age against a birth that plausibly names the same
    /// person.
    private static func sameIdentity(_ a: SourceRecord, _ b: SourceRecord) -> Bool {
        let aSurname = (a.surname ?? "").lowercased()
        let bSurname = (b.surname ?? "").lowercased()
        guard !aSurname.isEmpty, aSurname == bSurname else { return false }
        let aGiven = (a.givenName ?? "").lowercased()
        let bGiven = (b.givenName ?? "").lowercased()
        // Given-name match is permissive: either side may have an extra
        // initial / middle name. Match on the first token of each.
        let aFirst = aGiven.split(separator: " ").first.map(String.init) ?? ""
        let bFirst = bGiven.split(separator: " ").first.map(String.init) ?? ""
        return !aFirst.isEmpty && aFirst == bFirst
    }
}
