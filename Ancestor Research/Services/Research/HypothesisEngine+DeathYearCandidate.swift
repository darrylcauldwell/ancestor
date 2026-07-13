import Foundation
import AncestorKit

/// `.deathYearCandidate(profileID, year)` — generator, grader, and deficit
/// ladder (CONFLICT_LAYER_SPEC CL5 §4.7). The death-year twin of the
/// proven `.birthYearCandidate` recipe.
///
/// Generator: fires when ≥ 2 distinct precise (span-0) death-year values
/// are attested in `Profile.sources[.deathDate]` — exactly the state an
/// open deathDate dispute leaves behind after the R2 ladder correctly
/// refuses same-class rivals (two FreeBMD quarters). All candidates in
/// one generation share a `candidateGroupID` ⟨G5⟩.
///
/// Grader (deterministic, F3-predicate reuse):
///   • `.contradicted` — accepted alive-evidence (census/residence/
///     occupation/military/religion life event) dated AFTER the candidate
///     year: the subject was demonstrably alive past this death.
///   • `.supported`   — this candidate survives while alive-evidence
///     falls strictly BETWEEN the candidates (alive at 1911 decides
///     1905-vs-1913 in favour of 1913), or age-at-death arithmetic
///     (deathYear − recordedAge vs known birth year, ±1) fits this year
///     and misfits every competitor.
///   • `.inconclusive` — neither rule discriminates.
///
/// Deficit ladder: level 1 = FreeCen probes for census years strictly
/// inside the discriminating window between min and max candidate years
/// (each hit is alive-evidence that kills every candidate before it);
/// level 2 = probate probe (calendar year ≥ death year, usually within 2).
nonisolated extension HypothesisEngine {

    /// The shared choose-one group for a subject's death-year candidates.
    static func deathYearCandidateGroupID(profileID: String) -> String {
        "deathYear:\(profileID)"
    }

    static func generateDeathYearCandidate(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        guard let subjectProfileID = state.subject.profileID,
              let profile = snapshot.profiles[subjectProfileID]
        else { return [] }
        let years = preciseDeathYears(of: profile)
        guard years.count >= 2 else { return [] }

        let now = Date()
        let groupID = deathYearCandidateGroupID(profileID: subjectProfileID)
        return years.sorted().map { year in
            let kind = HypothesisKind.deathYearCandidate(
                profileID: subjectProfileID, year: year
            )
            var hypothesis = ResearchHypothesis(
                id: kind.identityKey(subjectProfileID: subjectProfileID),
                subjectProfileID: subjectProfileID,
                kind: kind,
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Pending grading.",
                createdAt: now,
                lastTestedAt: now,
                attempts: 0,
                history: []
            )
            hypothesis.candidateGroupID = groupID
            return hypothesis
        }
    }

    /// Distinct precise (span-0) death years attested on the profile.
    private static func preciseDeathYears(of profile: Profile) -> Set<Int> {
        var years: Set<Int> = []
        for source in profile.sources[.deathDate] ?? [] {
            let parsed = GenealogicalDate(parsing: source.raw)
            guard let earliest = parsed.earliest,
                  let latest = parsed.latest,
                  earliest == latest
            else { continue }
            years.insert(earliest)
        }
        return years
    }

    static func gradeDeathYearCandidate(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .deathYearCandidate(let profileID, let year) = hypothesis.kind,
              let profile = snapshot.profiles[profileID]
        else {
            return GradeResult(
                verdict: .inconclusive, isModelAssisted: false,
                supportingEvidence: [], contradictingEvidence: [],
                reasoning: "Malformed death-year candidate.")
        }
        let competitors = preciseDeathYears(of: profile).subtracting([year]).sorted()
        let events = snapshot.lifeEvents[profileID] ?? []

        // Rule 1 — F3 predicate: alive-evidence after this candidate
        // contradicts it outright.
        let laterAlive = ConflictPredicates.aliveEvidence(afterYear: year, in: events)
        if let latest = laterAlive.max(by: { $0.year < $1.year }) {
            return GradeResult(
                verdict: .contradicted, isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: ["\(latest.event.type.rawValue) \(latest.year)"],
                reasoning: "Alive-evidence after candidate death \(year): \(latest.event.type.rawValue) \(latest.year). A person cannot be recorded alive after death (F3).")
        }

        // Rule 2 — discriminating alive-evidence between the candidates:
        // if the subject was alive at a year that kills EVERY competitor
        // below this candidate, and no alive-evidence kills this one
        // (rule 1 already passed), this candidate is the survivor.
        if !competitors.isEmpty {
            let aliveYears = events.compactMap { event -> Int? in
                guard ConflictPredicates.aliveEvidenceTypes.contains(event.type) else { return nil }
                return event.date?.earliest
            }
            if let bestAlive = aliveYears.max() {
                let killed = competitors.filter { $0 < bestAlive }
                if killed.count == competitors.count {
                    return GradeResult(
                        verdict: .supported, isModelAssisted: false,
                        supportingEvidence: ["alive-evidence \(bestAlive)"],
                        contradictingEvidence: [],
                        reasoning: "Alive at \(bestAlive) contradicts every competing candidate (\(killed.map(String.init).joined(separator: ", "))); \(year) is the surviving death year.")
                }
            }
        }

        // Rule 3 — age-at-death arithmetic: a death record asserting THIS
        // candidate year with a recorded age implies a birth year; when it
        // fits the known birth (±1) and no competitor's aged record fits
        // its own year, this candidate is supported (and vice versa).
        if let birthYear = profile.birthDate?.earliest {
            func agedFit(forYear y: Int) -> Bool {
                state.scoredRecords.contains { scored in
                    guard scored.verdict != .impossible,
                          case .death(let r) = scored.record,
                          r.deathYear == y, let age = r.age else { return false }
                    return abs((y - age) - birthYear) <= 1
                }
            }
            let fits = agedFit(forYear: year)
            let competitorFits = competitors.contains { agedFit(forYear: $0) }
            if fits && !competitorFits {
                return GradeResult(
                    verdict: .supported, isModelAssisted: false,
                    supportingEvidence: ["age-at-death arithmetic fits \(year)"],
                    contradictingEvidence: [],
                    reasoning: "Age-at-death arithmetic fits candidate \(year) against known birth \(birthYear) (±1); no competitor fits.")
            }
            if !fits && competitorFits {
                return GradeResult(
                    verdict: .contradicted, isModelAssisted: false,
                    supportingEvidence: [],
                    contradictingEvidence: ["age-at-death arithmetic misfits \(year)"],
                    reasoning: "Age-at-death arithmetic misfits candidate \(year) against known birth \(birthYear) while a competitor fits.")
            }
        }

        return GradeResult(
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "No alive-evidence or age arithmetic discriminates \(year) from \(competitors.map(String.init).joined(separator: ", ")). Deficit probes target census years inside the discriminating window.")
    }

    static func deficitQueryDeathYearCandidate(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .deathYearCandidate = hypothesis.kind else { return [] }
        // The discriminating window: the subject's death range spans the
        // competing candidates (the same attested sources feed both).
        guard let minYear = state.subject.deathYearFrom,
              let maxYear = state.subject.deathYearTo,
              minYear < maxYear else { return [] }
        let surname = (state.subject.surname ?? "").trimmingCharacters(in: .whitespaces)
        guard !surname.isEmpty else { return [] }

        switch level {
        case 1:
            // Census years strictly inside the discriminating window: a
            // hit is alive-evidence that kills every candidate before it.
            let window = ScoringRules.censusYears.filter { $0 > minYear && $0 < maxYear }
            return window.map { year in
                RecordQuery(
                    surname: surname,
                    givenName: state.subject.givenName,
                    recordType: .census,
                    yearFrom: year, yearTo: year,
                    gender: state.subject.gender,
                    region: state.subject.region,
                    sourceParams: .freeCen(FreeCenParams(
                        chapmanCode: state.subject.homeChapmanCode,
                        censusYear: year
                    ))
                )
            }
        case 2:
            // Probate calendar probe: probate year ≥ death year, usually
            // within 2 — one probe spanning the candidate window + 2.
            return [RecordQuery(
                surname: surname,
                givenName: state.subject.givenName,
                recordType: .probate,
                yearFrom: minYear, yearTo: maxYear + 2,
                gender: state.subject.gender,
                region: state.subject.region,
                sourceParams: .probate(ProbateParams())
            )]
        default:
            return []
        }
    }
}
