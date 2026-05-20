import Foundation

/// Profile-aware filter applied to lead candidates before they're
/// persisted via `LeadStore.createFromScoredRecord(_:profileID:)`.
///
/// Background: prior to this gate, lead generation surfaced every
/// `.lead`-verdict record without using the subject's known facts to
/// reject obviously-wrong namesakes. Closed-loop testing on a
/// 7-profile tree found one profile (Jennifer Holmes, b. 21 Dec 1948,
/// living) jumped from 17 → 260 leads run-to-run because the
/// dispatcher's loose tier produced a Holmes-surname trawl spanning
/// birth years 1928-1968 plus 8 probate records of dead Jennifer
/// Holmeses — none of whom are her.
///
/// Three filters applied in order:
///
/// 1. **Alive-vs-dead**: profiles with no death date in the tree are
///    living; death-shaped records (probate, burial, military death,
///    death registration) cannot be about them.
/// 2. **Precise-birth-year window**: when the profile carries a
///    precise birth year (gedcom date with `earliest == latest`),
///    namesake candidates outside ±`birthYearTolerance` years are
///    rejected. Five-year window is permissive — the convergence
///    engine's birth axis already uses ±2, so the namesake filter
///    sits one notch wider to avoid stomping on the structured
///    pipeline's own scoring.
/// 3. **Sentinel-year hits**: census-derived records with the
///    sentinel "1916" or "1920" birth years that the household-
///    extractor sometimes synthesises when the page didn't carry
///    an age — these get rejected when they clash with a known
///    precise birth year.
///
/// What this filter deliberately does NOT do:
/// - It doesn't gate by gender. SourceRecord doesn't carry gender
///   per-record consistently; inferring from names is unreliable.
/// - It doesn't gate by region. The dispatcher already restricts
///   to the subject's region; if a record made it to `.lead` the
///   region was acceptable.
/// - It doesn't gate by surname. Namesake-collision *requires* same
///   surname; that's what makes them namesakes.
///
/// Tests pin the three accept/reject decisions independently of
/// the rest of the pipeline.
nonisolated struct LeadFilter: Sendable {
    /// Precise birth year — set when the profile has a precise gedcom
    /// date (`birthDate.earliest == birthDate.latest`, both non-nil).
    /// `nil` means no precise birth year is available; the birth-
    /// year filter falls through.
    let preciseBirthYear: Int?
    /// Maximum |candidate − preciseBirthYear| accepted as a lead.
    /// Defaults to 5; expose for tests.
    let birthYearTolerance: Int
    /// `true` when the profile has no death date in the tree — the
    /// filter treats them as living and rejects death-shaped
    /// records.
    let isAlive: Bool

    /// Build a filter from a tree profile. Pure function; no I/O.
    static func deriving(from profile: Profile) -> LeadFilter {
        let precise: Int? = {
            guard let birth = profile.birthDate,
                  let earliest = birth.earliest,
                  let latest = birth.latest,
                  earliest == latest else { return nil }
            return earliest
        }()
        let isAlive: Bool = {
            // Treat "no death date at all" or "no parseable death
            // year" as alive. A `deathDate` struct exists when the
            // raw text was set (could be "unknown"), so we look at
            // whether ANY death year landed.
            guard let death = profile.deathDate else { return true }
            return death.earliest == nil && death.latest == nil
        }()
        return LeadFilter(
            preciseBirthYear: precise,
            birthYearTolerance: 5,
            isAlive: isAlive
        )
    }

    /// Returns `true` when the scored record may be persisted as a
    /// lead. `false` rejects.
    func accepts(_ scored: ScoredRecord) -> Bool {
        // Filter 1 — alive profiles reject death-shaped records.
        if isAlive && Self.isDeathShaped(scored.record) {
            return false
        }
        // Filter 2 — precise birth year window. If the record carries
        // its own birth-year hint and the known birth year is
        // precise, reject when they're more than `tolerance` apart.
        if let known = preciseBirthYear, let candidate = Self.candidateBirthYear(scored.record) {
            if abs(candidate - known) > birthYearTolerance {
                return false
            }
        }
        return true
    }

    // MARK: - Record-shape predicates

    /// SourceRecord cases that can only be about a deceased person.
    /// Birth + census + marriage + parish + pedigree are NOT
    /// rejected for living profiles — those carry no death claim.
    nonisolated static func isDeathShaped(_ record: SourceRecord) -> Bool {
        switch record {
        case .death, .burial, .probate, .military: return true
        case .birth, .marriage, .census, .parish, .pedigree: return false
        }
    }

    /// Extract the candidate's birth-year hint from a record. Returns
    /// `nil` when the record shape doesn't carry one (e.g. probate
    /// records typically don't, marriage records typically don't).
    nonisolated static func candidateBirthYear(_ record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .census(let r): return r.birthYear
        case .burial(let r): return r.birthYear
        case .pedigree(let r): return r.birthYear
        case .death, .marriage, .probate, .military, .parish: return nil
        }
    }
}
