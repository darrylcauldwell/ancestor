import Foundation

/// The four research modes — each tunes pipeline thoroughness rather than
/// running different algorithms. Same dispatcher, same sources, same scoring;
/// modes differ in iteration count, fact caps, and early-stop conditions.
nonisolated enum ResearchMode: String, Sendable {
    /// Confirm what's already in the tree. Stops early if all facts corroborated.
    case verify
    /// Fill missing facts (death date, marriage). Standard iterations.
    case extend
    /// Find this person from scratch (ghost node). Broadest search.
    case discover
    /// Most thorough preset — runs everything Discover does, plus extra
    /// iterations and a higher fact cap. Use when you want the kitchen sink.
    case all
    /// The one in-app research action (SOURCE_WEIGHTING companion change,
    /// decided 2026-07-15): strictness starts strict and escalates only on
    /// miss; stopping is gap/stable-point/budget-driven through the stage
    /// ladder. The legacy presets above remain for the MCP/watcher surface,
    /// where an explicit mode is an override.
    case adaptive
}

/// Profile-contextual trigger for a research run. Used by the profile-detail
/// "Research" sheet to fire a research run with mode/scope picked at the moment
/// of triggering, rather than relying on whatever's currently set on the
/// Research view's controls.
///
/// `focus` is optional. When set, the dispatcher narrows
/// `activeRecordTypes` to `focus.recordTypes` — used by the per-gap
/// "Research parents / Research siblings / …" buttons on the profile
/// view. When nil, the pipeline runs with the full record-type set
/// (legacy whole-profile behaviour).
nonisolated struct ResearchRequest: Sendable {
    let profileID: String
    let mode: ResearchMode
    let scope: ResearchScope
    let focus: ResearchFocus?
    /// User opt-in for the prose-extraction phase (Discover/All modes only).
    /// Defaults to off because it's a ~20-min MLX workload that's only
    /// useful when the subject's location overlaps the registered
    /// prose corpora — most cross-region subjects get 0 hits and
    /// pay the full cost. Surfaced as a toggle in `ResearchConfigSheet`.
    let runProseExtraction: Bool

    init(
        profileID: String,
        mode: ResearchMode,
        scope: ResearchScope,
        focus: ResearchFocus? = nil,
        runProseExtraction: Bool = false
    ) {
        self.profileID = profileID
        self.mode = mode
        self.scope = scope
        self.focus = focus
        self.runProseExtraction = runProseExtraction
    }
}

/// How widely to fan out scope-aware sources (FreeBMD, FreeCen, FreeREG).
/// Mode is orthogonal — depth (verify/extend/discover/all) is on `ResearchMode`.
///
/// Ordered widening:
///   parish < district < county < adjacent < national
///
/// - `parish`: subject's home parish only. FreeBMD (no parish endpoint)
///   deliberately returns zero queries; sources declaring
///   `.inherentlyNational` / `.anchorPinned` / `.localCorpus` scope
///   handling ignore the picker by declaration — see `ScopeHandling`
///   (SOURCE_WEIGHTING Change 1) and SCOPE_AUDIT_2026-07.md.
/// - `district`: subject's home registration district. Sources without a
///   district axis (FreeREG, FreeCen) widen to `.county` for that source only.
/// - `county`: all districts in the subject's home county. The old `.local`.
/// - `adjacent`: home county + counties bordering it (single hop, via
///   `RegionConfig.adjacentCounties`). FreeBMD falls back to `.county` until
///   per-county district data exists for non-Derbyshire counties.
/// - `national`: entire UK catalogue. The old `.national`.
///
/// Transitional: until `Profile.birthLocationCode` ships (prior spec's Change 2),
/// `.parish` and `.district` silently widen to `.county` for any subject lacking
/// a structured location code. See RESEARCH_AXES_SPEC §3.2.
nonisolated enum ResearchScope: String, Comparable, Sendable, CaseIterable {
    case parish
    case district
    case county
    case adjacent
    case national

    private var order: Int {
        switch self {
        case .parish: return 0
        case .district: return 1
        case .county: return 2
        case .adjacent: return 3
        case .national: return 4
        }
    }

    static func < (lhs: ResearchScope, rhs: ResearchScope) -> Bool {
        lhs.order < rhs.order
    }
}

/// The person being researched.
nonisolated struct ResearchSubject: Sendable {
    /// Profile ID this subject was built from, if any.
    /// nil for manual-input subjects and leads (no profile yet exists).
    /// Required for parent-inference to create real parent-of edges.
    var profileID: String?
    var surname: String?
    /// Optional married surname for women whose `surname` carries the
    /// maiden name. Populated from `Profile.marriedSurname` (explicit
    /// user entry only — not derived from spouse, because divorce /
    /// remarriage / widowhood can change the surname-at-death in ways
    /// a single spouse-relationship can't capture). Used to fan out
    /// death-shape queries (death, burial, probate, military) so both
    /// surnames are probed. Nil for males and for women whose surname
    /// never changed.
    var marriedSurname: String? = nil
    /// ALL of a woman's married surnames, latest marriage first — a twice-
    /// married woman (e.g. Gillian Rose, whose last marriage before death was
    /// to David Grant) may have died under any of them, and we rarely know
    /// which. The death-shape probe (death/burial/probate/military) fans out
    /// across every entry so her records aren't missed under the wrong married
    /// name. Empty for males and never-married-name-changed women.
    var marriedSurnames: [String] = []
    var givenName: String?
    /// Optional middle name(s). When present, the name gate uses it to reject
    /// records whose given-name field carries a different middle initial — so
    /// "Jennifer Margaret" passes "Jennifer M Holmes" but fails "Jennifer A
    /// Holmes". Match is permissive when the record itself has no middle
    /// content (records that show only "Jennifer Holmes" still pass).
    var middleName: String?
    var birthYearFrom: Int?
    var birthYearTo: Int?
    var deathYearFrom: Int?
    var deathYearTo: Int?
    /// Latest year the subject is demonstrably ALIVE, derived from accepted
    /// life events that imply living presence (census, residence, occupation,
    /// education, military service, immigration/emigration) — never from
    /// death/burial/probate (DS-15). Lets the death-shape date gate reject a
    /// death record dated *before* a year the tree already places the subject
    /// alive: that death is a same-name namesake. Conservative by design —
    /// only unambiguous alive-events and the earliest (most certain) year of
    /// each contribute, because an over-high value would wrongly drop a real
    /// death record. Nil when no such evidence exists.
    var aliveAsOf: Int? = nil
    /// Original date strings from the profile's GenealogicalDate (e.g.
    /// "DEC 1883", "10 MAR 1937"). Carried for the Level-2 strategist
    /// prompt so the MLX model has a precise anchor for age math
    /// — `birthYearFrom`/`To` widen for search but lose the precise
    /// month/day. Nil for leads and for subjects whose profile has only
    /// estimated dates.
    var birthDateOriginal: String?
    var deathDateOriginal: String?
    var gender: Gender?
    var region: Region?
    /// Free-text death location from `Profile.deathLocation`. Used by the
    /// scorer's geography gate to validate record-side evidence whose own
    /// location data is missing — e.g. UK Probate Calendar records, which
    /// often carry only registry name + grant type with no estate address.
    /// First slice of the broader location-code plumbing (spec §23, prior
    /// "Change 2"); structured `deathLocationCode` follows when that lands.
    var deathLocation: String?
    var mode: ResearchMode
    /// Optional record-type narrowing — when set, `ResearchState.init`
    /// uses `focus.recordTypes` instead of the full default record-type
    /// set. See RESEARCH_PIPELINE_SPEC §11.4.
    var focus: ResearchFocus? = nil
    var familyContext: FamilyContext?
    /// Chapman code of the subject's home county — drives per-subject scoring,
    /// dispatch lookups, and the `BiographicalFitEvaluator` chapman anchor
    /// (slice 4 of [[project_multi_hypothesis_birth_year_plan]]).
    ///
    /// Empty string when no anchor is derivable. Callers must handle the
    /// empty case gracefully — the evaluator skips its chapman filter,
    /// SearchDispatcher should degrade to national scope or skip the
    /// chapman-coded probe. **No hardcoded Derbyshire default** — earlier
    /// builds defaulted to "DBY", which silently misfiltered non-DBY
    /// subjects (`feedback_no_hardcoded_regions`). The right value flows
    /// through `fromProfile`'s derivation chain (profile birthLocationCode
    /// → birthLocation → project setting → "").
    var homeChapmanCode: String = ""

    /// Residence search axes derived from the subject's Residence
    /// LifeEvents (Stage 2 roadmap: "life events feed research axes") —
    /// user-entered ones and evidence-absorbed ones alike (absorbed events
    /// were user-ACCEPTED through review, and their windows are closed to
    /// the attested year at mint). Sorted by window start for determinism.
    /// User-entered events are R3-authoritative data; these axes are SOFT
    /// targeting only —
    /// they widen or re-rank searches, never filter. Empty when the
    /// subject has no residence events (leads, manual subjects, thin
    /// profiles) — every consumer must tolerate the empty case.
    var residenceAxes: [ResidenceAxis] = []
    /// Burial place from a user-entered Burial LifeEvent — `location`
    /// first, else the structured cemetery name. Feeds burial-shape place
    /// axes (FindAGrave `location`, FS `q.deathLikePlace`) where it is a
    /// strictly better fit than the `deathLocation` approximation.
    var burialPlace: String? = nil
    /// County chapman derived from the burial event's place via the same
    /// derivation chain as profile fields. Nil when underivable.
    var burialChapmanCode: String? = nil
}

/// One residence axis: a place the subject is known (user-attested) to have
/// lived, with the event's year window. Soft targeting only — see
/// `ResearchSubject.residenceAxes`.
nonisolated struct ResidenceAxis: Sendable, Equatable {
    /// Freeform place text as the user entered it ("Youlgreave",
    /// "42 King St, Bakewell, Derbyshire").
    let place: String
    /// County chapman derived from the event's gazetteer locationCode or
    /// place text — nil when underivable (bare village, no county suffix).
    let chapmanCode: String?
    /// Event year window. Nil bounds are OPEN — an undated residence
    /// applies to every year (the common case: user types just a place).
    /// A start-only duration event is open-ended forward ("lived there
    /// from 1930").
    let yearFrom: Int?
    let yearTo: Int?

    /// True when the window covers `year` (open bounds always cover).
    func covers(_ year: Int) -> Bool {
        if let from = yearFrom, year < from { return false }
        if let to = yearTo, year > to { return false }
        return true
    }

    /// True when the window intersects [from, to] (nil bounds open on
    /// either side).
    func overlaps(from: Int?, to: Int?) -> Bool {
        if let queryFrom = from, let axisTo = yearTo, axisTo < queryFrom { return false }
        if let queryTo = to, let axisFrom = yearFrom, axisFrom > queryTo { return false }
        return true
    }
}

/// Known family members for the family context gate.
///
/// Split given/surname fields exist alongside the legacy `…Name` display
/// strings because most source query APIs accept surname and given name
/// as separate parameters (FamilySearch `q.fatherSurname`/`q.motherSurname`,
/// FreeBMD's `motherSurname`/`spouseSurname` params, FAG's
/// `firstname`+`lastname`). The display strings stay for any consumer
/// that wants the formatted form.
///
/// For `motherSurname`: falls back to the subject's `mothersMaidenName`
/// when the mother isn't a linked profile but the MMN is recorded on
/// the subject (a common case for early-19th-century work where the
/// mother's identity is partially known via the subject's birth-index).
nonisolated struct FamilyContext: Sendable {
    let spouseName: String?
    let spouseSurname: String?
    let spouseGivenName: String?
    /// Wife's maiden surname when recoverable from the spouse's own father
    /// on the tree. The wikitree convention has `Profile.lastName = maiden`
    /// for women, but some imports (the Cauldwell.twin-export) carry wives
    /// under their married surname instead — e.g. Sarah Cauldwell's
    /// `lastName = "Cauldwell"` while her actual maiden is "Ward" via her
    /// father Joseph Ward. For a male subject, FreeBMD marriage probes
    /// need this maiden surname (bride side at the marriage index) — the
    /// recorded `spouseSurname` is just the wife's married name and yields
    /// `Cauldwell × Cauldwell` searches that miss the real record. Nil
    /// when the spouse has no linked father on the tree or when the
    /// spouse's `lastName` already matches the father's surname (well-
    /// imported wife under her maiden name).
    let spouseFatherSurname: String?
    let childNames: [String]
    let fatherName: String?
    let fatherSurname: String?
    let fatherGivenName: String?
    let motherName: String?
    let motherSurname: String?
    let motherGivenName: String?
    /// Marriage place recorded on the subject's spouse relationship, when
    /// present on the tree. Feeds FS's `q.marriageLikePlace` (#Change6).
    /// nil when there's no spouse edge or the edge carries no location.
    let marriageLocation: String?

    /// Custom init so `marriageLocation` (#Change6) can default to nil —
    /// keeps every existing call site (incl. tests) compiling without
    /// threading the new axis through each one.
    init(
        spouseName: String?,
        spouseSurname: String?,
        spouseGivenName: String?,
        spouseFatherSurname: String?,
        childNames: [String],
        fatherName: String?,
        fatherSurname: String?,
        fatherGivenName: String?,
        motherName: String?,
        motherSurname: String?,
        motherGivenName: String?,
        marriageLocation: String? = nil
    ) {
        self.spouseName = spouseName
        self.spouseSurname = spouseSurname
        self.spouseGivenName = spouseGivenName
        self.spouseFatherSurname = spouseFatherSurname
        self.childNames = childNames
        self.fatherName = fatherName
        self.fatherSurname = fatherSurname
        self.fatherGivenName = fatherGivenName
        self.motherName = motherName
        self.motherSurname = motherSurname
        self.motherGivenName = motherGivenName
        self.marriageLocation = marriageLocation
    }
}

nonisolated extension ResearchSubject {
    var displayName: String {
        [givenName, surname].compactMap { $0 }.joined(separator: " ")
    }

    /// Year range for a given record type.
    func yearRange(for recordType: RecordType) -> (from: Int?, to: Int?) {
        switch recordType {
        case .birth, .christening, .baptism:
            return (birthYearFrom.map { $0 - 2 }, birthYearTo.map { $0 + 2 })
        case .death, .burial, .probate:
            if let df = deathYearFrom { return (df - 2, (deathYearTo ?? df) + 2) }
            // Fallback: birth + 15 to birth + 95
            if let bf = birthYearFrom { return (bf + 15, (birthYearTo ?? bf) + 95) }
            return (nil, nil)
        case .marriage:
            if let bf = birthYearFrom { return (bf + 16, (deathYearTo ?? (birthYearTo ?? bf) + 60)) }
            return (nil, nil)
        case .census:
            let earliest = birthYearFrom ?? 1841
            let latest = deathYearTo ?? (birthYearTo.map { $0 + 80 } ?? 1911)
            return (earliest, latest)
        default:
            return (birthYearFrom, deathYearTo ?? birthYearTo)
        }
    }

    /// Surnames to probe for `recordType`, deduplicated, in priority order.
    ///
    /// Always probes the canonical `surname`. Two optional widenings
    /// follow, both gated on the import state and the record type's
    /// indexing convention:
    ///
    /// 1. **Maiden-axis** — for female subjects whose recorded
    ///    `surname` is in fact the married name (inverted import,
    ///    where the maiden surname is recoverable as
    ///    `familyContext.fatherSurname`). Added for record types
    ///    indexed under the maiden surname: birth / baptism /
    ///    christening (pre-marriage by definition), marriage (bride
    ///    side), parish (FreeREG free-text axis), and census (early
    ///    years pre-marriage).
    ///
    /// 2. **Married-axis** — for female subjects whose recorded
    ///    `surname` is the maiden name and an explicit
    ///    `marriedSurname` is set. Added for record types where UK
    ///    indexes file deceased married women under their married
    ///    surname: death / burial / probate / military, and census
    ///    (post-marriage years).
    ///
    /// Both axes can fire simultaneously on `.census`, which spans
    /// pre- and post-marriage years.
    ///
    /// Returns `[]` if `surname` is nil.
    func surnamesToProbe(for recordType: RecordType) -> [String] {
        guard let surname else { return [] }
        var out: [String] = [surname]

        // Maiden-surname probe for female subjects whose `surname` is in
        // fact their married name (the wikitree convention is
        // `lastName = maiden`, but some imports arrive inverted —
        // Elizabeth Cauldwell appears as `lastName = "Beighton"` and
        // Catherine Hannah Bown appears as `lastName = "Ward"`).
        // Derive the maiden side from the father's surname on the
        // family-context block; only add if it differs from the
        // recorded surname.
        //
        // Applies to record types where the woman was indexed under
        // her maiden name:
        // * `.marriage` — bride side at FreeBMD/FreeREG.
        // * `.birth`, `.baptism`, `.christening` — by definition
        //   pre-marriage, always under maiden.
        // * `.parish` — pre-1837 BMDs in FreeREG; a maiden probe is
        //   safe even for post-marriage events because the source
        //   accepts surname as a free-text axis.
        // * `.census` — covers the woman's whole life, so both
        //   surnames are valid probe keys (early censuses under
        //   maiden, later under married). The post-marriage axis
        //   below already adds the married surname for `.census`.
        let probesMaidenAxis: Bool = switch recordType {
        case .birth, .baptism, .christening, .marriage, .parish, .census: true
        default: false
        }
        if probesMaidenAxis,
           gender == .female,
           let fatherSurname = familyContext?.fatherSurname,
           !fatherSurname.isEmpty,
           fatherSurname.caseInsensitiveCompare(surname) != .orderedSame {
            out.append(fatherSurname)
        }

        // Death-shape probes (existing logic) — add married surname
        // when the subject's recorded surname is the maiden form and
        // the woman was filed under her married surname at death.
        let probesMarriedAxis: Bool = switch recordType {
        case .death, .burial, .probate, .military, .census: true
        default: false
        }
        if probesMarriedAxis {
            // Fan out across EVERY married surname (latest marriage first) — a
            // remarried woman may have died under any of them, and we rarely
            // know which. Falls back to the single `marriedSurname` for
            // subjects built without the plural list.
            let marriedList = marriedSurnames.isEmpty
                ? [marriedSurname].compactMap { $0 }
                : marriedSurnames
            for married in marriedList
            where !married.isEmpty
                && married.caseInsensitiveCompare(surname) != .orderedSame
                && !out.contains(where: { $0.caseInsensitiveCompare(married) == .orderedSame }) {
                out.append(married)
            }
        }

        return out
    }

    /// Refine the subject from confirmed facts (learned date propagation).
    func refined(withBirthYear: Int? = nil, withDeathYear: Int? = nil) -> ResearchSubject {
        var s = self
        if let by = withBirthYear {
            s.birthYearFrom = by
            s.birthYearTo = by
        }
        if let dy = withDeathYear {
            s.deathYearFrom = dy
            s.deathYearTo = dy
        }
        return s
    }

    /// Pick a narrower birth window from persisted `field_sources` entries
    /// when there's an **unambiguous** winner — strictly narrower than the
    /// current window AND uniquely narrowest among the parseable
    /// candidates.
    ///
    /// Returns the current window unchanged when:
    /// - no source parses to a narrower window;
    /// - multiple sources tie at the narrowest span (silent disambiguation
    ///   is unsafe — picking by recency or arbitrary order can seed the
    ///   wrong year. The multi-hypothesis investigation slice will use
    ///   `BiographicalFitEvaluator` to choose between tied candidates;
    ///   until then, refuse and let the engine work from the wider envelope);
    /// - the `birthDate` field has an unresolved or `.deferred` dispute on
    ///   file (the user explicitly deferred picking a winner).
    static func narrowBirthWindowFromSources(
        current: (Int?, Int?),
        sources: [FieldSource],
        dispute: FieldDispute?
    ) -> (Int?, Int?) {
        if let dispute, dispute.resolution == nil || dispute.resolution == .deferred {
            return current
        }
        let currentSpan = yearSpan(from: current.0, to: current.1)

        struct Candidate: Equatable {
            let earliest: Int
            let latest: Int
            let span: Int
        }

        let candidates: [Candidate] = sources.compactMap { src in
            let date = GenealogicalDate(parsing: src.raw)
            guard let e = date.earliest, let l = date.latest else { return nil }
            return Candidate(earliest: e, latest: l, span: l - e)
        }
        let strictlyNarrower = candidates.filter { $0.span < currentSpan }
        guard let minSpan = strictlyNarrower.map(\.span).min() else { return current }
        // De-duplicate identical (earliest, latest) entries among the
        // narrowest candidates — the same row written twice across two
        // FreeBMD scoring passes is not a disagreement. After dedup, only
        // narrow when exactly one distinct window survives.
        let narrowestDistinct = Set(strictlyNarrower
            .filter { $0.span == minSpan }
            .map { Pair(e: $0.earliest, l: $0.latest) })
        guard narrowestDistinct.count == 1, let winner = narrowestDistinct.first else {
            return current
        }
        return (winner.e, winner.l)
    }

    /// Hashable pair used to dedupe identical narrowest-candidate windows
    /// before deciding whether ties exist.
    private struct Pair: Hashable {
        let e: Int
        let l: Int
    }

    /// Span between two years, treating either nil as "infinite" so any
    /// finite source wins.
    private static func yearSpan(from: Int?, to: Int?) -> Int {
        guard let f = from, let t = to else { return .max }
        return t - f
    }

    /// Build from an existing profile.
    ///
    /// `homeChapmanCode` parameter is the project-level setting (the user's
    /// chosen dominant county for the tree at project creation, or "" if
    /// unset). It's used as a fallback ONLY when the profile's own location
    /// data doesn't resolve to a chapman. Derivation order (most specific
    /// wins):
    ///   1. `profile.birthLocationCode` (gazetteer ID — split on `:`, take
    ///      the chapman prefix)
    ///   2. `profile.birthLocation` (free-text place name) via
    ///      `FreeBMDDistrictCatalogue.shared.district(named:)?.chapmanCode`
    ///   3. The `homeChapmanCode` parameter (project-level setting)
    ///   4. "" (no anchor — evaluator's chapman filter and dispatcher's
    ///      chapman-coded probes degrade to permissive / national)
    static func fromProfile(
        _ profile: Profile,
        snapshot: FamilyGraphSnapshot,
        mode: ResearchMode = .extend,
        focus: ResearchFocus? = nil,
        homeChapmanCode: String = ""
    ) -> ResearchSubject {
        // Build family context from the tree
        let spouses = snapshot.spousesOf(profile.id)
        let children = snapshot.childrenOf(profile.id)
        let parents = snapshot.parentsOf(profile.id)

        // Filter implausible biological parents out of pipeline context
        // before building FamilyContext. Mirrors the parent-age-gap
        // guard in `agent/pipeline.py:96-109` — a parent linked with
        // birth year < 14 years before the subject is almost certainly
        // a mis-typed sibling (FamilySearch and GEDCOM imports both
        // produce this shape when role tags drift). Without this
        // filter their name leaks into FamilyContext.fatherName /
        // .motherName and contaminates name-gate scoring + the
        // parent-link verdict. The audit's ParentAgeGapRule still
        // surfaces it to the user; this stops it polluting research.
        // Adoptive parents (subtype != .biological) are exempt — a
        // guardian can be any age relative to the child.
        let plausibleParents = parents.filter { parent in
            guard let subjectYear = profile.birthDate?.earliest,
                  let parentYear = parent.birthDate?.earliest else {
                return true
            }
            let isBiological = snapshot.relationships.contains {
                $0.type == .parent && $0.from == parent.id && $0.to == profile.id
                    && $0.subtype == .biological
            }
            guard isBiological else { return true }
            return subjectYear - parentYear >= 14
        }
        let father = plausibleParents.first(where: { $0.gender == .male })
        let mother = plausibleParents.first(where: { $0.gender == .female })

        // Derive the spouse's maiden surname from the spouse's own father
        // on the tree. For male subjects whose wife is recorded under her
        // married surname (inverted import), this is the only way to
        // recover the maiden form FreeBMD's marriage index actually uses
        // on the bride side. Mirrors the female-side maiden recovery in
        // `surnamesToProbe`, but operates across the profile boundary —
        // spouse → spouse's parents → father's lastName.
        let spouseFatherSurname: String? = {
            guard let spouseID = spouses.first?.id else { return nil }
            let spouseParents = snapshot.parentsOf(spouseID)
            return spouseParents.first(where: { $0.gender == .male })?.lastName
        }()

        // Marriage place from the subject's spouse edge (#Change6). Read in
        // either edge direction; blank/whitespace treated as absent.
        let marriageLocation: String? = {
            guard let spouseID = spouses.first?.id else { return nil }
            let edge = snapshot.relationships.first {
                $0.type == .spouse &&
                (($0.from == profile.id && $0.to == spouseID) ||
                 ($0.from == spouseID && $0.to == profile.id))
            }
            let loc = edge?.marriageLocation?.trimmingCharacters(in: .whitespaces)
            return (loc?.isEmpty == false) ? loc : nil
        }()

        let context = FamilyContext(
            spouseName: spouses.first?.displayName,
            spouseSurname: spouses.first?.lastName,
            spouseGivenName: spouses.first?.firstName,
            spouseFatherSurname: spouseFatherSurname,
            childNames: children.map(\.displayName),
            fatherName: father?.displayName,
            fatherSurname: father?.lastName,
            fatherGivenName: father?.firstName,
            motherName: mother?.displayName,
            // Mother's surname falls back to the subject's MMN when the
            // mother isn't a linked profile but is recorded via the
            // birth-index entry on the subject itself — common for early
            // generations where mother's identity is partial.
            motherSurname: mother?.lastName ?? profile.mothersMaidenName,
            motherGivenName: mother?.firstName,
            marriageLocation: marriageLocation
        )

        // Birth window — hard date wins when present. When absent (common
        // for parents added by name only via the onboarding wizard), derive a
        // soft window from the oldest known child's birth year: parents are
        // typically 18..45 years older than their first child. Without this
        // fallback the date gate fails with "insufficient date information"
        // for every record, which downgrades real birth records to leads and
        // blocks identity resolution + auto-promote. The wide window (~27
        // years) is automatically downgraded to a "weakly supported" cluster
        // verdict so we don't auto-promote on thin air.
        let (birthFromInitial, birthToInitial): (Int?, Int?) = {
            if let date = profile.birthDate, date.earliest != nil || date.latest != nil {
                return (date.earliest, date.latest)
            }
            // Spouse-birth inference (the "Ethel-class": a married profile with
            // no birth date and a common name is otherwise unresearchable). Use
            // a spouse's birth year ± 5 — spouses are typically within a few
            // years of age — as a SEARCH window only. Own DOB always wins
            // (handled above); this fires only when the birth date is empty and
            // is never written back to the profile. Preferred over the wider
            // children fallback below because ±5 is a tighter, more direct
            // anchor. The window's width still caps clusters to leads, so an
            // estimate never auto-promotes. Deterministic spouse pick (by id).
            let spouseWindow: (Int, Int)? = spouses
                .sorted { $0.id < $1.id }
                .lazy
                .compactMap { spouse -> (Int, Int)? in
                    guard let earliest = spouse.birthDate?.earliest else { return nil }
                    return (earliest - 5, (spouse.birthDate?.latest ?? earliest) + 5)
                }
                .first
            if let spouseWindow { return spouseWindow }
            let childYears = children.compactMap { $0.birthDate?.earliest }
            guard let oldestChildYear = childYears.min() else { return (nil, nil) }
            return (oldestChildYear - 45, oldestChildYear - 18)
        }()

        // Seed birth-year precision from persisted `field_sources` for
        // `birthDate`. `Profile.birthDate` carries only one value (the
        // wide range when sources disagree), but `profile.sources[.birthDate]`
        // is the audit log of every value any source ever asserted. A prior
        // run may have written a precise quarter (e.g. "Dec 1883") that
        // never got promoted to `profile.birthDate` because of a conflict
        // — without this seeding, each new run restarts from the wide
        // 27-year window regardless of what previous runs uncovered, and
        // `refineSubject` (which reads only the *in-run* `state.confirmedFacts`)
        // has nothing to work with on the first iteration.
        //
        // Selection rule: narrowest year-span wins; ties broken by most
        // recent `addedAt`. Refuse to narrow when an unresolved dispute
        // is on file — the user explicitly deferred the choice and we
        // shouldn't auto-pick one of the competing values behind their
        // back.
        let (birthFrom, birthTo) = Self.narrowBirthWindowFromSources(
            current: (birthFromInitial, birthToInitial),
            sources: profile.sources[.birthDate] ?? [],
            dispute: profile.disputes[.birthDate]
        )

        // Derive marriedSurname for female subjects whose profile field
        // is empty but the spouse on the tree carries a different
        // surname. Mirrors the deterministic spouse-surname pivot in
        // `agent/pipeline.py:_expand_post_marriage_searches` —
        // women's death + probate records are filed under the married
        // surname, so without this derivation those searches probe
        // only the maiden surname and silently miss everything.
        // Lilian Mary Brooks (died as HOLMES, 1995, Amber Valley) is
        // the canonical case: WikiTree's LastNameCurrent stays "Brooks"
        // even after marriage, so `profile.marriedSurname` is nil but
        // her spouse Reginald Holmes is right there in the snapshot.
        let derivedMarriedSurname: String? = {
            if let explicit = profile.marriedSurname, !explicit.isEmpty {
                return explicit
            }
            guard profile.gender == .female else { return nil }
            let ownSurname = (profile.lastName ?? "").lowercased()
            for spouse in spouses {
                let spouseSurname = (spouse.lastName ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !spouseSurname.isEmpty,
                   spouseSurname.lowercased() != ownSurname {
                    return spouseSurname
                }
            }
            return nil
        }()

        // Every distinct married surname, latest marriage first, for the
        // death-side probe fan-out. A remarried woman (Gillian Rose → … →
        // David Grant) may have died under any of them.
        let derivedMarriedSurnames: [String] = {
            guard profile.gender == .female else { return [] }
            let ownSurname = (profile.lastName ?? "").lowercased()
            var pairs: [(surname: String, year: Int)] = []
            for rel in snapshot.relationships
            where rel.type == .spouse && (rel.from == profile.id || rel.to == profile.id) {
                let otherID = rel.from == profile.id ? rel.to : rel.from
                guard let spouse = snapshot.profiles[otherID] else { continue }
                let ss = (spouse.lastName ?? "").trimmingCharacters(in: .whitespaces)
                guard !ss.isEmpty, ss.lowercased() != ownSurname else { continue }
                // Undated marriages sort last (Int.min under descending order).
                pairs.append((ss, rel.marriageDate?.bestYear ?? Int.min))
            }
            let latestFirst = pairs.sorted { $0.year > $1.year }
            var seen = Set<String>()
            var out: [String] = []
            // An explicit married surname (the user's authoritative "known as")
            // leads the list.
            if let explicit = profile.marriedSurname?.trimmingCharacters(in: .whitespaces),
               !explicit.isEmpty {
                out.append(explicit)
                seen.insert(explicit.lowercased())
            }
            for p in latestFirst where seen.insert(p.surname.lowercased()).inserted {
                out.append(p.surname)
            }
            return out
        }()

        // Life-event research axes (Stage 2 roadmap). Residence and Burial
        // LifeEvents the user entered become soft search axes. `sensitive`
        // events are excluded HERE, before any of their text could reach an
        // outbound source query — the snapshot loader does not filter them.
        // Deterministic ordering (window start, then place) because
        // snapshot.lifeEvents arrays are unsorted.
        let subjectEvents = snapshot.lifeEvents[profile.id] ?? []
        // DS-15: latest year the subject is demonstrably alive from accepted
        // life events that imply living presence — never burial/probate
        // (post-death) or the ambiguous `.other`. The scorer uses this to
        // reject a death record dated before a year the tree already places
        // the subject alive. Conservative: the EARLIEST (most certain) year of
        // each event, MAX across events — an over-high value would wrongly
        // drop a real death. Sensitive events are excluded, consistent with
        // the residence/burial axes above (the derived year surfaces in the
        // scorer's verdict reason, so it must not originate from sensitive
        // data); DS-15 still fires on any non-sensitive census/residence.
        let aliveImplyingTypes: Set<LifeEventType> = [
            .census, .residence, .occupation, .education,
            .militaryService, .religion, .immigration, .emigration,
        ]
        let derivedAliveAsOf: Int? = subjectEvents
            .filter { aliveImplyingTypes.contains($0.type) && !$0.sensitive }
            .compactMap { $0.date?.earliest }
            .max()
        let derivedResidenceAxes: [ResidenceAxis] = subjectEvents
            .filter { $0.type == .residence && !$0.sensitive }
            .compactMap { event -> ResidenceAxis? in
                guard let place = event.location?.trimmingCharacters(in: .whitespaces),
                      !place.isEmpty else { return nil }
                return ResidenceAxis(
                    place: place,
                    chapmanCode: chapmanCodeFromLocationCode(event.locationCode)
                        ?? Self.chapmanCode(forPlaceText: place),
                    yearFrom: event.date?.earliest,
                    // End of a duration event; a start-only residence is
                    // open-ended forward ("lived there from 1930").
                    yearTo: event.endDate?.latest ?? event.endDate?.earliest
                )
            }
            .sorted {
                if ($0.yearFrom ?? Int.min) != ($1.yearFrom ?? Int.min) {
                    return ($0.yearFrom ?? Int.min) < ($1.yearFrom ?? Int.min)
                }
                return $0.place < $1.place
            }
        // Best burial event: prefer one that yields a place (location, else
        // structured cemetery), then a dated one, with UUID order only as
        // the final deterministic tie-break — a place-less stub must never
        // shadow a located event.
        func burialEventPlace(_ event: LifeEvent) -> String? {
            if let loc = event.location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty {
                return loc
            }
            if case .burial(let details)? = event.details,
               let cemetery = details.cemetery?.trimmingCharacters(in: .whitespaces),
               !cemetery.isEmpty {
                // A bare cemetery name is a weak match key for external
                // sources — compose the county name in when the event's
                // gazetteer code yields one ("St. Anne Churchyard,
                // Derbyshire" matches; the bare name may not).
                if let chapman = chapmanCodeFromLocationCode(event.locationCode) {
                    let county = RecordScorer.countyName(forChapman: chapman)
                    if !county.isEmpty,
                       !cemetery.lowercased().contains(county.lowercased()) {
                        return "\(cemetery), \(county)"
                    }
                }
                return cemetery
            }
            return nil
        }
        let burialEvent = subjectEvents
            .filter { $0.type == .burial && !$0.sensitive }
            .sorted { a, b in
                let aPlace = burialEventPlace(a) != nil
                let bPlace = burialEventPlace(b) != nil
                if aPlace != bPlace { return aPlace }
                let aDated = a.date != nil
                let bDated = b.date != nil
                if aDated != bDated { return aDated }
                return a.id.uuidString < b.id.uuidString
            }
            .first
        let derivedBurialPlace: String? = burialEvent.flatMap(burialEventPlace)
        let derivedBurialChapman: String? = burialEvent.flatMap { event in
            chapmanCodeFromLocationCode(event.locationCode)
                ?? derivedBurialPlace.flatMap { Self.chapmanCode(forPlaceText: $0) }
        }

        return ResearchSubject(
            profileID: profile.id,
            surname: profile.lastName,
            marriedSurname: derivedMarriedSurname,
            marriedSurnames: derivedMarriedSurnames,
            givenName: profile.firstName,
            middleName: profile.middleName,
            birthYearFrom: birthFrom,
            birthYearTo: birthTo,
            deathYearFrom: profile.deathDate?.earliest,
            deathYearTo: profile.deathDate?.latest,
            aliveAsOf: derivedAliveAsOf,
            birthDateOriginal: profile.birthDate?.original,
            deathDateOriginal: profile.deathDate?.original,
            gender: profile.gender,
            region: profile.birthLocation.map { .county($0) },
            deathLocation: profile.deathLocation,
            mode: mode,
            focus: focus,
            familyContext: context,
            homeChapmanCode: Self.deriveHomeChapmanCode(
                from: profile, projectFallback: homeChapmanCode
            ),
            residenceAxes: derivedResidenceAxes,
            burialPlace: derivedBurialPlace,
            burialChapmanCode: derivedBurialChapman
        )
    }

    /// Resolve a Chapman code for a subject from the profile's own data,
    /// falling back to the project-level setting. Used by every builder
    /// so derivation logic stays in one place.
    ///
    /// Order:
    ///   1. `birthLocationCode` — the gazetteer ID set via LocationPicker.
    ///      Format is "{CHAPMAN}:{place}" (e.g. "DBY:Crich"). Take the
    ///      prefix up to the colon and validate it as a 3-letter code.
    ///   2. `birthLocation` — free-text place name. Look up via
    ///      `FreeBMDDistrictCatalogue.shared.district(named:)?.chapmanCode`.
    ///      Matches when the location name happens to be a registration
    ///      district name (Belper, Bakewell, Marylebone, …).
    ///   3. `projectFallback` — the project-level setting the user chose at
    ///      creation. Used when the profile has no usable location data.
    ///   4. Empty string — anchor unresolvable.
    static func deriveHomeChapmanCode(
        from profile: Profile,
        projectFallback: String
    ) -> String {
        if let code = chapmanCodeFromLocationCode(profile.birthLocationCode) {
            return code
        }
        if let name = profile.birthLocation,
           let code = Self.chapmanCode(forPlaceText: name) {
            return code
        }
        return projectFallback
    }

    /// Chapman code from a freeform place string — the tier-2 logic of
    /// `deriveHomeChapmanCode`, extracted so LifeEvent place strings run
    /// through the IDENTICAL derivation as profile fields (Stage 2 roadmap
    /// requirement):
    ///   1. Exact registration-district match (e.g. "Bakewell") via
    ///      `FreeBMDDistrictCatalogue`.
    ///   2. County-component scan of a freeform "Parish, County[, Country]"
    ///      string. A village like "Ashford in the Water" is not a
    ///      registration district, so the district match above misses it —
    ///      but the county component ("Derbyshire") still yields the anchor
    ///      (owner report 2026-07-15: a valid "…, Derbyshire" birthplace
    ///      still defaulted the subject to anchor-less National). County is
    ///      usually the last-but-one component, so scan from the end.
    /// Nil when neither tier resolves (bare village, no county suffix).
    static func chapmanCode(forPlaceText raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let code = FreeBMDDistrictCatalogue.shared
            .district(named: name)?.chapmanCode {
            return code
        }
        let components = name.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for component in components.reversed() {
            if let code = UKChapmanCodes.shared.chapmanCode(forCountyName: component) {
                return code
            }
        }
        return nil
    }

    /// Parse a 3-letter Chapman code prefix from a gazetteer ID like
    /// "DBY:Crich". Returns nil for nil input, empty input, or strings
    /// without a colon-delimited 3-letter prefix.
    private static func chapmanCodeFromLocationCode(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces),
              !code.isEmpty else { return nil }
        let prefix: String
        if let colon = code.firstIndex(of: ":") {
            prefix = String(code[..<colon])
        } else {
            prefix = code
        }
        let cleaned = prefix.trimmingCharacters(in: .whitespaces).uppercased()
        guard cleaned.count == 3,
              cleaned.allSatisfy({ $0.isLetter })
        else { return nil }
        return cleaned
    }

    /// Build from a Lead. Leads aren't on the tree yet so there's no family
    /// context to derive — `familyContext` is nil and `profileID` is nil too.
    /// The subject's identity carries through (surname/given/birth-year) so
    /// the dispatcher searches for *this* person, not the profile that
    /// generated the lead. Without this constructor, `investigateLead` was
    /// re-researching the generating profile rather than the lead itself.
    /// `homeChapmanCode` parameter is the project-level setting; leads
    /// don't carry chapman-mappable location data, so it's the only
    /// derivation source available. Pass "" if unset.
    static func fromLead(
        _ lead: Lead,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = ""
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: lead.surname,
            givenName: lead.givenName,
            birthYearFrom: lead.birthYear,
            birthYearTo: lead.birthYear,
            deathYearFrom: lead.deathYear,
            deathYearTo: lead.deathYear,
            gender: nil,
            region: nil,
            mode: mode,
            familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }

    /// Build from manual user input. `location` is the user's free-text
    /// place; if it resolves via `FreeBMDDistrictCatalogue` to a chapman
    /// code, that wins over the `homeChapmanCode` parameter (project
    /// setting). Pass "" if the project setting is unset.
    static func fromUserInput(
        surname: String?, givenName: String?,
        birthYear: Int?, deathYear: Int?,
        gender: Gender?, location: String?,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = ""
    ) -> ResearchSubject {
        let derivedChapman: String = {
            if let name = location?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty,
               let code = FreeBMDDistrictCatalogue.shared
                .district(named: name)?.chapmanCode {
                return code
            }
            return homeChapmanCode
        }()
        return ResearchSubject(
            surname: surname, givenName: givenName,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: deathYear, deathYearTo: deathYear,
            gender: gender,
            region: location.map { .county($0) },
            mode: mode,
            familyContext: nil,
            homeChapmanCode: derivedChapman
        )
    }
}
