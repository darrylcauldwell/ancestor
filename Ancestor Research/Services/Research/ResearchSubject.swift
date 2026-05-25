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

    init(profileID: String, mode: ResearchMode, scope: ResearchScope, focus: ResearchFocus? = nil) {
        self.profileID = profileID
        self.mode = mode
        self.scope = scope
        self.focus = focus
    }
}

/// How widely to fan out scope-aware sources (FreeBMD, FreeCen, FreeREG).
/// Mode is orthogonal — depth (verify/extend/discover/all) is on `ResearchMode`.
///
/// Ordered widening:
///   parish < district < county < adjacent < national
///
/// - `parish`: subject's home parish only. Parish-unsupported sources
///   (FreeBMD, CWGC, Probate, FindAGrave) return zero queries.
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
    /// Chapman code of the subject's home county — drives per-subject scoring
    /// and dispatch lookups. Defaults to "DBY" (Derbyshire) for legacy data
    /// where the project's home_chapman_code wasn't set at creation. See
    /// RESEARCH_AXES_SPEC.md Change 1.
    var homeChapmanCode: String = "DBY"
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
        if probesMarriedAxis,
           let married = marriedSurname,
           !married.isEmpty,
           married.caseInsensitiveCompare(surname) != .orderedSame {
            out.append(married)
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

    /// Build from an existing profile.
    static func fromProfile(
        _ profile: Profile,
        snapshot: FamilyGraphSnapshot,
        mode: ResearchMode = .extend,
        focus: ResearchFocus? = nil,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        // Build family context from the tree
        let spouses = snapshot.spousesOf(profile.id)
        let children = snapshot.childrenOf(profile.id)
        let parents = snapshot.parentsOf(profile.id)

        let father = parents.first(where: { $0.gender == .male })
        let mother = parents.first(where: { $0.gender == .female })

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
            motherGivenName: mother?.firstName
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
        let (birthFrom, birthTo): (Int?, Int?) = {
            if let date = profile.birthDate, date.earliest != nil || date.latest != nil {
                return (date.earliest, date.latest)
            }
            let childYears = children.compactMap { $0.birthDate?.earliest }
            guard let oldestChildYear = childYears.min() else { return (nil, nil) }
            return (oldestChildYear - 45, oldestChildYear - 18)
        }()

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

        return ResearchSubject(
            profileID: profile.id,
            surname: profile.lastName,
            marriedSurname: derivedMarriedSurname,
            givenName: profile.firstName,
            middleName: profile.middleName,
            birthYearFrom: birthFrom,
            birthYearTo: birthTo,
            deathYearFrom: profile.deathDate?.earliest,
            deathYearTo: profile.deathDate?.latest,
            gender: profile.gender,
            region: profile.birthLocation.map { .county($0) },
            deathLocation: profile.deathLocation,
            mode: mode,
            focus: focus,
            familyContext: context,
            homeChapmanCode: homeChapmanCode
        )
    }

    /// Build from a Lead. Leads aren't on the tree yet so there's no family
    /// context to derive — `familyContext` is nil and `profileID` is nil too.
    /// The subject's identity carries through (surname/given/birth-year) so
    /// the dispatcher searches for *this* person, not the profile that
    /// generated the lead. Without this constructor, `investigateLead` was
    /// re-researching the generating profile rather than the lead itself.
    static func fromLead(
        _ lead: Lead,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = "DBY"
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

    /// Build from manual user input.
    static func fromUserInput(
        surname: String?, givenName: String?,
        birthYear: Int?, deathYear: Int?,
        gender: Gender?, location: String?,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname, givenName: givenName,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: deathYear, deathYearTo: deathYear,
            gender: gender,
            region: location.map { .county($0) },
            mode: mode,
            familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }
}
