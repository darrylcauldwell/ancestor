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
/// Holmeses — none of whom are her. A second closed-loop pass on
/// Reginald Holmes (d. 1 Jan 1999) found 48 FindAGrave memorials of
/// OTHER Reginald Holmeses (1883, 1900, 1906, 1909, 1943, 1978 …)
/// passing the original two filters because Reginald is dead
/// (filter 1 doesn't fire) and FAG burials don't carry birth_year
/// (filter 2 doesn't fire) — closing the gap requires a third
/// death-year axis.
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
/// 3. **Precise-death-year window**: deceased profiles with a
///    precise death year reject death-shaped records whose own
///    death year is outside ±`deathYearTolerance`. Catches the
///    FindAGrave-namesake pattern: Reginald died 1999, every
///    Reginald-Holmes memorial with a death year outside 1994-2004
///    is provably someone else.
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
    /// Precise death year — set when the profile has a precise
    /// gedcom death date. Mirror of `preciseBirthYear` for the
    /// death axis; gates filter 3.
    let preciseDeathYear: Int?
    /// Maximum |candidate − preciseDeathYear| accepted as a lead.
    /// Defaults to 5.
    let deathYearTolerance: Int
    /// `true` when the profile has no death date in the tree — the
    /// filter treats them as living and rejects death-shaped
    /// records.
    let isAlive: Bool

    /// Build a filter from a tree profile. Pure function; no I/O.
    static func deriving(from profile: Profile) -> LeadFilter {
        let preciseBirth: Int? = {
            guard let birth = profile.birthDate,
                  let earliest = birth.earliest,
                  let latest = birth.latest,
                  earliest == latest else { return nil }
            return earliest
        }()
        let preciseDeath: Int? = {
            guard let death = profile.deathDate,
                  let earliest = death.earliest,
                  let latest = death.latest,
                  earliest == latest else { return nil }
            return earliest
        }()
        let isAlive: Bool = {
            // "Confirmed alive" requires the user to have explicitly
            // marked the profile as living-private (the export-suppress
            // flag). Just having no death date is NOT enough — research
            // is supposed to DISCOVER death dates, so older relatives
            // whose death we don't know about yet should still surface
            // death-shape candidates as leads for review.
            //
            // The original Jennifer-Holmes 260-leads incident this
            // filter was added to mitigate is now largely handled by:
            //   - marriedSurname fan-out (search axis is `Jennifer
            //     Cauldwell`, not just `Jennifer Holmes` — far narrower)
            //   - precise-birth-year and precise-death-year window
            //     filters (filters 2 + 3 below)
            // …leaving Filter 1 as the safety net for genuinely-living
            // profiles the user has explicitly flagged.
            profile.resolvedAttributes.privacy == .livingPrivate
        }()
        return LeadFilter(
            preciseBirthYear: preciseBirth,
            birthYearTolerance: 5,
            preciseDeathYear: preciseDeath,
            deathYearTolerance: 5,
            isAlive: isAlive
        )
    }

    /// Returns `true` when the scored record may be persisted as a
    /// lead. `false` rejects.
    func accepts(_ scored: ScoredRecord) -> Bool {
        // Filter 1 — alive profiles reject any record that asserts
        // a death year. Two paths into this gate:
        //   a) record shape is death-shaped (probate/burial/etc.)
        //   b) record is .pedigree (or similar narrative shape)
        //      that nevertheless carries a non-nil deathYear claim
        // Either way, the candidate person died — provably not this
        // alive profile. FamilySearch person records returned as
        // `.pedigree` with a deathYear are the realistic case for
        // path (b); see candidateDeathYear's docstring.
        if isAlive {
            if Self.isDeathShaped(scored.record) {
                return false
            }
            if Self.candidateDeathYear(scored.record) != nil {
                return false
            }
        }
        // Filter 2 — precise birth year window. If the record carries
        // its own birth-year hint and the known birth year is
        // precise, reject when they're more than `tolerance` apart.
        if let known = preciseBirthYear, let candidate = Self.candidateBirthYear(scored.record) {
            if abs(candidate - known) > birthYearTolerance {
                return false
            }
        }
        // Filter 3 — precise death year window. For deceased
        // profiles with a precise death year, death-shaped records
        // carrying their own death year are rejected when more
        // than `tolerance` apart. Catches the FindAGrave-namesake
        // pattern: dead-profile leads were the gap filter 1 didn't
        // close (filter 1 only fires for alive profiles).
        if let known = preciseDeathYear, let candidate = Self.candidateDeathYear(scored.record) {
            if abs(candidate - known) > deathYearTolerance {
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

    /// Extract the candidate's death-year hint from a record. Five
    /// SourceRecord shapes carry a death year:
    ///   - `.death` / `.burial` / `.probate` / `.military` —
    ///     death-shaped by definition
    ///   - `.pedigree` — narrative records (FamilySearch person
    ///     entries, Wirksworth pedigrees, etc.) optionally carry
    ///     a death year on `PedigreeRecord.deathYear`.
    ///
    /// `.birth` / `.census` / `.marriage` / `.parish` don't —
    /// they fall through and filter 3 doesn't gate them.
    ///
    /// Real-world bug this catches (post-Filter-3 v1 closed-loop):
    /// FamilySearch returns person-style records as `.pedigree`,
    /// including ones with `deathYear: 2009 age 65`. Kathleen
    /// (d. 2016) had one such namesake leak through pass 5
    /// because `.pedigree` wasn't in the death-year extractor.
    nonisolated static func candidateDeathYear(_ record: SourceRecord) -> Int? {
        switch record {
        case .death(let r): return r.deathYear
        case .burial(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        case .military(let r): return r.deathYear
        case .pedigree(let r): return r.deathYear
        case .birth, .census, .marriage, .parish: return nil
        }
    }
}
