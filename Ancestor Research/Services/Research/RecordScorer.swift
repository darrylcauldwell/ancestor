import Foundation
import AncestorKit

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

    /// Subject-aware variant used by the review UI and `applyCluster`. Same bar
    /// as `wouldApply`, plus a REVIEW-LAYER guard: a record that contradicts a
    /// vital the subject has ALREADY confirmed is a same-named different person
    /// (a namesake) and must not be auto-applied — even though the scoring gates
    /// classed it `.fact`. This does NOT touch the deterministic gates (the
    /// record stays `.fact`); it only refuses to write it and lets the UI say
    /// why. The user can still force-apply a single record if they disagree.
    ///
    /// Guards the observed failure: after a firm birth is confirmed (George
    /// Wheeldon b.1894 Chesterfield), re-research kept offering namesake births
    /// (1892 Bakewell, 1895 Basford) as "will apply" — a person has ONE birth,
    /// so a conflicting-year or wrong-district birth is impossible for him.
    nonisolated static func wouldApply(_ scored: ScoredRecord, subject: Profile?) -> Bool {
        guard wouldApply(scored) else { return false }
        if let subject, conflictsWithConfirmedBirth(scored, subject: subject) { return false }
        return true
    }

    /// True when `scored` is a BIRTH record that can't be the subject's own
    /// birth because the subject already has a confirmed birth it contradicts —
    /// a different year (beyond the ±1 a registration quarter can straddle) or a
    /// different registration district. No confirmed birth, or a non-birth
    /// record, → not a conflict (nothing to contradict).
    nonisolated static func conflictsWithConfirmedBirth(_ scored: ScoredRecord, subject: Profile) -> Bool {
        guard case .birth(let birth) = scored.record else { return false }
        guard let confirmedYear = subject.birthDate?.bestYear,
              let recordYear = birth.birthYear else { return false }

        // A birth registered late can cross the new year, so allow ±1.
        if abs(recordYear - confirmedYear) > 1 { return true }

        // Same-ish year but a different registration district is a different
        // birth event (Chesterfield confirmed vs Basford on the record).
        // Slice B(i) (LOCATION_MODEL_SPEC Part II) — resolve BOTH the record's
        // district and the subject's birthplace to registration-district ids and
        // compare by IDENTITY: Hognaston resolves to Ashbourne-RD, so a Bakewell/
        // Basford birth is a different event while an Ashbourne birth is NOT —
        // the discrimination the exclusivity gate asks for, taken from the
        // subject's own birthplace. Falls back to the loose substring guard when
        // either side can't be resolved (ADR-004: no behaviour change for
        // unresolved places).
        if let recDistrict = birth.district?.trimmingCharacters(in: .whitespaces), !recDistrict.isEmpty,
           let subjectPlace = subject.birthLocation?.trimmingCharacters(in: .whitespaces), !subjectPlace.isEmpty {
            let chapman = subjectChapman(subject)
            if let recRD = registrationDistrictID(for: recDistrict, chapman: chapman, year: recordYear),
               let subjRD = registrationDistrictID(for: subjectPlace, chapman: chapman, year: confirmedYear) {
                return recRD != subjRD   // resolved: different RD → conflict; same RD → not
            }
            if !districtsCompatible(recDistrict, subjectPlace) { return true }
        }
        return false
    }

    /// The subject's county Chapman code. Delegates to the shared
    /// `RegistrationDistrictResolver` (extracted in Slice C so the review and
    /// apply layers resolve districts identically).
    private nonisolated static func subjectChapman(_ subject: Profile) -> String? {
        RegistrationDistrictResolver.chapman(forProfile: subject)
    }

    /// Resolve a place-or-district string to its registration-district
    /// `PlaceAuthority` id. Delegates to the shared resolver; nil when
    /// unresolvable — the caller then falls back to substring matching.
    private nonisolated static func registrationDistrictID(
        for placeOrDistrict: String, chapman: String?, year: Int?
    ) -> String? {
        RegistrationDistrictResolver.districtID(forPlaceOrDistrict: placeOrDistrict, chapman: chapman, year: year)
    }

    /// Loose place match (fallback for unresolved places): a bare registration
    /// district ("Chesterfield") against a fuller stored place ("Chesterfield,
    /// Derbyshire") — compatible when the leading tokens match or either string
    /// contains the other's. Deliberately permissive so only a clearly-different
    /// district (Basford vs Chesterfield) trips the guard.
    private nonisolated static func districtsCompatible(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased(), nb = b.lowercased()
        func leadToken(_ s: String) -> String {
            (s.split(separator: ",").first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
        }
        let ta = leadToken(na), tb = leadToken(nb)
        return ta == tb || na.contains(tb) || nb.contains(ta)
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
        // Fix B.3 (DECISION_CORE_PAIR_SPEC) — a geography softFail that means
        // "we don't KNOW where this is" (unknown district / no location
        // data) does not demote a record whose familyContext gate scored a
        // genuine match: family evidence outranks missing geo data. A WRONG
        // place (non-local, foreign, catchment mismatch) still demotes.
        let familyConfirmed = gates.contains { $0.gate == .familyContext && $0.outcome == .pass }
        let hasSoftFails = gates.contains { gate in
            guard gate.outcome == .softFail else { return false }
            if gate.gate == .geography && familyConfirmed
                && (gate.reason.hasPrefix("unknown district") || gate.reason == "no location data") {
                return false
            }
            return true
        }

        // #CPC-Change4 — bounded cross-profile elevation
        // (CROSS_PROFILE_CORROBORATION_SPEC Decision 10; RESEARCH_PIPELINE
        // §4.2 amendment). Applies only when a reciprocal-tier,
        // STRONG-anchor cross-profile annotation identifies this marriage
        // via a tree-linked spouse's persisted record, every other gate is
        // a clean pass, and the sole blocker is insufficient SUBJECT
        // information (the nil-window date fail, or the thin-subject cap
        // below). Contradiction-shaped failures are never overridden —
        // date `.impossible` short-circuited long before this point. The
        // annotation derives exclusively from persisted evidence rows
        // (`CrossProfileAnnotator`), so the elevation is reproduced
        // deterministically on every run.
        let crossProfileElevates = crossProfileElevationApplies(
            record: record, subject: subject, gates: gates, hasSoftFails: hasSoftFails)

        let baseVerdict: RecordVerdict
        if failed.isEmpty && !hasSoftFails {
            baseVerdict = .fact
        } else if failed.isEmpty && hasSoftFails {
            baseVerdict = .lead
        } else if failed.contains(.name) {
            baseVerdict = .impossible
        } else if failed.contains(.geography) {
            baseVerdict = subject.mode == .all ? .lead : .impossible
        } else if failed.count == 1 && failed.contains(.date) && crossProfileElevates {
            baseVerdict = .fact
        } else {
            baseVerdict = .lead
        }

        // Thin-subject verdict cap (ENGINE_FOUNDATION_SPEC #Change1).
        // When the subject has no given name (or a 25+-year birth-year
        // window), the gates can't meaningfully discriminate — a passing
        // record is one of many surname-sharers. Refuse to assert .fact;
        // demote to .lead so convergence (or placeholder write-back per
        // #Change2) decides. Hard fails (.impossible) flow through.
        // #CPC-Change4 exemption: a reciprocal-tier strong-anchor
        // cross-profile corroboration is exactly the external
        // discrimination the thin cap exists to demand — the tree-linked
        // spouse's own record singles this marriage out of the
        // surname-sharer cohort — so it lifts the cap (the ENGINE_
        // FOUNDATION #Change1 contract as amended by CPC Change 4).
        let verdict: RecordVerdict
        if baseVerdict == .fact && InformationDensity.from(subject: subject) == .thin
            && !crossProfileElevates {
            verdict = .lead
        } else {
            verdict = baseVerdict
        }

        return ScoredRecord(
            id: record.id, record: record, verdict: verdict,
            gates: gates, summary: summarise(record: record, searchType: searchType)
        )
    }

    // MARK: - #CPC-Change4 elevation predicate

    /// The date gate's insufficient-INFORMATION fail reason — shared by the
    /// nil-subject-window and no-record-year guards, and matched by
    /// identity in the elevation predicate so a genuine date MISMATCH
    /// (different reason string) can never be mistaken for mere absence of
    /// information. Pinned by `CrossProfileElevationTests`.
    static let insufficientDateInfoReason = "insufficient date information"

    /// Decision 10's bounding conditions, exactly enumerated. True only
    /// when: the record carries a RECIPROCAL-tier, STRONG-anchor
    /// cross-profile annotation (stamped by `CrossProfileAnnotator` from a
    /// tree-linked spouse's persisted evidence — tier/anchor vocabulary
    /// documented on `MarriageRecord`); name, geography, and family gates
    /// are all clean passes with zero softFails anywhere; and the date
    /// gate either passed (the thin-cap-exemption case) or failed
    /// SPECIFICALLY with the insufficient-information reason. Everything
    /// else — softFails, mismatch fails, `.impossible` (short-circuited
    /// upstream), absent gates — refuses.
    private static func crossProfileElevationApplies(
        record: SourceRecord, subject: ResearchSubject,
        gates: [GateResult], hasSoftFails: Bool
    ) -> Bool {
        guard !hasSoftFails,
              case .marriage(let m) = record,
              m.corroboratingSpouseProfileID != nil,
              m.corroborationTier == "reciprocal",
              m.corroborationAnchor == "strong",
              let marriageYear = m.marriageYear
        else { return false }
        // Defence-in-depth: the date gate's nil-window guard fires BEFORE
        // its own death check, so an "insufficient information" fail can
        // mask a marriage-after-death contradiction on a birth-windowless
        // subject. The corroborator's guard ladder refuses such pairs from
        // profile data, but the scorer must be sound on its OWN inputs
        // (deterministic sandwich) — re-check here, margin 0 (marriages
        // are indexed in the ceremony's quarter).
        if let death = subject.deathYearTo ?? subject.deathYearFrom,
           marriageYear > death {
            return false
        }
        guard gates.first(where: { $0.gate == .name })?.outcome == .pass,
              gates.first(where: { $0.gate == .geography })?.outcome == .pass,
              gates.first(where: { $0.gate == .familyContext })?.outcome == .pass
        else { return false }
        guard let dateGate = gates.first(where: { $0.gate == .date }) else { return false }
        if dateGate.outcome == .pass { return true }
        return dateGate.outcome == .fail && dateGate.reason == insufficientDateInfoReason
    }

    // MARK: - Cross-record exclusivity pass (DECISION_CORE_PAIR_SPEC Fix A)

    /// The slot a record occupies among facts a person can hold at most once.
    /// nil = the record type carries no exclusivity semantics.
    static func exclusivitySlot(for record: SourceRecord) -> String? {
        switch record {
        case .birth: return "birth"
        case .death: return "death"
        case .burial: return "burial"
        case .probate: return "probate"
        case .census(let c): return "census-\(c.censusYear)"
        case .marriage: return "marriage"   // non-singular — remarriage is legitimate
        case .parish(let p):
            // Parish events join the slot of the life event they attest.
            let kind = (p.detail?.event).map { "\($0)" } ?? (p.eventType ?? "").lowercased()
            if kind.contains("bapt") || kind.contains("christen") { return "birth" }
            if kind.contains("marriage") { return "marriage" }
            if kind.contains("burial") { return "death" }
            return nil
        default: return nil
        }
    }

    /// The GRO registration identity of a BMD index row — same registration
    /// (vol + page + year + district) across different index rows means the
    /// SAME candidate, not a rival. nil when the record carries no vol/page.
    static func registrationKey(for record: SourceRecord) -> String? {
        func key(_ prefix: String, _ vol: String?, _ page: String?, _ year: Int?, _ district: String?) -> String? {
            guard let vol, let page, !vol.isEmpty, !page.isEmpty else { return nil }
            return "\(prefix)|\(vol.lowercased())|\(page.lowercased())|\(year.map(String.init) ?? "")|\((district ?? "").lowercased())"
        }
        switch record {
        case .birth(let r): return key("b", r.volume, r.page, r.birthYear, r.district)
        case .death(let r): return key("d", r.volume, r.page, r.deathYear, r.district)
        case .marriage(let r): return key("m", r.volume, r.page, r.marriageYear, r.district)
        default: return nil
        }
    }

    /// The deterministic discriminator: a NON-VACUOUS familyContext pass
    /// (child/spouse/parent/maiden-name actually matched — `.skip` and
    /// `.softFail` never count). Cross-profile elevation is subsumed: its
    /// predicate requires a familyContext pass.
    static func isDiscriminated(_ record: ScoredRecord) -> Bool {
        record.gates.contains { $0.gate == .familyContext && $0.outcome == .pass }
    }

    /// A GHOST rival: a stored lead this pass itself previously demoted (the
    /// persisted `.exclusivity` softFail is the marker). Its presence proves
    /// the slot is contested even when the caches keep the other rivals out
    /// of the batch — without ghosts, demoting all rivals EMPTIES the slot
    /// and the next lone re-fetch re-promotes as "unrivalled", flip-flopping
    /// forever. Ghosts block undiscriminated newcomers but are never
    /// re-promoted (leads never resurrect) and never demoted further.
    static func isExclusivityGhost(_ record: ScoredRecord) -> Bool {
        record.verdict == .lead
            && record.gates.contains { $0.gate == .exclusivity && $0.outcome == .softFail }
    }

    /// `fact` must mean "confident this is THEM". Gates are per-record, so a
    /// namesake-dense name can put eleven mutually exclusive birth
    /// registrations through as eleven `facts`. This pass runs over an
    /// assembled batch and demotes competing facts:
    ///   • singular slots: >1 candidate with exactly one discriminated → the
    ///     rest demote; zero or two-plus discriminated → ALL demote (a
    ///     namesake pile, or a genuine contradiction — human judgement).
    ///   • marriage (non-singular): discriminated facts always keep; an
    ///     undiscriminated fact keeps only when it is the ONLY candidate.
    /// `ghosts` (stored exclusivity-demoted leads) count as rival candidates
    /// but can neither keep fact nor demote further. Verdicts only ever move
    /// DOWN (fact → lead); `.lead`/`.impossible` inputs are untouched; the
    /// pass is idempotent. No AI input anywhere.
    /// `appliedIDs` — records whose content the user has ALREADY put on the
    /// tree. They are exempt from demotion and count as discriminated.
    ///
    /// A human decision outranks an automated inference; that is the sandwich's
    /// own ordering, not a new policy. Without it, evidence that only becomes
    /// visible later can silently take an applied fact away. The live case:
    /// making the geography gate able to read parish records (2026-08-21) let
    /// six speculative FreeREG "William Holmes" baptisms across Derbyshire
    /// reach `.fact` — they had been stuck at `lead` only because a blind gate
    /// soft-failed them — whereupon they contested the birth slot and demoted
    /// `freebmd_birth_7b_747_69678088`, the applied 7b/747 Bakewell 1882
    /// registration the owner had confirmed against the GRO image. The
    /// contradiction is still REPORTED (`ContradictoryFactsAudit` deliberately
    /// asks for the unexempted view and shows applied rows as held back); what
    /// this stops is the demotion happening TO the user rather than BY them.
    static func applyExclusivity(
        _ scored: [ScoredRecord], ghosts: [ScoredRecord] = [],
        appliedIDs: Set<String> = []
    ) -> [ScoredRecord] {
        var factIndicesBySlot: [String: [Int]] = [:]
        for (index, record) in scored.enumerated() where record.verdict == .fact {
            if let slot = exclusivitySlot(for: record.record) {
                factIndicesBySlot[slot, default: []].append(index)
            }
        }
        var ghostsBySlot: [String: [ScoredRecord]] = [:]
        for ghost in ghosts where isExclusivityGhost(ghost) {
            if let slot = exclusivitySlot(for: ghost.record) {
                ghostsBySlot[slot, default: []].append(ghost)
            }
        }

        var demotions: [Int: String] = [:]
        for (slot, indices) in factIndicesBySlot {
            // Registration-identity grouping: the same GRO registration often
            // exists as several index rows (different row ids, identical
            // vol/page/year). Twins are ONE candidate, never rivals — without
            // this, a correct death fact demotes against its own twin.
            var candidates: [String: [Int]] = [:]
            for index in indices {
                let key = Self.registrationKey(for: scored[index].record) ?? "id:\(scored[index].id)"
                candidates[key, default: []].append(index)
            }
            // Ghost candidates join under the same identity rules — a ghost
            // sharing a registration with a live row merges into that
            // candidate rather than phantom-rivalling it.
            var ghostKeys: Set<String> = []
            var discriminatedGhostKeys: Set<String> = []
            let liveKeys = Set(candidates.keys)
            for ghost in ghostsBySlot[slot] ?? [] {
                let key = Self.registrationKey(for: ghost.record) ?? "id:\(ghost.id)"
                // A ghost twin of a live row is the SAME candidate — it adds
                // no rival, but its stored discrimination still counts (a
                // candidate is discriminated if ANY of its rows is).
                if !liveKeys.contains(key) { ghostKeys.insert(key) }
                if isDiscriminated(ghost) { discriminatedGhostKeys.insert(key) }
            }
            let allKeys = liveKeys.union(ghostKeys)
            guard allKeys.count > 1 else { continue }   // one candidate → no rivalry

            // An applied row discriminates its own candidate: the user picking
            // it out of the cohort is stronger evidence than any family match
            // the scorer can compute. Without this a lone applied fact against
            // six undiscriminated rivals lands in the "none discriminated"
            // branch, which demotes the whole slot.
            let discriminatedLiveKeys = Set(candidates.filter { _, rows in
                rows.contains { isDiscriminated(scored[$0]) || appliedIDs.contains(scored[$0].id) }
            }.map(\.key))
            let discriminatedKeys = discriminatedLiveKeys.union(discriminatedGhostKeys)

            // Demotion only ever lands on live rows — ghost keys have no
            // entry in `candidates`, so demoting them is a natural no-op.
            // An APPLIED row is skipped: the user already decided, and taking
            // it back silently is the harm this pass must not cause.
            func demote(_ keys: some Collection<String>, _ reason: String) {
                for key in keys {
                    for index in candidates[key] ?? []
                    where !appliedIDs.contains(scored[index].id) {
                        demotions[index] = reason
                    }
                }
            }
            let undiscriminatedKeys = allKeys.subtracting(discriminatedKeys)

            if slot == "marriage" {
                // Multiple marriages are legitimate — but only corroborated
                // ones may coexist as facts.
                demote(undiscriminatedKeys, "\(allKeys.count) marriage candidates and this one carries no family corroboration — demoted for review")
            } else if discriminatedKeys.count == 1 {
                demote(undiscriminatedKeys, "\(allKeys.count) competing \(slot) candidates — a family-corroborated record outranks this one")
            } else if discriminatedKeys.isEmpty {
                demote(allKeys, "\(allKeys.count) competing \(slot) candidates, none discriminated — a person holds at most one; needs family or cross-profile corroboration")
            } else {
                demote(allKeys, "\(allKeys.count) competing \(slot) candidates with \(discriminatedKeys.count) corroborated — a genuine evidential contradiction; review required")
            }
        }

        guard !demotions.isEmpty else { return scored }
        return scored.enumerated().map { index, record in
            guard let reason = demotions[index] else { return record }
            var gates = record.gates
            gates.append(GateResult(gate: .exclusivity, outcome: .softFail, reason: reason))
            return ScoredRecord(
                id: record.id, record: record.record, verdict: .lead,
                gates: gates, summary: record.summary)
        }
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

            // Accept EVERY married surname she may have died under, not just
            // the latest (DS-18). A twice-married woman's death/burial/probate/
            // military/census record can carry any of them, and we rarely know
            // which — the death-shape probe already fans out across all of them,
            // so the name gate must accept all of them too or it rejects the
            // very records that probe surfaced.
            let acceptsMarried: Bool = switch record.recordType {
            case .death, .burial, .probate, .military, .census: true
            default: false
            }
            // TEMPORAL BOUND (owner dogfood — worst-class scorer defect, silently
            // fuses two women): a married surname is only valid for a record
            // dated at/after the subject's first marriage. Before it she was
            // under her maiden name, so a same-married-surname record that
            // predates the marriage is a namesake — an 1891 census "Mary E
            // HOLMES" (born Holmes) must not match a subject who became Holmes by
            // a 1915 marriage. Applied ONLY when both the marriage year and the
            // record year are known; either unknown → no bound (never drops a
            // legitimate record for want of a date).
            let marriedAxisAllowed: Bool = {
                guard acceptsMarried else { return false }
                guard let marriedFrom = subject.marriedSurnameEffectiveFrom,
                      let recordYear = extractYear(from: record) else { return true }
                return recordYear >= marriedFrom
            }()
            if marriedAxisAllowed {
                var marriedCandidates = subject.marriedSurnames
                if let single = subject.marriedSurname { marriedCandidates.append(single) }
                for raw in marriedCandidates {
                    let married = raw.uppercased().trimmingCharacters(in: .whitespaces)
                    if !married.isEmpty, married != personSurname, !set.contains(married) {
                        set.append(married)
                    }
                }
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
            // CO-PRINCIPAL RESCUE. A parish MARRIAGE row names both parties,
            // and the parser titles the record after the FIRST — usually the
            // groom — keeping the other(s) in rawFields["co_persons"]
            // "for the scorer". The scorer never read it: a bride searching
            // her own marriage failed the name gate on her own record.
            //
            // Owner dogfood 2026-08-23: Mary Stevenson's re-research fetched
            // "Youlgreave Parish Register, marriage of Jacob HOLMES, 1846" —
            // the keystone record that names BOTH her father and Jacob's —
            // because FreeREG matched HER as the bride, and the gate scored
            // it name:FAIL → .impossible against the groom's name.
            //
            // Always a softFail, never a pass: identity via the second-listed
            // principal is real evidence but deserves a human's eye.
            if case .parish(let parish) = record,
               let coPersons = parish.common.rawFields["co_persons"] {
                for person in coPersons.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    let tokens = person.uppercased().split(separator: " ").map(String.init)
                    guard tokens.count >= 2, let coSurname = tokens.last else { continue }
                    let coGiven = tokens.dropLast().joined(separator: " ")
                    let coSurnameScore = acceptableSurnames
                        .map { ScoringRules.nameSimilarity(coSurname, $0) }
                        .max() ?? 0
                    guard coSurnameScore >= 0.7 else { continue }
                    let coGivenOK = personGiven.isEmpty
                        || ScoringRules.nameSimilarity(coGiven, personGiven) >= 0.7
                        || coGiven.split(separator: " ").first.map({ ScoringRules.nameSimilarity(String($0), personGiven) >= 0.7 }) == true
                    guard coGivenOK else { continue }
                    return GateResult(gate: .name, outcome: .softFail, reason: String(
                        format: "subject matches the record's co-principal \"%@\" (surname=%.2f) — the row is titled after the other party; review",
                        person, coSurnameScore))
                }
            }
            let candidates = acceptableSurnames.joined(separator: "/")
            return GateResult(gate: .name, outcome: .fail, reason: "surname mismatch: \(recordSurname) vs \(candidates)")
        }
        let surnameScore = bestSurnameScore
        // DS-16: a surname that matches only weakly — containment (Harris/
        // Harrison, Wood/Woodward → 0.80), an equal-length single-char diff
        // (Dale/Gale → 0.70) or an unequal-length transcription variant
        // (Brookes/Brooks → 0.70) — is ambiguous between a true spelling
        // variant and a distinct family that co-occurs in the same district.
        // Only a strong match (exact 1.0, AU/OU normalisation 0.95, or a
        // user-learned equivalence 0.90) is fact-grade. A weak surname makes
        // the whole name gate soft-fail so the record lands as a reviewable
        // .lead rather than auto-promoting to .fact — this both stops the
        // Harris/Harrison false positive AND recovers the Brookes/Brooks
        // variant that used to hard-fail to .impossible (DS-06).
        let surnameStrong = surnameScore >= 0.9

        // T1-06 (score side) — initials-indexed casualties. WWI CWGC rows
        // frequently have Forename empty and Initials "E V"; `givenName`
        // is nil and `common.name` collapses to the bare surname, so the
        // generic fallback below would compare SURNAME vs given name and
        // hard-fail with a nonsense audit reason ("given name mismatch:
        // CAULDWELL vs ERNEST"). Compare the parsed initials against the
        // subject's given/middle initials instead. Extra record initials
        // beyond the subject's known names don't fail (subject data may
        // be incomplete); a contradiction on any compared position does.
        if case .military = record,
           (record.givenName ?? "").isEmpty,
           !personGiven.isEmpty {
            let initials = (record.rawFields["initials"] ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !initials.isEmpty else {
                return GateResult(gate: .name, outcome: .fail, reason: "no forename or initials in military record to compare")
            }
            if initialsConsistent(recordInitials: initials, given: personGiven, middle: personMiddle) {
                return GateResult(gate: .name, outcome: .pass, reason: String(format: "surname=%.2f, initials %@ consistent with %@", surnameScore, initials, personGiven))
            }
            let subjectNames = [personGiven, personMiddle].filter { !$0.isEmpty }.joined(separator: " ")
            return GateResult(gate: .name, outcome: .fail, reason: "initials mismatch: \(initials) vs \(subjectNames)")
        }

        var givenScore = 0.5
        if !recordGiven.isEmpty && !personGiven.isEmpty {
            // Compare against just the first token of the record's given-name
            // field so a record like "JENNIFER M HOLMES" (surname split off
            // already, leaving "JENNIFER M") still matches subject given name
            // "JENNIFER" without being penalised by the middle initial.
            let recordFirstGiven = recordGiven.split(separator: " ").first.map(String.init) ?? recordGiven
            givenScore = ScoringRules.nameSimilarity(recordFirstGiven, personGiven)
            if givenScore < 0.7 {
                // Rescue a first-token mismatch when the record shares an EXACT
                // birth date (day+month+year) with the subject AND its given
                // tokens are a plausible subset of the subject's full given
                // name — the same person indexed under a middle name they went
                // by. Real case: George Eric Vaughn Cauldwell (b.19 Jul 1915),
                // whose 1986 Derbyshire death FamilySearch indexes as "Vaughan
                // Eric Cauldwell". Same surname + exact DOB + a name that
                // reorders/subsets the subject's is the same person; the guards
                // (exact DOB, per-token resemblance) keep it from matching a
                // differently-named relative who merely shares the surname.
                if exactBirthDateRescuesGivenName(
                    record: record, recordGiven: recordGiven,
                    subjectFullGiven: personGivenRaw, subject: subject
                ) {
                    return GateResult(gate: .name, outcome: .pass, reason: String(
                        format: "surname=%.2f, given '%@' rescued by exact birth-date match",
                        surnameScore, recordGiven))
                }
                // DS-04: the subject may be recorded under the name they went
                // by — their MIDDLE name. When the record's given matches the
                // subject's middle name, it's plausibly the same person
                // indexed differently (a census "Victor Cauldwell" for "Ernest
                // Victor Cauldwell"). Soft-fail to a reviewable .lead rather
                // than the hard .impossible that drops it from every pool — a
                // middle-name match is weaker than a given match and could
                // also fit a differently-named relative, so it wants review.
                if !personMiddle.isEmpty,
                   ScoringRules.nameSimilarity(recordFirstGiven, personMiddle) >= 0.7 {
                    return GateResult(gate: .name, outcome: .softFail, reason: "given '\(recordGiven)' matches subject's middle name '\(personMiddle)' — recorded under middle name, review")
                }
                return GateResult(gate: .name, outcome: .fail, reason: "given name mismatch: \(recordGiven) vs \(personGiven)")
            }
        } else if recordGiven.isEmpty {
            return GateResult(gate: .name, outcome: .fail, reason: "no given name in record to compare")
        } else {
            // recordGiven is present but the SUBJECT has no known given name —
            // e.g. a relative/hypothesis search axis that dispatched on surname
            // alone (`givenName: nil`). We cannot confirm identity on surname
            // alone: a shared surname — especially a MARRIED surname, which a
            // whole family carries — is not identity. A record that carries its
            // own given name we can't check must NOT pass the gate green; it
            // soft-fails to a reviewable lead instead. Without this, a male
            // "Charles H Holmes" 1941 death passed the name gate for a female
            // "Lilian … Holmes" subject purely on surname=1.00 with the given
            // comparison skipped (givenScore stuck at its 0.5 default).
            return GateResult(gate: .name, outcome: .softFail, reason: String(
                format: "surname=%.2f but subject given name unknown — cannot confirm identity on surname alone, review",
                surnameScore))
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

        if !surnameStrong {
            return GateResult(gate: .name, outcome: .softFail, reason: String(format: "surname=%.2f weak (variant or distinct family — review), given=%.2f", surnameScore, givenScore))
        }
        return GateResult(gate: .name, outcome: .pass, reason: String(format: "surname=%.2f, given=%.2f", surnameScore, givenScore))
    }

    /// Extract whatever sits between the first token and the last token of
    /// the record's given-name field. For "JENNIFER M HOLMES" we already
    /// split surname off earlier, leaving recordGiven = "JENNIFER M" (or
    /// "JENNIFER MARGARET"). Return "M" / "MARGARET", or nil when there's
    /// no middle content to compare.
    // Internal (not private): the name-enrichment absorption reuses the
    // same middle-token extraction so the gate and the absorber can never
    // disagree about what counts as middle content.
    static func extractMiddleContent(from recordGiven: String) -> String? {
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
            // A scribal contraction or nickname of the same name is still a
            // match (DS-05): "THOMAS" middle vs "THOS" record middle share
            // the first initial and resolve equal through the similarity
            // ladder, so don't reject them on the prefix test alone.
            if sub.count > 1 && rec.count > 1 && sub != rec
               && !sub.hasPrefix(rec) && !rec.hasPrefix(sub)
               && ScoringRules.nameSimilarity(sub, rec) < 0.7 {
                return false
            }
        }
        return true
    }

    /// T1-06 — compare a military record's initials string ("E V", "E.V.")
    /// against the subject's given/middle initials. The first initial must
    /// match the given name's first letter; subsequent record initials are
    /// compared pairwise against the subject's middle-name initials for as
    /// long as both sides have content (zip semantics — a record with more
    /// initials than the subject has known names passes, mirroring
    /// `middleNameMatches`' incomplete-data tolerance). `given`/`middle`
    /// arrive uppercased from the call site.
    private static func initialsConsistent(recordInitials: String, given: String, middle: String) -> Bool {
        let recordLetters = recordInitials.uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .compactMap(\.first)
        guard let firstRecord = recordLetters.first,
              let firstSubject = given.first else { return false }
        if firstRecord != firstSubject { return false }
        let middleInitials = middle.split(separator: " ").compactMap(\.first)
        for (rec, sub) in zip(recordLetters.dropFirst(), middleInitials) where rec != sub {
            return false
        }
        return true
    }

    /// True when a given-name first-token mismatch should be rescued: the record
    /// shares an EXACT birth date (day+month+year) with the subject AND every
    /// multi-letter token of the record's given name resembles a token of the
    /// subject's full given name (the person indexed under a middle name they
    /// went by). See the call site in `checkName` for rationale.
    private static func exactBirthDateRescuesGivenName(
        record: SourceRecord, recordGiven: String,
        subjectFullGiven: String, subject: ResearchSubject
    ) -> Bool {
        // (1) Exact birth-date match. Both sides must carry a full calendar
        //     date — a year-only subject or record can't produce the strong
        //     DOB identity signal, so we decline rather than guess.
        guard let subjectDOB = fullCalendarDate(subject.birthDateOriginal) else { return false }
        let recordDOBRaw: String? = {
            let keys = record.rawFields.keys
            // Prefer the unambiguous formal date across any Birth-shape fact
            // (Birth, BirthRegistration, …); fall back to the original text.
            if let k = keys.first(where: { $0.hasPrefix("fact.Birth") && $0.hasSuffix(".date.formal") }) {
                return record.rawFields[k]
            }
            if let k = keys.first(where: { $0.hasPrefix("fact.Birth") && $0.hasSuffix(".date") }) {
                return record.rawFields[k]
            }
            return nil
        }()
        guard let recordDOB = fullCalendarDate(recordDOBRaw), recordDOB == subjectDOB else { return false }

        // (2) Per-token name-resemblance guard — the record's given name must be
        //     a plausible subset/reordering of the subject's. Skip bare initials;
        //     every full token must resemble a subject token. Blocks rescuing a
        //     differently-named same-surname relative who merely shares a DOB
        //     (a twin) — vanishingly rare, but the guard makes the rule provably
        //     safe.
        let subjectTokens = subjectFullGiven.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let recordTokens = recordGiven.split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !recordTokens.isEmpty, !subjectTokens.isEmpty else { return false }
        for rt in recordTokens {
            if !subjectTokens.contains(where: { tokenResembles(rt, $0) }) {
                return false
            }
        }
        return true
    }

    /// A record given-name token resembles a subject token — exact, or a close
    /// transcription variant (shared first letter, edit-distance ratio ≥ 0.8).
    /// `ScoringRules.nameSimilarity` is too coarse here — it returns 0 for
    /// VAUGHAN vs VAUGHN (different lengths) — so use a normalised edit distance,
    /// which is what makes George's "VAUGHAN" resemble his "VAUGHN".
    private static func tokenResembles(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.first == b.first else { return false }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return false }
        return 1.0 - Double(levenshtein(a, b)) / Double(maxLen) >= 0.8
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    /// Parse a birth-date string to (year, month, day) when it carries a full
    /// calendar date; nil for year-only or unparseable input. Handles GEDCOM X
    /// formal dates ("+1915-07-19") and free text ("19 Jul 1915", "13 July 1917").
    static func fullCalendarDate(_ raw: String?) -> (year: Int, month: Int, day: Int)? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        // Formal: [+]YYYY-MM-DD (GEDCOM X). Leading "-" is BC and unsupported.
        if let r = s.range(of: #"^[+-]?\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let body = s[r].hasPrefix("+") ? String(s[r].dropFirst()) : String(s[r])
            let parts = body.split(separator: "-").map(String.init)
            if parts.count == 3, let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
               (1...12).contains(mo), (1...31).contains(d) {
                return (y, mo, d)
            }
        }
        // Free text: <day> <month-name> <year> in any order.
        var day: Int?, month: Int?, year: Int?
        for token in s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) {
            if let n = Int(token) {
                if n >= 1000 { year = n }
                else if (1...31).contains(n) && day == nil { day = n }
            } else if let mo = monthNumber(token) {
                month = mo
            }
        }
        if let d = day, let mo = month, let y = year { return (y, mo, d) }
        return nil
    }

    private static func monthNumber(_ token: String) -> Int? {
        let key = String(token.lowercased().prefix(3))
        let months: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        return months[key]
    }

    // MARK: - Gate 2: Date

    private static func checkDate(record: SourceRecord, subject: ResearchSubject, searchType: RecordType) -> GateResult {
        guard let birthLow = subject.birthYearFrom else {
            return GateResult(gate: .date, outcome: .fail, reason: insufficientDateInfoReason)
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
            return GateResult(gate: .date, outcome: .fail, reason: insufficientDateInfoReason)
        }

        let deathYear = subject.deathYearFrom

        // Parish records carry their own EVENT kind — a parish MARRIAGE
        // must be date-checked as a marriage and a parish BURIAL as a
        // death-shape record, not against the birth window. Every parish
        // event was previously birth-dated, so the subject's own 1896
        // marriage (age 21) scored impossible while a namesake's infant
        // burial passed (live find 2026-07-30, first FreeREG run).
        // Baptism/christening and unknown parish events stay on the
        // birth window — a baptism year approximates the birth year.
        let effectiveType: RecordType = {
            guard case .parish(let parish) = record else { return searchType }
            let event = parish.eventType?.lowercased() ?? ""
            if event.contains("marria") { return .marriage }
            if event.contains("buri") { return .burial }
            return searchType
        }()

        // Validate against the *low* bound to mirror Python parity — pre-
        // window the engine used birthYearFrom as the single anchor, so
        // `validateRecord` was always called with that value. Keeping
        // parity here means existing IMPOSSIBLE rules (married before
        // birth, died before birth, etc.) still fire.
        let validation = ScoringRules.validateRecord(recordYear: recordYear, birthYear: birthLow, deathYear: deathYear, recordType: effectiveType.rawValue)
        if validation.hasPrefix("impossible") {
            return GateResult(gate: .date, outcome: .impossible, reason: validation)
        }

        let windowLabel = birthLow == birthHigh ? "~\(birthLow)" : "\(birthLow)–\(birthHigh)"

        switch effectiveType {
        case .death, .probate, .burial:
            // Probate/burial records carry a death year too (per
            // `extractYear` they return `deathYear`), so the death-axis
            // logic applies — record year is the death year, not a birth
            // year. Without this branch a 2017 probate record on a 1919-
            // born subject failed the default birth-window check by 98
            // years → impossible. With this branch the same record passes
            // when ageAtDeath is plausible. Spec §22 follow-up.

            // DS-15: the tree's own accepted evidence already places the
            // subject alive AFTER this record's death year → the record is a
            // same-name namesake, not them. `aliveAsOf` is derived from
            // accepted census/residence/occupation life events (never
            // burial/probate). Strictly-earlier only: a death in the same
            // year as the last alive-event is compatible (died later that
            // year), so this fires only when recordYear < aliveAsOf.
            if let aliveAsOf = subject.aliveAsOf, recordYear < aliveAsOf {
                return GateResult(gate: .date, outcome: .impossible, reason: "died \(recordYear) but the subject is recorded alive in \(aliveAsOf) — a same-name namesake, not them")
            }

            // DS-31 death-date exclusivity. A person dies once. When the
            // subject's death date is a CONFIRMED PRECISE calendar date (full
            // day+month+year — not a year-only value or an estimate, where the
            // year itself may still move), a same-name death/burial record
            // concerning a DIFFERENT date is a namesake, not them. Stronger
            // than the ±year window below, which lets a same-name death one
            // year off survive as a lead: for William Holmes (d. 19 Sep 1919,
            // confirmed from GEDCOM) this sweeps the entire CWGC casualty pile
            // — ~twenty same-name William Holmeses across 1914–1918, several
            // inside the ±1 window — and the off-year FreeBMD deaths off Triage
            // as `.impossible` instead of leaving them as leads. Probate is
            // exempt: a grant can lag death by months to years and legitimately
            // post-date the exact death by a year or more.
            if effectiveType != .probate,
               let confirmed = subject.deathDateOriginal.flatMap(Self.fullCalendarDate),
               confirmed.day > 0, confirmed.month > 0,
               let recDeath = recordDeathDate(from: record) {
                let confirmedLabel = subject.deathDateOriginal ?? "\(confirmed.year)"
                if recDeath.day > 0 && recDeath.month > 0 {
                    // Both sides precise: same calendar date (±3 days for
                    // transcription slop) is the same event; anything else is a
                    // different person.
                    let sameEvent = recDeath.year == confirmed.year
                        && recDeath.month == confirmed.month
                        && abs(recDeath.day - confirmed.day) <= 3
                    if !sameEvent {
                        return GateResult(gate: .date, outcome: .impossible, reason: "record's death date differs from the subject's confirmed death \(confirmedLabel) — a person dies once; same-name namesake, not them")
                    }
                } else {
                    // Record is year/quarter-only (e.g. a FreeBMD death index
                    // row). A different year than the confirmed exact death is
                    // a namesake. The one legitimate cross-year case is a
                    // very-late-year death whose GRO registration slips into the
                    // next year's first quarter, so allow year+1 only when the
                    // confirmed death fell in Nov/Dec.
                    let registrationSlipOK = confirmed.month >= 11 && recDeath.year == confirmed.year + 1
                    if recDeath.year != confirmed.year && !registrationSlipOK {
                        return GateResult(gate: .date, outcome: .impossible, reason: "death year \(recDeath.year) ≠ the subject's confirmed death \(confirmedLabel) — a person dies once; same-name namesake, not them")
                    }
                }
            }

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
            // military records use `age` (CWGC's parsed AgeAtDeath —
            // T1-02: `.military` maps to searchType `.death`, so without
            // this arm the branch ran with recordedAge always nil and the
            // gate passed any casualty where [15,100] intersected the
            // window — two same-name casualties aged 19 and 31 in 1918
            // both passed despite fully-disambiguating ages). Burial
            // records typically have no recorded age.
            let recordedAge: Int? = {
                if case .death(let dr) = record { return dr.age }
                if case .probate(let pr) = record { return pr.ageAtDeath }
                if case .military(let mr) = record { return mr.age }
                return nil
            }()

            // A subject with a recorded spouse or children demonstrably reached
            // adulthood/parenthood, so any death that implies they died a child
            // is a same-name namesake, not them. `familyContext` is the tree's
            // own family (not a search hint). (Nora Beresford b.1907, m. Rose,
            // with children → the "Nora Beresford, 1920, age 4" child death is a
            // different person.) `childbearingFloor` = 15.
            let fc = subject.familyContext
            let reachedAdulthood = !(fc?.spouseName ?? "").isEmpty
                || !(fc?.childNames ?? []).isEmpty
            let childbearingFloor = 15
            // (b) Even the OLDEST plausible age at this death year is a child —
            // impossible for someone who married/had children. Also catches the
            // age-less namesake burials (e.g. the "Spital Cemetery, d.1920"
            // twin) that carry no recorded age.
            if reachedAdulthood, ageAtDeathHigh < childbearingFloor {
                return GateResult(gate: .date, outcome: .impossible, reason: "died \(recordYear) at age ≤\(ageAtDeathHigh), but the subject married/had children — a childhood-death namesake, not them")
            }

            if let recordedAge {
                // (b) Recorded childhood death for a subject who was a
                // parent/spouse — impossible regardless of the birth window.
                if reachedAdulthood, recordedAge < childbearingFloor {
                    return GateResult(gate: .date, outcome: .impossible, reason: "died at age \(recordedAge), but the subject married/had children — a childhood-death namesake, not them")
                }
                let matchesAnyAge = (ageAtDeathLow ... ageAtDeathHigh).contains { ScoringRules.yearsMatch(recordedAge, $0, tolerance: 2) }
                if matchesAnyAge {
                    return GateResult(gate: .date, outcome: .pass, reason: "age at death \(recordedAge) consistent with birth \(windowLabel)")
                }
                // (a) A recorded age far outside the plausible range is a
                // different person, not a borderline misreport — escalate
                // .fail → .impossible so it drops out of the leads. Young-side
                // is tight (a child/young age is precise and unmistakable);
                // old-side is lenient (elderly ages are misreported more).
                // EXCEPT military (CWGC) records: same-name casualties are
                // deliberately separated by demoting the age-mismatched one to
                // a reviewable lead (aged 19 vs implied 31), not dropping it.
                let isMilitary: Bool = { if case .military = record { return true }; return false }()
                if !isMilitary, recordedAge < ageAtDeathLow - 5 || recordedAge > ageAtDeathHigh + 12 {
                    return GateResult(gate: .date, outcome: .impossible, reason: "age at death \(recordedAge) impossible for birth \(windowLabel) — a different person")
                }
                return GateResult(gate: .date, outcome: .fail, reason: "age at death \(recordedAge) inconsistent with birth \(windowLabel)")
            }
            // No recorded age — the only remaining signal is that the implied
            // age-at-death sits within the plausible band. That is weak: with
            // neither a recorded age NOR a known death year, essentially any
            // adult death of a same-named person in the district clears it, so
            // auto-promoting to a .fact is over-confident (DS-01). Pass to
            // .fact only when the subject's death year is independently known —
            // the record year was already constrained to that window above, so
            // the band overlap is then genuinely corroborating. Otherwise
            // soft-fail: the record lands as a reviewable .lead, not a fact.
            let rangeOverlapsPlausible = ageAtDeathHigh >= 15 && ageAtDeathLow <= 100
            if rangeOverlapsPlausible {
                let bandReason = "died \(recordYear), age range \(max(15, ageAtDeathLow))–\(min(100, ageAtDeathHigh)) plausible (birth \(windowLabel))"
                // Pass to .fact when the death is independently anchored:
                // either the subject's death year is known (the record year
                // was constrained to it above) OR this is a military casualty
                // — CWGC records carry a verified casualty date and are
                // separated by next-of-kin / unit / initials at the other
                // gates, so DS-01 must not demote them (mirrors the isMilitary
                // arm in the recorded-age branch above). Everything else with
                // neither an age nor a death anchor is too weak for a fact.
                let isMilitary: Bool = { if case .military = record { return true }; return false }()
                if subject.deathYearFrom != nil || isMilitary {
                    return GateResult(gate: .date, outcome: .pass, reason: bandReason)
                }
                return GateResult(gate: .date, outcome: .softFail, reason: bandReason + " — no recorded age or known death year, needs review")
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
            // Census-year exclusivity (owner dogfood). A person is in exactly
            // one place on census night. If the subject already has an APPLIED
            // census for this record's year, a candidate whose household page
            // differs is a namesake at another address — impossible (sibling of
            // the death-once check). Fires only when both the applied census and
            // this candidate carry a household-page URL, so it can prove they
            // differ; otherwise it never bounds.
            if case .census(let cr) = record,
               let applied = subject.appliedCensusIdentitiesByYear[cr.censusYear], !applied.isEmpty,
               let url = cr.common.detailURL?.trimmingCharacters(in: .whitespaces), !url.isEmpty,
               !applied.contains(url) {
                return GateResult(gate: .date, outcome: .impossible, reason: "the subject already has an applied \(cr.censusYear) census at a different address — a person is in one place on census night; same-name namesake, not them")
            }
            if case .census(let cr) = record, let censusBirth = cr.birthYear {
                // Census age misreporting is endemic in 19th-c. enumeration
                // (round numbers, mis-remembered ages, intentional fudges).
                // ±5 is the honest band — previous ±2 was rejecting genuine
                // census matches whose enumerated age was off by 3–4 years.
                let tol = ScoringRules.tolerance(for: .census)
                    + (subject.birthAnchorIsDerived ? ScoringRules.derivedAnchorSlack : 0)
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
            // Per-type tolerance: .birth is ±2 (DS-23 — covers the Q4-
            // birth/Q1-following-year-registration quarter slip AND a
            // census-derived approximate year rounding to a neighbouring
            // year); baptism and christening are loose (±5 — children can be
            // baptised years after birth, adult baptism happens). Subject's
            // date precision is already encoded in the from/to window above.
            let tol = ScoringRules.tolerance(for: searchType)
                + (subject.birthAnchorIsDerived ? ScoringRules.derivedAnchorSlack : 0)
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

    /// Cross-RUN exclusivity (DECISION_CORE_PAIR_SPEC Fix A, cross-run
    /// extension). The in-run pass can only see the current batch — but the
    /// negative/dedup caches mean a rival from an earlier run often is NOT
    /// re-fetched, so a namesake could return as an "unrivalled" fact while
    /// its competitors sit in the evidence store (live specimen: Elizabeth
    /// Shaw's 1891 Ilkeston census re-promoted while Hayfield + Belper were
    /// cache-suppressed). This variant competes the batch against STORED
    /// facts and reports which stored rows must demote too — healing stale
    /// piles incrementally on every subsequent run.
    struct CrossRunExclusivity {
        let batch: [ScoredRecord]
        /// Stored facts (not in the batch) whose verdict changed — the
        /// caller re-persists these (user_status/applied_at preserved by
        /// the upsert).
        let demotedStored: [ScoredRecord]
    }

    /// `storedGhosts` — stored leads previously demoted by this pass (see
    /// `isExclusivityGhost`); they mark their slot as contested so a lone
    /// cache-suppressed namesake cannot re-promote into an emptied slot.
    /// Callers pre-filter out user-discarded rows: a human's "not them" means
    /// the ghost no longer blocks.
    static func applyExclusivityAcrossStore(
        batch: [ScoredRecord], storedFacts: [ScoredRecord],
        storedGhosts: [ScoredRecord] = [],
        appliedIDs: Set<String> = []
    ) -> CrossRunExclusivity {
        let batchIDs = Set(batch.map(\.id))
        let stored = storedFacts.filter { !batchIDs.contains($0.id) }
        let ghosts = storedGhosts.filter { !batchIDs.contains($0.id) }
        let passed = applyExclusivity(              // order-preserving
            batch + stored, ghosts: ghosts, appliedIDs: appliedIDs)
        let newBatch = Array(passed.prefix(batch.count))
        let storedAfter = Array(passed.suffix(stored.count))
        let demotedStored = zip(stored, storedAfter).compactMap { before, after in
            after.verdict != before.verdict ? after : nil
        }
        return CrossRunExclusivity(batch: newBatch, demotedStored: demotedStored)
    }

    // MARK: - Subject research area (DECISION_CORE_PAIR_SPEC Fix B.1)

    /// The subject's accepted counties: the tree's home Chapman code PLUS the
    /// counties of the subject's OWN recorded places (birth region, death
    /// location, burial). A Nottinghamshire-born subject in a Derbyshire-home
    /// tree accepts both — their own home district no longer soft-fails.
    /// Resolution declines are skipped, never guessed; no hardcoded regions.
    static func acceptedChapmanCodes(for subject: ResearchSubject) -> Set<String> {
        var codes: Set<String> = []
        let home = subject.homeChapmanCode.trimmingCharacters(in: .whitespaces).uppercased()
        if !home.isEmpty { codes.insert(home) }
        var placeTexts: [String] = []
        switch subject.region {
        case .county(let text): placeTexts.append(text)
        case .parish(let parish, let county): placeTexts.append(parish); placeTexts.append(county)
        default: break
        }
        if let deathLocation = subject.deathLocation { placeTexts.append(deathLocation) }
        if let burialPlace = subject.burialPlace { placeTexts.append(burialPlace) }
        for text in placeTexts {
            if let code = ChapmanCodeResolver.chapmanCode(forPlaceText: text) {
                codes.insert(code.uppercased())
            }
        }
        if let burialChapman = subject.burialChapmanCode, !burialChapman.isEmpty {
            codes.insert(burialChapman.uppercased())
        }
        return codes
    }

    // MARK: - Gate 3: Geography

    private static func checkGeography(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        // T1-05 — Python's CWGC geography check, ported from
        // agent/scorer.py:227-272. The cemetery is wherever the casualty
        // died (often abroad) and can't be checked against the research
        // region — but the additional_info next-of-kin line ("Son of X
        // and Y, of Turnditch, Derby") IS the real geographic signal.
        // The previous unconditional class-pass let every same-name
        // casualty nationwide through the gate while the discriminating
        // line sat parsed and unread.
        if case .military(let mr) = record {
            return checkMilitaryGeography(mr, subject: subject)
        }

        // DS-11/DS-19: on an International-scope run the user has opted in to
        // foreign records, so an obviously-foreign place soft-fails (→ a
        // reviewable `.lead`) instead of hard-failing (→ `.impossible` in
        // focused modes). Every other run stays Triage-clean.
        func foreignGate(_ label: String, _ value: String) -> GateResult {
            if subject.includeForeignRecords {
                return GateResult(gate: .geography, outcome: .softFail,
                    reason: "\(label): \(String(value.prefix(50))) — outside the UK, surfaced for review (International scope)")
            }
            return GateResult(gate: .geography, outcome: .fail,
                reason: "\(label): \(String(value.prefix(50)))")
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
            return foreignGate("non-UK \(key)", value)
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
            // A parish record reached NEITHER switch until 2026-08-21, so
            // every one of them fell through to "no location data" — 108 of
            // 108 in a replay of the live store, including plainly-local
            // Youlgreave and Dronfield entries. Harmless while it only cost a
            // softFail, but DS-12P (:1930) now passes familyContext on a
            // parish marriage when a party's SURNAME alone matches a known
            // spouse, and Fix B.3 (:181) cancels a geography softFail reading
            // exactly "no location data" once familyContext has passed. The
            // two together promoted a Nottinghamshire marriage to `.fact` for
            // a Derbyshire subject — the gate could not see the county it
            // exists to check.
            //
            // Composed into the COUNTY fallback, not the district switch
            // above: `parish` is a civil/ecclesiastical parish, not a
            // registration district, and feeding it to the district catalogue
            // invites exactly the cross-county collision documented in
            // `ChapmanCodeResolver` ("Middleton" is a Lancashire RD *and* a
            // Derbyshire parish). The fallback already resolves free-text
            // place strings — county match, then parish-catalogue lookup on
            // the leading token — which is what a parish record needs.
            case .parish(let r):
                county = [r.parish, r.county]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
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
                return foreignGate("non-UK location", county)
            }
            // Home-county match. Previously hardcoded `.contains("derby")`,
            // which broke the No-Hardcoded-Regions invariant (DS-17). Derive
            // the county name from the subject's Chapman code and match both
            // directions so the full county ("Derbyshire") and the common
            // census short form / county town ("Derby", "Derbys") both pass,
            // for whichever county the subject actually belongs to.
            // Fix B.1 — every accepted county (home + the subject's own
            // places), not just the tree home.
            for code in Self.acceptedChapmanCodes(for: subject) {
                let acceptedCounty = Self.countyName(forChapman: code)
                guard !acceptedCounty.isEmpty else { continue }
                let place = county.lowercased()
                let accepted = acceptedCounty.lowercased()
                if place.contains(accepted) || (place.count >= 5 && accepted.contains(place)) {
                    return GateResult(gate: .geography, outcome: .pass, reason: acceptedCounty)
                }
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
                for code in Self.acceptedChapmanCodes(for: subject)
                where ScoringRules.isLocalParish(primaryToken, forHomeChapman: code) {
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
                    // Spell it out for a non-expert: a probate registry is where
                    // the GRANT was processed, not where the person lived, and it
                    // covers several counties — so a Manchester grant for a
                    // Derbyshire death is expected, not suspicious (owner asked
                    // "how would I know Manchester is right?", 2026-07-19).
                    let county = Self.countyName(forChapman: subject.homeChapmanCode)
                    let countyLabel = county.isEmpty ? subject.homeChapmanCode : county
                    let registryName = r.registry ?? "This"
                    if catchment.contains(subject.homeChapmanCode.uppercased()) {
                        return GateResult(gate: .geography, outcome: .pass,
                            reason: "\(registryName) probate registry covers \(countyLabel) — the registry is where the grant was processed, not where they lived")
                    }
                    return GateResult(gate: .geography, outcome: .softFail,
                        reason: "the \(registryName) probate registry doesn't cover \(countyLabel) — may be a different person of the same name from another region")
                }
                // Registry unknown — fall back to subject's free-text death
                // location. Less precise than a structured catchment match
                // but useful when the registry is missing or our map
                // doesn't cover it.
                let homeCounty = Self.countyName(forChapman: subject.homeChapmanCode)
                if let dl = subject.deathLocation, !homeCounty.isEmpty {
                    let place = dl.lowercased()
                    let home = homeCounty.lowercased()
                    if place.contains(home) || (place.count >= 5 && home.contains(place)) {
                        return GateResult(gate: .geography, outcome: .pass, reason: "subject's death location \(dl) overlaps Probate UK coverage")
                    }
                }
            }
            return GateResult(gate: .geography, outcome: .softFail, reason: "no location data")
        }

        let districtClean = district.replacingOccurrences(of: " district", with: "").trimmingCharacters(in: .whitespaces)

        // Same foreign-country check on the structured district field —
        // covers sources that put a country name in the district slot
        // rather than the dedicated location field.
        if Self.isObviouslyForeign(districtClean) {
            return foreignGate("non-UK district", districtClean)
        }

        let acceptedCodes = Self.acceptedChapmanCodes(for: subject)

        // Fix B.2 — hierarchy + validity walk FIRST: resolve the district to
        // a PlaceAuthority node and decide by containment (the district's
        // county ∈ the subject's accepted set). Substring/curated fallback
        // only when resolution declines, so unresolvable text keeps today's
        // behaviour exactly.
        if let districtID = PlaceResolver.resolveDistrict(name: districtClean),
           let countyNode = PlaceAuthorityRegistry.shared.places.county(of: districtID) {
            if acceptedCodes.contains(countyNode.id.uppercased()) {
                return GateResult(gate: .geography, outcome: .pass,
                    reason: "\(districtClean) is in \(countyNode.name) — the subject's research area")
            }
            return GateResult(gate: .geography, outcome: .softFail,
                reason: "\(districtClean) is in \(countyNode.name), outside the subject's counties")
        }

        // PARISH TIER. `resolveDistrict` only matches nodes whose kind is
        // `.registrationDistrict` (`PlaceAuthority+Resolution.swift:162`), so a
        // name that is a PARISH — which is what a census prints in its district
        // column — could never resolve, even when the catalogue held it. That is
        // how "Wensley And Snitterton" scored "unknown district" against a
        // catalogue containing it under DBY/Bakewell and DBY/Matlock.
        //
        // Deliberately resolved with `chapman: nil`. Scoping to the subject's
        // own county would let an ambiguous name always find an in-area answer
        // and pass — the gate would be marking its own homework. Instead the
        // parish must land in exactly ONE county to be trusted: an unambiguous
        // out-of-county parish then correctly soft-fails, and a genuinely
        // ambiguous one (bare "Wensley" — DBY via alias, NRY exact) declines to
        // today's behaviour rather than guessing.
        let year = Self.extractYear(from: record)
        let parishDistricts = PlaceAuthorityRegistry.shared.places
            .districts(forParish: districtClean, year: year, chapman: nil)
        if !parishDistricts.isEmpty {
            let counties = Set(parishDistricts.compactMap {
                PlaceAuthorityRegistry.shared.places.county(of: $0.id)?.id.uppercased()
            })
            if counties.count == 1, let countyID = counties.first,
               let countyNode = PlaceAuthorityRegistry.shared.places.place(id: countyID) {
                if acceptedCodes.contains(countyID) {
                    return GateResult(gate: .geography, outcome: .pass,
                        reason: "\(districtClean) is a parish in \(countyNode.name) — the subject's research area")
                }
                return GateResult(gate: .geography, outcome: .softFail,
                    reason: "\(districtClean) is a parish in \(countyNode.name), outside the subject's counties")
            }
        }

        for code in acceptedCodes {
            if ScoringRules.isLocalDistrict(districtClean, forHomeChapman: code) {
                return GateResult(gate: .geography, outcome: .pass, reason: "\(districtClean) is in research area")
            }
        }
        if let nonLocal = ScoringRules.isNonLocal(districtClean, forHomeChapman: subject.homeChapmanCode) {
            return GateResult(gate: .geography, outcome: .softFail, reason: "\(districtClean) is in \(nonLocal), not local")
        }

        return GateResult(gate: .geography, outcome: .softFail, reason: "unknown district: \(districtClean)")
    }

    /// T1-05 — geography gate for CWGC military records, ported faithfully
    /// from Python `_check_geography`'s war-grave special case
    /// (agent/scorer.py:236-273):
    ///
    ///   * PASS when the next-of-kin line mentions the research county
    ///     (full name, or its first five chars so "Derby" in CWGC matches
    ///     "Derbyshire"), a configured district, or the subject's birth
    ///     town (first comma-segment of the birth location, length > 2).
    ///   * A non-empty line mentioning none of them is demoted. Python
    ///     returns "fail" here, and its verdict layer maps a geography
    ///     fail to LEAD (agent/scorer.py:80-88) — never impossible. Swift's
    ///     geography `.fail` maps to `.impossible` in focused modes, so the
    ///     faithful outcome is `.softFail` (→ `.lead`).
    ///   * The class-pass survives ONLY for records with no
    ///     additional_info at all (the cemetery genuinely can't be
    ///     checked — casualties died abroad; same carve-out as commit
    ///     83706f6). Audit-pinned amendment: Python fell through to its
    ///     district checks here, which for CWGC always landed "fail";
    ///     the accepted Swift behaviour keeps the class-pass so a bare
    ///     row isn't demoted for data CWGC never records.
    ///
    /// Geography terms are derived per-subject (RegionConfig districts for
    /// the home Chapman code, county display name via RegionConfig →
    /// UKChapmanCodes, birth town from the subject's region) — no
    /// hardcoded regions. An anchor-less subject (empty chapman, no birth
    /// location) degrades to the demotion path: the line names somewhere,
    /// we can't verify it, so it stays a lead for the user.
    private static func checkMilitaryGeography(_ record: MilitaryRecord, subject: ResearchSubject) -> GateResult {
        let info = (record.additionalInfo ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !info.isEmpty else {
            return GateResult(
                gate: .geography, outcome: .pass,
                reason: "CWGC casualty — no next-of-kin line; UK residence not on record by class invariant"
            )
        }

        let chapman = subject.homeChapmanCode
            .trimmingCharacters(in: .whitespaces)
            .uppercased()

        // County name — full form first, then the first-five-chars short
        // form ("derby" matches "of Turnditch, Derby"). Python parity:
        // scorer.py:252-258.
        let county = countyName(forChapman: chapman).lowercased()
        if !county.isEmpty, info.contains(county) {
            return GateResult(gate: .geography, outcome: .pass, reason: "CWGC next-of-kin mentions \(county)")
        }
        let countyShort = county.count >= 5 ? String(county.prefix(5)) : county
        if !countyShort.isEmpty, info.contains(countyShort) {
            return GateResult(gate: .geography, outcome: .pass, reason: "CWGC next-of-kin mentions \(countyShort)")
        }

        // Configured districts for the home county. Sorted iteration for
        // deterministic pass reasons across Dictionary ordering.
        if !chapman.isEmpty {
            for district in RegionConfig.districts(forChapmanCode: chapman).keys.sorted() {
                let needle = district.trimmingCharacters(in: .whitespaces).lowercased()
                if !needle.isEmpty, info.contains(needle) {
                    return GateResult(gate: .geography, outcome: .pass, reason: "CWGC next-of-kin mentions \(district)")
                }
            }
        }

        // Subject's birth town — the segment before the first comma of
        // the free-text birth location ("Turnditch, Derbyshire, England"
        // → "turnditch"). Python parity: scorer.py:264-270.
        if let birthLocation = birthLocationText(of: subject) {
            let town = birthLocation
                .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if town.count > 2, info.contains(town) {
                return GateResult(gate: .geography, outcome: .pass, reason: "CWGC next-of-kin mentions \(town)")
            }
        }

        // T1-10 feed — the structured next-of-kin residence through the
        // parish catalogue. "of 5 Mill St., Turnditch" doesn't name the
        // county or a district, but Turnditch resolves to a research-area
        // district exactly the way the census parish check does. Pass-only
        // enhancement over the Python containment checks.
        if !chapman.isEmpty,
           let residence = CWGCNextOfKin.parse(record.additionalInfo ?? "")?.residence {
            for segment in residence.split(separator: ",") {
                let place = segment.trimmingCharacters(in: .whitespaces)
                guard place.count > 2 else { continue }
                if ScoringRules.isLocalParish(place, forHomeChapman: chapman) {
                    return GateResult(gate: .geography, outcome: .pass, reason: "CWGC next-of-kin residence \(place) is in a research-area district")
                }
            }
        }

        return GateResult(gate: .geography, outcome: .softFail, reason: "CWGC next-of-kin doesn't mention research area")
    }

    /// Display name of the subject's home county — the Swift analogue of
    /// Python's `config.region.county`. Rich per-county RegionConfig first
    /// (static hand-curated data, no bundle dependency), then the bundled
    /// UKChapmanCodes catalogue for every other county. Empty when the
    /// subject has no chapman anchor — callers skip the county checks and
    /// fall through to district/town matching. Internal (not private):
    /// `SearchDispatcher` composes life-event residence places with their
    /// derived county name so soft place axes never lose county context.
    static func countyName(forChapman code: String) -> String {
        guard !code.isEmpty else { return "" }
        if let config = RegionConfig.config(forChapmanCode: code) {
            return config.county
        }
        return UKChapmanCodes.shared.codes.first { $0.code == code }?.name ?? ""
    }

    /// Free-text birth location carried on the subject's region
    /// (`ResearchSubject.fromProfile` maps `profile.birthLocation` into
    /// `.county(text)`; manual input does the same).
    private static func birthLocationText(of subject: ResearchSubject) -> String? {
        switch subject.region {
        case .county(let text): return text
        case .parish(let parish, let county): return "\(parish), \(county)"
        default: return nil
        }
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
        // DS-11 — US states and Canadian provinces so a place naming only
        // the sub-national region ("Charleston, South Carolina") is caught
        // without the country. Whole-word matched (see isObviouslyForeign);
        // UK-colliding names are deliberately omitted — "Washington" (Tyne &
        // Wear), "Boston" (Lincs), "Lincoln", "Richmond", "Kent" — to avoid
        // false-flagging a UK place.
        "ontario", "quebec", "nova scotia", "manitoba", "saskatchewan",
        "alberta", "newfoundland", "new brunswick", "british columbia",
        "new york", "new jersey", "new mexico", "new hampshire",
        "north carolina", "south carolina", "north dakota", "south dakota",
        "west virginia", "rhode island", "pennsylvania", "massachusetts",
        "connecticut", "virginia", "maryland", "ohio", "michigan",
        "illinois", "indiana", "wisconsin", "minnesota", "iowa", "missouri",
        "kansas", "nebraska", "oklahoma", "texas", "arizona", "colorado",
        "utah", "nevada", "oregon", "idaho", "montana", "wyoming",
        "tennessee", "kentucky", "alabama", "mississippi", "louisiana",
        "arkansas", "florida", "georgia", "vermont", "delaware", "alaska",
        "hawaii", "california", "maine", "carolina",
    ]

    nonisolated private static func isObviouslyForeign(_ text: String) -> Bool {
        // Pad with separators so short tokens only match as whole words
        // (avoids "usa" matching "kusano"). EVERY non-alphanumeric becomes
        // a separator: the earlier comma/period/slash-only list let
        // quote-wrapped collection titles ('… "United States, Census,
        // 1950"') hide the country token behind a boundary character and
        // a US census cluster reached Confirmed (live find 2026-07-15).
        let lower = " " + String(text.lowercased().map { ch in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }) + " "
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

        // Check census household for known family members.
        if case .census(let census) = record, let household = census.household {
            // Child match FIRST — a child's given name is distinctive, so a
            // matching child is a strong identity signal for the household
            // (unlike a common spouse forename, below).
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

            // Spouse match. DS-02: a common spouse FORENAME (a weak,
            // containment-grade match like "Mary" vs "Mary Cauldwell") can
            // match the wrong household of the same family surname, so it
            // ENDORSES to .fact only on a STRONG match (full given+surname or
            // exact, ≥0.90). A weaker spouse-only match with no corroborating
            // child soft-fails → a reviewable .lead rather than an
            // auto-accepted wrong household.
            if let spouseName = context.spouseName {
                let bestSpouse = household
                    .filter { let r = $0.relationship.lowercased(); return r.contains("wife") || r.contains("husband") }
                    .map { ScoringRules.nameSimilarity($0.name.uppercased(), spouseName.uppercased()) }
                    .max() ?? 0
                if bestSpouse >= 0.9 {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse \(spouseName) found in household")
                }
                if bestSpouse >= 0.7 {
                    return GateResult(gate: .familyContext, outcome: .softFail, reason: "only a weak spouse-name match for \(spouseName) in household — a common forename can match the wrong family; review")
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

            // #CPC-Change3 — cross-profile corroboration arm. Fires only
            // when no earlier arm claimed the record (spouse column absent
            // or unmatched): the pipeline's annotation step stamped this
            // record because a TREE-LINKED SPOUSE's persisted evidence
            // holds the same canonical GRO reference (the annotation
            // derives exclusively from persisted evidence rows — no AI
            // path can produce it, and the corroborator refuses records
            // whose spouse column contradicts the pair, so this arm never
            // masks a DS-12 contradiction). A pass here affects only
            // `wouldApply` in this Change; the Change-4 verdict rule keys
            // on the ANNOTATION (tier + anchor), not on which arm passed.
            if let corroboratingSpouse = marriage.corroboratingSpouseProfileID {
                let tier = marriage.corroborationTier ?? "unknown"
                return GateResult(
                    gate: .familyContext, outcome: .pass,
                    reason: "cross-profile: tree-linked spouse \(corroboratingSpouse) holds the same GRO reference (\(tier) tier)"
                )
            }

            // DS-12: the record names a spouse but it matched neither the
            // known spouse (name or surname) nor the same-page-inferred
            // partner above. A contradicting spouse is the strongest
            // wrong-person signal a marriage can carry — soft-fail rather
            // than fall through to `.skip`, which (being dropped from the
            // verdict) would let the record reach `.fact` with the family
            // gate silently absent. Only fires when the tree actually
            // records a spouse to compare against.
            if let recordSpouse = marriage.spouseName?.trimmingCharacters(in: .whitespaces),
               !recordSpouse.isEmpty,
               (context.spouseName != nil || context.spouseSurname != nil) {
                return GateResult(
                    gate: .familyContext, outcome: .softFail,
                    reason: "marriage names \(recordSpouse), which doesn't match the subject's known spouse"
                )
            }
        }

        // DS-10 — parish/christening parent-name cross-check. FreeREG
        // baptism rows carry the named father/mother (ParishRecord.fatherName
        // / .motherName), but `.parish` records previously fell through to
        // `.skip` — so a namesake-cousin baptism naming CONTRADICTING parents
        // reached `.fact`. Mirror the MMN arm below: compare the record's
        // parent GIVEN name (the surname is usually the shared family surname,
        // so the given is the discriminating token) against the subject's
        // linked parents. Corroborate on a match, soft-fail on a clear
        // contradiction, skip when there's nothing to compare.
        // Event-type guard (FREEREG_INTEGRATION_SPEC §2 / consumer-map
        // hardening 2026-07-29): only a BAPTISM's fatherName/motherName are
        // the SUBJECT's parents. On a marriage they would be the groom's or
        // bride's father (a stranger to a bride-subject); on a burial, the
        // named next-of-kin. The producer (FreeREGSource) now projects flat
        // parents baptism-only, and this guard keeps the gate honest even
        // if another producer regresses.
        //
        // The baptism test matches the PRODUCER's exactly: flat eventType
        // (legacy rows, direct-baptism queries) OR the typed detail's
        // event (an all-types .parish search row can carry a blank type
        // cell while its enriched detail page proves baptism — the gate
        // must still fire there; verify finding 2026-07-29).
        if case .parish(let parish) = record, {
            if let t = parish.eventType?.lowercased(), t.contains("bapt") || t.contains("christen") { return true }
            if case .baptism = parish.detail?.event { return true }
            return false
        }() {
            let father = Self.parentGivenMatch(
                recordName: parish.fatherName,
                knownGiven: context.fatherGivenName, knownFull: context.fatherName)
            let mother = Self.parentGivenMatch(
                recordName: parish.motherName,
                knownGiven: context.motherGivenName, knownFull: context.motherName)
            if father == false || mother == false {
                return GateResult(
                    gate: .familyContext, outcome: .softFail,
                    reason: "parish record names a parent inconsistent with the subject's linked parents — possible namesake baptism")
            }
            if father == true || mother == true {
                return GateResult(
                    gate: .familyContext, outcome: .pass,
                    reason: "parish record parents consistent with the subject's linked parents")
            }
        }

        // DS-12P — parish-MARRIAGE spouse cross-check. The DS-12 arm above
        // keys on `case .marriage`, but FreeREG marriages arrive as `.parish`
        // records (FreeREGSource projects every register row that way), so
        // that arm never sees them: a marriage scored on name + date +
        // geography alone, and any "John WHEELDON" marrying ANY bride in the
        // right decade looked plausible. Owner dogfood 2026-08-17 surfaced 17
        // wrong Derbyshire marriages as leads on one subject — every bride a
        // different woman, none of them his.
        //
        // The other party IS carried, two ways: typed as
        // FreeREGMarriage.groom/.bride on an enriched detail page, else flat
        // in rawFields["co_persons"], which FreeREGSource fills from the
        // results row's <br>-separated principals cell.
        //
        // The subject's OWN side is dropped first. The typed detail carries
        // both groom and bride, one of whom is the subject — and leaving them
        // in lets a wrong record pass on the subject's own surname whenever
        // the tree stores a wife under her MARRIED name (spouseSurname
        // "Wheeldon" would match the groom "John Wheeldon"). Identity is
        // tested on given AND surname together, so a same-surname spouse
        // (Dalbury 1855, John Wheeldon × Mary Wheeldon) is still kept.
        if case .parish(let parish) = record, {
            if let t = parish.eventType?.lowercased(), t.contains("marr") { return true }
            if case .marriage = parish.detail?.event { return true }
            return false
        }() {
            let subjectSurname = (subject.surname ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let subjectGiven = (subject.givenName ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let isSubjectsOwnSide: (String) -> Bool = { party in
                guard !subjectSurname.isEmpty, !subjectGiven.isEmpty else { return false }
                let tokens = party.uppercased().split(separator: " ").map(String.init)
                guard let partySurname = tokens.last, tokens.count > 1 else { return false }
                let partyGiven = tokens.dropLast().joined(separator: " ")
                return ScoringRules.nameSimilarity(partySurname, subjectSurname) >= 0.7
                    && ScoringRules.nameSimilarity(partyGiven, subjectGiven) >= 0.7
            }

            var parties: [String] = []
            if case .marriage(let m)? = parish.detail?.event {
                for person in [m.groom, m.bride] {
                    let full = [person.forename, person.surname]
                        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !full.isEmpty { parties.append(full) }
                }
            }
            if parties.isEmpty, let coPersons = record.rawFields["co_persons"] {
                parties = coPersons.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            parties = parties.filter { !isSubjectsOwnSide($0) }

            let knownFull = context.spouseName?.trimmingCharacters(in: .whitespaces)
            let knownSurname = context.spouseSurname?.trimmingCharacters(in: .whitespaces)
            let haveKnownSpouse = !(knownFull ?? "").isEmpty || !(knownSurname ?? "").isEmpty

            if !parties.isEmpty, haveKnownSpouse {
                for party in parties {
                    let partyUpper = party.uppercased()
                    if let knownFull, !knownFull.isEmpty,
                       ScoringRules.nameSimilarity(partyUpper, knownFull.uppercased()) >= 0.7 {
                        return GateResult(
                            gate: .familyContext, outcome: .pass,
                            reason: "marriage party matches the subject's known spouse: \(party)")
                    }
                    // Surname alone: the register writes the bride under her
                    // MAIDEN name, which is what a correctly-recorded wife
                    // carries in `lastName` — so this is the arm that fires
                    // on a real match, and the reason a wife stored under her
                    // married surname disarms this gate entirely.
                    if let knownSurname, !knownSurname.isEmpty,
                       let partySurname = partyUpper.split(separator: " ").last,
                       ScoringRules.nameSimilarity(String(partySurname), knownSurname.uppercased()) >= 0.7 {
                        return GateResult(
                            gate: .familyContext, outcome: .pass,
                            reason: "marriage party surname matches the subject's known spouse: \(party)")
                    }
                }
                return GateResult(
                    gate: .familyContext, outcome: .softFail,
                    reason: "marriage names \(parties.joined(separator: " and ")), which doesn't match the subject's known spouse")
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

    /// Compare a record's parent name against a known linked parent (DS-10).
    /// Returns `true` when the parent GIVEN names match, `false` when they
    /// clearly contradict, and `nil` when there's nothing to compare (either
    /// side missing). The given is the discriminating token — a baptism's
    /// father surname is normally the shared family surname.
    static func parentGivenMatch(recordName: String?, knownGiven: String?, knownFull: String?) -> Bool? {
        guard let recordName = recordName?.trimmingCharacters(in: .whitespaces), !recordName.isEmpty,
              let recordGiven = recordName.uppercased().split(separator: " ").first.map(String.init)
        else { return nil }
        let known = (knownGiven ?? knownFull?.split(separator: " ").first.map(String.init))?
            .uppercased().trimmingCharacters(in: .whitespaces)
        guard let known, !known.isEmpty else { return nil }
        return ScoringRules.nameSimilarity(recordGiven, known) >= 0.7
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

    /// The record's DEATH date at the finest resolution it carries: full
    /// (year, month, day) when the record has a calendar date string, else
    /// just the death year (month/day = 0). Death-shape records only; returns
    /// nil when the record carries no death year at all (e.g. a burial row with
    /// only a birth year — comparing that to a death date would be nonsense).
    /// Used by the death-date exclusivity rule in `checkDate`.
    static func recordDeathDate(from record: SourceRecord) -> (year: Int, month: Int, day: Int)? {
        func parse(_ raw: String?, fallbackYear: Int?) -> (Int, Int, Int)? {
            if let full = fullCalendarDate(raw) { return (full.year, full.month, full.day) }
            if let y = fallbackYear { return (y, 0, 0) }
            return nil
        }
        switch record {
        case .death(let r): return parse(r.deathDate, fallbackYear: r.deathYear)
        case .burial(let r): return parse(r.deathDate, fallbackYear: r.deathYear)
        case .military(let r): return parse(r.dateOfDeath, fallbackYear: r.deathYear)
        case .probate(let r): return parse(r.deathDate, fallbackYear: r.deathYear)
        case .parish(let r): return parse(r.eventDate, fallbackYear: r.eventYear)
        default: return nil
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
            let yearStr = r.deathYear.map { ", d.\($0)" } ?? ""
            return "\(r.common.name ?? "?"), \(r.cemetery ?? r.burialLocation ?? "")\(yearStr)"
        case .probate(let r):
            return "\(r.common.name ?? "?"), \(r.grantType ?? "probate") \(r.probateDate ?? "")"
        case .parish(let r):
            return "\(r.common.name ?? "?"), \(r.eventType ?? "") \(r.eventYear.map(String.init) ?? "?")"
        case .pedigree(let r):
            return "\(r.common.name ?? "?"), b.\(r.birthYear.map(String.init) ?? "?") \(r.location ?? "")"
        }
    }
}
