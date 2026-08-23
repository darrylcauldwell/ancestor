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
    /// Widest scope — opt-in inclusion of records outside the UK (DS-11/
    /// DS-19). Purely additive over `.national`: UK-source dispatch is
    /// unchanged, FindAGrave lifts its location pin, and the geography gate
    /// soft-fails (rather than hard-fails) obviously-foreign places so an
    /// emigrant's overseas records surface as reviewable leads instead of
    /// being dropped. Never a default — the user selects it deliberately.
    case international

    private var order: Int {
        switch self {
        case .parish: return 0
        case .district: return 1
        case .county: return 2
        case .adjacent: return 3
        case .national: return 4
        case .international: return 5
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
    /// The earliest year the subject held a married surname — her first
    /// marriage year, or nil when no dated marriage is known. The name gate
    /// uses this as a TEMPORAL BOUND on the married-surname axis: a married
    /// surname is an acceptable match only for a record dated at/after this
    /// year. Before her marriage she was recorded under her maiden name, so a
    /// same-married-surname record that predates the marriage is a namesake —
    /// the worst-class scorer bug it fixes silently fused two women (owner
    /// dogfood: an 1891 census "Mary E HOLMES", born Holmes and an unmarried
    /// daughter of a Holmes head, matched a subject who only became Holmes by a
    /// 1915 marriage). Nil here, or an undated record, applies no bound
    /// (conservative — never drops a legitimate record for want of a date).
    var marriedSurnameEffectiveFrom: Int? = nil
    var givenName: String?
    /// Optional middle name(s). When present, the name gate uses it to reject
    /// records whose given-name field carries a different middle initial — so
    /// "Jennifer Margaret" passes "Jennifer M Holmes" but fails "Jennifer A
    /// Holmes". Match is permissive when the record itself has no middle
    /// content (records that show only "Jennifer Holmes" still pass).
    var middleName: String?
    var birthYearFrom: Int?
    var birthYearTo: Int?
    /// True when the birth year rests only on DERIVED evidence — an age
    /// subtracted from a census, or an explicitly approximate date — with no
    /// birth-shape record behind it.
    ///
    /// The search window and the date gate are both built from the birth year,
    /// so when that year is wrong the record that would CORRECT it falls out of
    /// range. Owner dogfood 2026-08-22: Jacob Holmes sat at b.~1823 from a
    /// census age of 38; his real baptism is 1817. The window was 1821–1825 and
    /// `start_year`/`end_year` go to FreeREG server-side, so the baptism was
    /// never returned. Editing the year by hand to 1817 made it appear
    /// instantly — the same register, the same query, one number different.
    ///
    /// A census age is the least reliable number in genealogy (round numbers,
    /// mis-remembered ages, deliberate fudges — Jacob's was out by five). A
    /// baptism is not. Widening the window in proportion to how the anchor was
    /// established is the difference between a searchable person and one whose
    /// own evidence is unreachable.
    var birthAnchorIsDerived: Bool = false
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
    /// Census-year EXCLUSIVITY (owner dogfood): for each census year the
    /// subject already has an APPLIED census for, the set of that census's
    /// household-page URLs (its identity). A person is in exactly one place on
    /// census night, so the date gate rejects a same-year census candidate
    /// whose household page differs from an applied one — a namesake at another
    /// address (sibling of the death-once check). Built from the subject's
    /// applied census life-events; empty for a year → no bound (and a candidate
    /// with no household-page URL is never rejected — can't prove it differs).
    var appliedCensusIdentitiesByYear: [Int: Set<String>] = [:]
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
    /// When true, the geography gate soft-fails obviously-foreign places
    /// (→ `.lead`) instead of hard-failing them. Set by the pipeline only for
    /// an `.international`-scope run (DS-11/DS-19) — an explicit opt-in to
    /// surface emigrant/colonial records. Default false keeps every other
    /// run Triage-clean.
    var includeForeignRecords: Bool = false

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

    /// SUBJECT_PLACE_MODEL_SPEC Slice 2 — every place we know about this
    /// person, in one shape, in precedence order (birth, death, burial,
    /// marriage, then residence and census by event window).
    ///
    /// **Nothing reads this yet.** It is populated alongside the five flattened
    /// fields above so Slice 3 can move consumers one at a time, each proving
    /// the characterization tests still pass. Behaviour change in Slice 2 is
    /// zero by construction.
    ///
    /// Order is the contract: `places.first` is the best-evidenced place, and
    /// `places.chapmanCodes.first` is the same county `homeChapmanCode` derives
    /// today. A source that can afford one axis takes the first; a source that
    /// can afford several takes a bounded prefix. Sorting anywhere downstream
    /// would destroy that and hand out whichever county sorts first.
    ///
    /// Sensitive places ARE included, carrying the flag. The array accessors
    /// exclude them by default, so the existing filtering behaviour is what a
    /// consumer gets without asking — but the information that a place was
    /// withheld survives, instead of being destroyed at derivation the way
    /// `residenceAxes` destroys it.
    var places: [PlaceRef] = []
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
    /// Birth years of the subject's children (earliest-known per child),
    /// unsorted. A marriage precedes the first child, so this tightens the
    /// marriage search window (UV-01). Empty when no child has a known year.
    let childBirthYears: [Int]
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
        marriageLocation: String? = nil,
        childBirthYears: [Int] = []
    ) {
        self.spouseName = spouseName
        self.spouseSurname = spouseSurname
        self.spouseGivenName = spouseGivenName
        self.spouseFatherSurname = spouseFatherSurname
        self.childNames = childNames
        self.childBirthYears = childBirthYears
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
    /// Birth-window padding when the anchor is census-derived. Jacob Holmes's
    /// census age was out by 5; ±8 covers that with room, and still refuses a
    /// namesake a decade adrift.
    static let derivedAnchorPad = 8

    /// True when a profile's birth year rests only on derived evidence. Pure,
    /// so the rule is testable without a graph.
    ///
    /// Two independent signals, either sufficient:
    ///  - the recorded date SAYS it is approximate (`CAL`/`ABT`/`EST`), or
    ///  - every source behind `birthDate` is a census.
    /// A hand-entered or birth-record-backed year is treated as firm — the user
    /// knowing something we can't see is not a weak anchor.
    nonisolated static func birthAnchorIsDerived(for profile: Profile) -> Bool {
        let original = (profile.birthDate?.original ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        for marker in ["CAL", "ABT", "EST", "C.", "CIRCA"] where original.hasPrefix(marker) {
            return true
        }
        let sources = profile.sources[.birthDate] ?? []
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy { src in
            let id = src.origin.identifier.lowercased()
            return id.contains("census") || id == "freecen"
        }
    }

    func yearRange(for recordType: RecordType) -> (from: Int?, to: Int?) {
        switch recordType {
        case .birth, .christening, .baptism:
            // Pad in proportion to how the anchor was established: ±2 around a
            // birth-shape record, ±8 around a census age. See
            // `birthAnchorIsDerived` — these bounds are sent to the source
            // server-side, so anything outside them is not merely rejected, it
            // is never returned.
            if let from = birthYearFrom {
                let pad = birthAnchorIsDerived ? Self.derivedAnchorPad : 2
                return (from - pad, (birthYearTo ?? from) + pad)
            }
            // No birth year at all — but a parent is bounded by their children.
            // Someone named only as a father or mother on someone else's record
            // has nothing to search on, and every window is built from the birth
            // year, so they are not merely hard to research but IMPOSSIBLE to.
            // Owner dogfood 2026-08-23: John Holmes and Sophia arrived from
            // Jacob's 1817 baptism with names and nothing else, and the same is
            // true of John Stephenson and Lydia.
            //
            // A parent is at least 16 and at most 50 years older than their
            // eldest known child. Wide, but a wide window beats no window, and
            // this invents no FACT — the profile still holds no birth date, only
            // the search is bounded.
            if let eldest = familyContext?.childBirthYears.min() {
                return (eldest - 50, eldest - 16)
            }
            return (nil, nil)
        case .death, .burial, .probate:
            if let df = deathYearFrom { return (df - 2, (deathYearTo ?? df) + 2) }
            // Fallback: birth + 15 to birth + 95
            if let bf = birthYearFrom { return (bf + 15, (birthYearTo ?? bf) + 95) }
            return (nil, nil)
        case .marriage:
            guard let bf = birthYearFrom else { return (nil, nil) }
            let wideLow = bf + 16
            let wideHigh = deathYearTo ?? (birthYearTo ?? bf) + 60
            // UV-01: a marriage precedes the first child, so when the
            // children's birth years are known, tighten the window around the
            // earliest — a marriage is rarely more than ~12 years before the
            // first surviving child and rarely after it. Intersect with the
            // wide window (never widen); fall back to the wide window when no
            // child year is known or the intersection would invert.
            if let firstChild = familyContext?.childBirthYears.min() {
                let low = max(wideLow, firstChild - 12)
                let high = min(wideHigh, firstChild + 2)
                if low <= high { return (low, high) }
            }
            return (wideLow, wideHigh)
        case .census:
            let earliest = birthYearFrom ?? 1841
            let latest = deathYearTo ?? (birthYearTo.map { $0 + 80 } ?? 1911)
            return (earliest, latest)
        case .parish:
            // A parish register spans the WHOLE life — baptism at the start,
            // marriage in the middle, burial at the end — so the window is the
            // UNION of the event-shaped windows. That way it inherits the
            // derived-anchor padding on the birth side and the +95 longevity
            // fallback on the death side, and both of those keep improving in
            // one place.
            //
            // The old fallthrough returned (birthYearFrom, deathYearTo ??
            // birthYearTo): for a subject with NO death date the window
            // collapsed to the birth year alone — as if a person's parish
            // records end the year they were born. Mary Stevenson's parish
            // searches went to the wire as start_year=1825&end_year=1825, so
            // her 1823 Youlgreave baptism could not be returned by ANY
            // spelling of any name — while the ladder, the variant fan-out
            // and the timeout retry above it were all, by then, working.
            // Every FreeREG record ever fetched for her was dated exactly
            // 1825; that uniformity was this bug's signature, visible in the
            // evidence list for days (owner dogfood 2026-08-23).
            //
            // The fix that "resolved" this the first time (86674fd) widened
            // `.baptism` — and its acceptance test TESTED `.baptism` — while
            // the live FreeREG dispatch sends `.parish`. The test passed, the
            // wire was unchanged. Test the record type the pipeline actually
            // dispatches.
            let birthShape = yearRange(for: .baptism)
            let deathShape = yearRange(for: .burial)
            let from = birthShape.from ?? deathShape.from
            let to = deathShape.to ?? birthShape.to
            if from != nil || to != nil { return (from, to) }
            return (birthYearFrom, deathYearTo ?? birthYearTo)
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
        let siblings = snapshot.siblingsOf(profile.id)

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
            marriageLocation: marriageLocation,
            childBirthYears: children.compactMap { $0.birthDate?.earliest }
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
            // Sibling-cohort inference: a dateless subject is born within the
            // span of their dated siblings (siblings share parents), so a
            // ~15-year buffer each side of the cohort covers even a large
            // family. Tighter than the children fallback below, and — unlike it
            // — available for a subject who never married or had children. Real
            // case: dateless "Eve Land" with sibling "Ida Louisa Land" (b.1885)
            // → window ~1870–1900, which rules out the 1862 and 1923/1924
            // namesake births that otherwise cluttered her leads. Search-only;
            // never written back to the profile.
            let siblingYears = siblings.compactMap { $0.birthDate?.bestYear }
            if let minSib = siblingYears.min(), let maxSib = siblingYears.max() {
                return (minSib - 15, maxSib + 15)
            }
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
        let lifeEventAliveAsOf: Int? = subjectEvents
            .filter { aliveImplyingTypes.contains($0.type) && !$0.sensitive }
            .compactMap { $0.date?.earliest }
            .max()
        // DS-15 family extension (owner report 2026-08-05: a CWGC naval death
        // dated 27 May 1915 was about to apply to an Albert Beresford who married
        // in Dec 1915 and fathered a child in 1920). The subject was demonstrably
        // ALIVE to marry and to father/bear each child, so a death before that is
        // a namesake — but these facts live on the family graph, not in life
        // events, so the life-event sweep above misses them. Marriage year is a
        // direct alive-year; a parent is alive at least the year BEFORE a child's
        // birth (conception for a father, the birth itself for a mother), so
        // `childBirthYear - 1` is a safe, conservative lower bound that never
        // over-rejects. Relationship metadata is never sensitive.
        let marriageAliveYears: [Int] = snapshot.relationships
            .filter { $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id) }
            .compactMap { $0.marriageDate?.bestYear }
        let childAliveYears: [Int] = children.compactMap { child in
            child.birthDate?.earliest.map { $0 - 1 }
        }
        // The married-surname axis opens at the marriage (DS-18's temporal
        // bound). But the RECORDED marriage date is not always the earliest
        // evidence that she bore the name — a child carrying the married
        // surname is proof she was under it by that child's birth.
        //
        // Live specimen: " Bown" (@I_1564735723@) has a spouse edge dated
        // Mar 1892 and children William Ward b. 1870 and Mary Ward b. 1889.
        // The bound closed the axis for every WARD record before 1892 — 264
        // census rows that pass both the date and geography gates — even
        // though the tree itself says she was a Ward two decades earlier.
        //
        // This may only LOWER an existing bound, never create one. When no
        // marriage is dated there is no bound today and the axis is fully
        // permissive; deriving a bound from the children would newly REJECT
        // records between the (unknown) marriage and the first child, which
        // is a narrowing — and a narrowing is the failure class the replay
        // harness exists to catch. `.map` on the recorded year keeps nil as
        // nil, so the change is strictly a widening.
        let marriedSurnamesLower = Set(derivedMarriedSurnames.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let marriedSurnameChildYears: [Int] = children.compactMap { child in
            guard let surname = child.lastName?
                    .trimmingCharacters(in: .whitespaces).lowercased(),
                  marriedSurnamesLower.contains(surname) else { return nil }
            return child.birthDate?.earliest
        }
        let derivedMarriedSurnameEffectiveFrom: Int? = marriageAliveYears.min().map {
            recorded in min(recorded, marriedSurnameChildYears.min() ?? recorded)
        }
        let derivedAliveAsOf: Int? = ([lifeEventAliveAsOf]
            + marriageAliveYears.map(Optional.some)
            + childAliveYears.map(Optional.some))
            .compactMap { $0 }
            .max()
        // Applied-census identities per year (census-year exclusivity). Each
        // applied census life-event contributes its household-page URL(s); a
        // year with no URL-bearing census contributes nothing (so it never
        // bounds a candidate we can't prove differs).
        var derivedAppliedCensusIDs: [Int: Set<String>] = [:]
        for ev in subjectEvents where ev.type == .census {
            guard let year = ev.date?.bestYear else { continue }
            let urls = ev.sources.compactMap { $0.citation?.url }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !urls.isEmpty { derivedAppliedCensusIDs[year, default: []].formUnion(urls) }
        }
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

        // SUBJECT_PLACE_MODEL_SPEC Slice 2 — the same facts, one shape.
        //
        // Built in PRECEDENCE order, and that order is the contract: it
        // reproduces `deriveHomeChapmanCode`'s chain (birth → death → …), so
        // `places.chapmanCodes.first` is the county the anchor derives today,
        // minus only the project fallback, which is not a fact about this
        // person and so is not a place of theirs. Nothing reads this yet.
        var derivedPlaces: [PlaceRef] = []
        func appendPlace(
            _ text: String?, code: String?, kind: PlaceRef.Kind,
            yearFrom: Int? = nil, yearTo: Int? = nil, sensitive: Bool = false
        ) {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty
            else { return }
            derivedPlaces.append(PlaceRef(
                text: text, code: code, kind: kind,
                yearFrom: yearFrom, yearTo: yearTo, sensitive: sensitive))
        }

        appendPlace(profile.birthLocation, code: profile.birthLocationCode, kind: .birth,
                    yearFrom: profile.birthDate?.earliest, yearTo: profile.birthDate?.latest)
        appendPlace(profile.deathLocation, code: profile.deathLocationCode, kind: .death,
                    yearFrom: profile.deathDate?.earliest, yearTo: profile.deathDate?.latest)
        if let burialEvent {
            appendPlace(derivedBurialPlace, code: burialEvent.locationCode, kind: .burial,
                        yearFrom: burialEvent.date?.earliest, yearTo: burialEvent.date?.latest)
        }
        // Marriage places off the spouse edges. Note this is the FOURTH storage
        // site carrying the same `(location, locationCode)` pair, and the only
        // one no flattened subject field represents at all.
        for edge in snapshot.relationships
            where edge.type == .spouse && (edge.from == profile.id || edge.to == profile.id) {
            appendPlace(edge.marriageLocation, code: edge.marriageLocationCode, kind: .marriage,
                        yearFrom: edge.marriageDate?.earliest,
                        yearTo: edge.marriageDate?.latest)
        }
        // Residence and census carry the SAME (location, locationCode) pair on
        // the same type; that census produces nothing today is the gap this
        // spec exists to close, so here they are simply two kinds of place.
        // Sensitive events are carried WITH their flag rather than dropped —
        // the array accessors exclude them by default, so no consumer sees a
        // change, but the fact that a place was withheld survives.
        for event in subjectEvents where event.type == .residence || event.type == .census {
            appendPlace(
                event.location, code: event.locationCode,
                kind: event.type == .census ? .census : .residence,
                yearFrom: event.date?.earliest,
                yearTo: event.endDate?.latest ?? event.endDate?.earliest
                    ?? (event.type == .census ? event.date?.latest : nil),
                sensitive: event.sensitive)
        }
        derivedPlaces.sort { a, b in
            // Stable by kind precedence first, then window, then text — the
            // event collections above arrive in no guaranteed order.
            let order: [PlaceRef.Kind] = [.birth, .death, .burial, .marriage, .residence, .census]
            let ai = order.firstIndex(of: a.kind) ?? order.count
            let bi = order.firstIndex(of: b.kind) ?? order.count
            if ai != bi { return ai < bi }
            if (a.yearFrom ?? Int.min) != (b.yearFrom ?? Int.min) {
                return (a.yearFrom ?? Int.min) < (b.yearFrom ?? Int.min)
            }
            return a.text < b.text
        }

        return ResearchSubject(
            profileID: profile.id,
            surname: profile.lastName,
            marriedSurname: derivedMarriedSurname,
            marriedSurnames: derivedMarriedSurnames,
            // Earliest year she is evidenced under a married surname — the name
            // gate's temporal bound on the married-surname axis. The earliest
            // DATED marriage, floored by the birth of any child who carries a
            // married surname (see the derivation above). Nil when no marriage
            // is dated, which means no bound at all.
            marriedSurnameEffectiveFrom: derivedMarriedSurnameEffectiveFrom,
            givenName: profile.firstName,
            middleName: profile.middleName,
            birthYearFrom: birthFrom,
            birthYearTo: birthTo,
            birthAnchorIsDerived: Self.birthAnchorIsDerived(for: profile),
            deathYearFrom: profile.deathDate?.earliest,
            deathYearTo: profile.deathDate?.latest,
            aliveAsOf: derivedAliveAsOf,
            appliedCensusIdentitiesByYear: derivedAppliedCensusIDs,
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
            burialChapmanCode: derivedBurialChapman,
            places: derivedPlaces
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
        // The subject's OWN death county, before any project-wide default.
        //
        // Birth used to be the only field consulted, so a person with no
        // birthplace fell straight through to the project's home county — and
        // someone who lived and died in Staffordshire, in a Derbyshire-anchored
        // project, was searched as Derbyshire. That is not a missing anchor, it
        // is the wrong one, asserted confidently. A death place the user
        // recorded outranks a default they set once at project creation.
        if let code = chapmanCodeFromLocationCode(profile.deathLocationCode) {
            return code
        }
        if let name = profile.deathLocation,
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
        // Delegates to the single canonical resolver (Stage 1 of the
        // location-model pass). Kept as a thin wrapper so existing call sites
        // (`Self.chapmanCode(forPlaceText:)`) are unchanged.
        ChapmanCodeResolver.chapmanCode(forPlaceText: raw)
    }

    /// Parse a 3-letter Chapman code prefix from a gazetteer ID like
    /// "DBY:Crich". Returns nil for nil input, empty input, or strings
    /// without a colon-delimited 3-letter prefix.
    ///
    /// Delegates to the canonical resolver, which now owns both halves of the
    /// question (code and text) — kept as a thin wrapper so the existing call
    /// sites here are unchanged, exactly as `chapmanCode(forPlaceText:)` was.
    static func chapmanCodeFromLocationCode(_ code: String?) -> String? {
        ChapmanCodeResolver.chapmanCode(forLocationCode: code)
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
