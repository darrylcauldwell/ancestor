import Foundation

/// Phase 5 of the lead-discovery pivot (`AncestorApp/LEAD_DISCOVERY_SPEC.md`
/// §7 + §9): the identity-constraint core, SHARED between the two clustering
/// roles — acceptance (`ClusteringEngine`, rich per-subject records) and
/// discovery (`LeadDiscoveryEngine`, flat corpus leads).
///
/// Before Phase 5 each engine carried its own copy of these rules, and they
/// had already drifted (born-after-death margin was +1 in one and +2 in the
/// other; the lifespan constants lived only in ClusteringEngine). This enum is
/// now the single authority: a rule fixed here is fixed for both engines, and
/// a new rule added here reaches both. The two engines keep their own
/// *orchestration* (assignment scoring vs. blocking + agglomeration) because
/// their inputs are irreducibly different shapes — what they share is the
/// answer to "could these two pieces of evidence describe the same person?"
///
/// Every rule is contradiction-oriented (`true` = cannot be the same person →
/// split) and permissive on missing data, preserving the governing invariant:
/// **prefer over-split to over-merge**.
nonisolated enum IdentityConstraints {

    // MARK: - Constants (single source of truth)

    /// Longest plausible life. Bounds implied-birth derivation and seed windows.
    static let maxLifespanYears = 110

    /// Oldest plausible age at a non-terminal adult event (marriage, census
    /// without age) — bounds how far back a non-birth seed's window opens.
    static let maxAdultAgeYears = 90

    /// Lag margin for NON-BIRTH events recorded after a death: burial, probate,
    /// and registration routinely land 1–2 years after the death itself, so an
    /// event inside this margin is compatible with the same life.
    static let postDeathMarginYears = 2

    /// Lag margin for a person's OWN birth versus their death: only birth
    /// *registration* lag applies (no probate-style delays), so this is
    /// deliberately tighter than `postDeathMarginYears`. Pre-Phase-5 the two
    /// engines disagreed here by accident (+1 vs +2); the difference is now
    /// explicit and justified.
    static let postDeathBirthMarginYears = 1

    /// Two claimed birth years within this window can be the same person
    /// (index-year vs registration-quarter vs census-derived jitter).
    static let birthYearTolerance = 5

    /// Tighter birth window for cross-surname variant bridging — merging across
    /// a spelling variant earns LESS slack than merging within a block.
    static let bridgeBirthYearTolerance = 2

    /// Death/burial/probate year jitter for ONE true death. Two claimed death
    /// years further apart than this are two different deaths — and a person
    /// dies once.
    static let sameDeathYearTolerance = 1

    /// Youngest legal age at marriage, for REFUSAL guards (#CPC-Change1,
    /// `CROSS_PROFILE_CORROBORATION_SPEC.md` Decision 12). Pre-1929 England
    /// & Wales minima were 14 (male) / 12 (female) — Victorian marriages at
    /// 14–15 are real — so this sits deliberately below the scorer's
    /// plausibility check (`ScoringRules.checkMarriageAge`, 16): the gate
    /// scores likelihood; a refusal guard may only refuse impossibility.
    static let minMarriageAge = 14

    // MARK: - Rules (true = contradiction = must split)

    /// Both given names present with zero similarity is a real disagreement;
    /// a missing given name is permissive.
    static func givenNamesContradict(_ a: String?, _ b: String?) -> Bool {
        guard let a = nonEmpty(a), let b = nonEmpty(b) else { return false }
        return ScoringRules.nameSimilarity(a.uppercased(), b.uppercased()) == 0
    }

    /// Two birth years further apart than the tolerance are two people.
    static func birthYearsContradict(
        _ a: Int?, _ b: Int?, tolerance: Int = birthYearTolerance
    ) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) > tolerance
    }

    /// A person cannot be born after their own death (+ registration lag).
    static func bornAfterDeath(birth: Int?, death: Int?) -> Bool {
        guard let birth, let death else { return false }
        return birth > death + postDeathBirthMarginYears
    }

    /// A death ends a life: no marriage, census, or any other event after it
    /// (+ burial/probate/registration lag).
    static func eventAfterDeath(eventYear: Int?, deathYear: Int?) -> Bool {
        guard let eventYear, let deathYear else { return false }
        return eventYear > deathYear + postDeathMarginYears
    }

    /// A person dies once: two claimed death years beyond jitter are two people.
    static func distinctDeaths(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) > sameDeathYearTolerance
    }

    /// §7 geography sanity: two evidences resolved to DIFFERENT known counties
    /// describe different people; unknown geography is permissive. (Each engine
    /// resolves geography from its own data shape — registration districts via
    /// the national catalogue, or lead place tokens — but the principle decided
    /// here is the same.)
    static func countiesContradict(_ a: String?, _ b: String?) -> Bool {
        guard let a = nonEmpty(a), let b = nonEmpty(b) else { return false }
        return a.uppercased() != b.uppercased()
    }

    // MARK: - Derivations

    /// True when an age-at-death is humanly plausible (transcription junk like
    /// 999 must not fabricate a birth window).
    static func plausibleAgeAtDeath(_ age: Int) -> Bool {
        (0...maxLifespanYears).contains(age)
    }

    /// The birth year a death-with-age implies (`death − age`), nil when the
    /// age is implausible. Shared by `Lead.effectiveBirthYear` and the
    /// acceptance engine's death-implied-birth contradiction check.
    static func impliedBirthYear(deathYear: Int?, ageAtDeath: Int?) -> Int? {
        guard let deathYear, let ageAtDeath, plausibleAgeAtDeath(ageAtDeath) else { return nil }
        return deathYear - ageAtDeath
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: CharacterSet(charactersIn: " ?")),
              !t.isEmpty else { return nil }
        return t
    }
}
