import Foundation

/// EVIDENCE_ABSORPTION_SPEC Change 4 — the single declarative enumeration of
/// everything a record absorbs into a profile, each fact routed to its home.
///
/// Before this, the routing lived in three hand-written places that had to be
/// kept in lockstep by hand: `ApplyEngine.applyFactToSubject`'s per-type switch
/// (identity fields + spouse edge), its corroboration tail (implied dates), and
/// `SourceRecord.projectToLifeEvents` (typed events). `absorptionPlan` folds all
/// three into one ordered list so:
///   - the write path (`applyFactToSubject`) *executes* the plan, and
///   - the review preview (Change 5) *displays* the same plan,
/// which is why the two can never drift — the drift bug the firewall/absorption
/// design exists to prevent (see the spec's "Why 4 before 5" note).
///
/// This is a behaviour-preserving refactor: the plan reproduces the exact set
/// and order of writes the old switch+tail produced, so the test suite stays
/// identically green.
enum Absorption {
    /// A date field (`.birthDate` / `.deathDate`) — executed through the
    /// directional overwrite policy (`ApplyEngine.applyDateField`).
    case dateField(ProfileField, GenealogicalDate)
    /// A string field (`.birthLocation` / `.deathLocation`) — executed through
    /// `ApplyEngine.applyStringField`.
    case stringField(ProfileField, String)
    /// A subject-side marriage → spouse-edge fill (the relationship home, with
    /// its own conflict detection).
    case spouseEdge(MarriageRecord)
    /// A typed timeline event (census / occupation / residence / burial / …).
    /// Executed by the caller via `addLifeEventIfAbsent`, not by
    /// `applyFactToSubject`.
    case lifeEvent(LifeEvent)
}

nonisolated extension SourceRecord {

    /// The complete, ordered absorption plan for this record. Order matches the
    /// legacy write sequence exactly: primary identity fields / spouse edge
    /// first, then the implied-date corroboration tail (Change 3), then the
    /// typed life events (Change 2/3 fan-out). Only present values appear —
    /// a nil/empty candidate was a no-op in the old code and is simply omitted
    /// here, which is also what the review preview wants to show.
    func absorptionPlan(profileID: String, profile: Profile? = nil) -> [Absorption] {
        var items: [Absorption] = []

        // 1. Primary identity fields + spouse edge (was the per-type switch).
        switch self {
        case .birth(let r):
            if let date = ApplyEngine.bmdDate(year: r.birthYear, quarter: r.quarter, exact: r.birthDate) {
                items.append(.dateField(.birthDate, date))
            }
            if let loc = nonEmpty(r.birthPlace ?? r.district) {
                items.append(.stringField(.birthLocation, loc))
            }
        case .death(let r):
            if let date = ApplyEngine.bmdDate(year: r.deathYear, quarter: r.quarter, exact: r.deathDate) {
                items.append(.dateField(.deathDate, date))
            }
            if let loc = nonEmpty(r.deathPlace ?? r.district) {
                items.append(.stringField(.deathLocation, loc))
            }
        case .marriage(let m):
            items.append(.spouseEdge(m))
        case .census(let r):
            if let loc = ApplyEngine.censusBirthLocation(r) {
                items.append(.stringField(.birthLocation, loc))
            }
        case .burial, .military, .probate, .parish, .pedigree:
            break  // no primary field write — corroboration below may still fire
        }

        // 1b. Name enrichment (owner case 2026-07-21 — Geoff Bonsall's
        //     marriage record carried "Geoffrey W Bonsall"; the fuller name
        //     evaporated on apply). When the record's given name is a FULLER
        //     FORM of the profile's, absorb it: the fuller first token rides
        //     the string-field policy (a user-authoritative "Geoff" is never
        //     displaced — the record's form lands as a cited alternative;
        //     an import-tier name upgrades outright), and the middle
        //     token(s) gap-fill the middleName. Emitted only when the
        //     PROFILE is in hand — the plan is the single declarative truth
        //     both the write path and the preview walk, so gating happens
        //     here, not in the consumers. Both emissions require the first
        //     tokens to be compatible (equal or fuller) because a
        //     force-applied record may have bypassed the name gate.
        //     Census records are excluded outright: a census given name can
        //     fall back to the household HEAD when no target marker survives
        //     parsing, and is often abbreviated — never treat it as name
        //     evidence. BMD/parish records name the subject directly.
        if let profile, !isCensus {
            let recordGiven = (self.givenName ?? "").trimmingCharacters(in: .whitespaces)
            let profileGiven = (profile.firstName ?? "").trimmingCharacters(in: .whitespaces)
            if !recordGiven.isEmpty {
                let recordFirst = recordGiven.split(separator: " ").first.map(String.init) ?? recordGiven
                if profileGiven.isEmpty {
                    // Blank-fill (owner case 2026-07-24 — Oswald J Derbyshire's
                    // marriage carried his forename, but absorption only
                    // *enriched* an existing given name and never *filled* a
                    // blank one, so applying the record left "Missing
                    // firstName"). The subject had no name at all; an applied
                    // (human- or gate-confirmed) BMD/parish record names them
                    // directly, so gap-fill firstName from the first token and
                    // middleName from the rest. Pure blank-fill — never an
                    // overwrite, so check-before-overwrite is untouched. Census
                    // is already excluded above (its given name can be a
                    // household-head fallback).
                    items.append(.stringField(.firstName, Self.recasedName(recordFirst)))
                    if let middle = RecordScorer.extractMiddleContent(from: recordGiven),
                       (profile.middleName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                        items.append(.stringField(.middleName, Self.recasedName(middle)))
                    }
                } else {
                    let firstTokensCompatible = recordFirst.caseInsensitiveCompare(profileGiven) == .orderedSame
                        || ScoringRules.isFullerGivenForm(record: recordFirst, profile: profileGiven)
                    if firstTokensCompatible {
                        // First name: only an ATTESTED fuller form is emitted —
                        // a raw prefix expansion (JOSEPH→JOSEPHINE) is a rename,
                        // not an enrichment, and would overwrite an import-tier
                        // name outright.
                        if ScoringRules.isAttestedFullerGivenForm(record: recordFirst, profile: profileGiven) {
                            items.append(.stringField(.firstName, Self.recasedName(recordFirst)))
                        }
                        // Middle: gap-fill when empty, otherwise only a STRICT
                        // expansion of the stored value ("W"→"William" upgrades;
                        // a record's initial never degrades a stored full middle).
                        if let middle = RecordScorer.extractMiddleContent(from: recordGiven) {
                            let profileMiddle = (profile.middleName ?? "").trimmingCharacters(in: .whitespaces)
                            if profileMiddle.isEmpty || ScoringRules.isFullerMiddleForm(record: middle, stored: profileMiddle) {
                                items.append(.stringField(.middleName, Self.recasedName(middle)))
                            }
                        }
                    }
                }
            }
        }

        // 2. Implied-date corroboration (Change 3). impliedBirthDate/DeathDate
        //    return nil precisely for the type whose primary case already wrote
        //    that field (.birth / .death), so a field is never written twice.
        if let birth = ApplyEngine.impliedBirthDate(for: self) {
            items.append(.dateField(.birthDate, birth))
        }
        if let death = ApplyEngine.impliedDeathDate(for: self) {
            items.append(.dateField(.deathDate, death))
        }

        // 3. Typed life events (Change 2/3 fan-out + primary event).
        items.append(contentsOf: projectToLifeEvents(profileID: profileID).map(Absorption.lifeEvent))

        return items
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// Re-case uniformly-cased source tokens ("GEOFFREY" → "Geoffrey",
    /// "geoffrey" → "Geoffrey") while passing mixed-case forms through
    /// untouched — bare `.capitalized` would degrade properly-cased
    /// interior capitals (McKenzie → Mckenzie, O'Brien → O'brien).
    /// Internal: record removal re-derives the same emitted values to find
    /// the field_sources rows a name enrichment wrote.
    static func recasedName(_ name: String) -> String {
        name.split(separator: " ").map { token in
            let s = String(token)
            return (s == s.uppercased() || s == s.lowercased()) ? s.capitalized : s
        }.joined(separator: " ")
    }

    /// EVIDENCE_ABSORPTION_SPEC Change 5 — the human-readable list of what this
    /// record will land on the profile, for the review surface ("birth place
    /// Alport, Derbyshire · birth date about 1887–1888 · occupation Colliery
    /// electrician · residence 3 Mill Lane"). Reads the SAME `absorptionPlan`
    /// the write path executes, so a lead's nuggets are visible before accept
    /// and the preview can never promise a fact the write won't land.
    ///
    /// The record's own *primary* timeline event is excluded — the review row
    /// already names the record itself; the preview is about the off-agenda
    /// facts it additionally carries.
    func absorptionPreview(profileID: String, profile: Profile? = nil) -> [String] {
        let primaryEventID = projectToLifeEvent(profileID: profileID)?.id
        let origin = SourceOrigin(identifier: sourceID)
        return absorptionPlan(profileID: profileID, profile: profile).compactMap { item in
            if case .lifeEvent(let event) = item, event.id == primaryEventID { return nil }
            guard var label = item.reviewLabel else { return nil }
            // Honest preview: when the string overwrite policy will KEEP the
            // existing value (occupied + candidate tier doesn't outrank it),
            // say so — "Will add to profile" must not promise an overwrite
            // the tier policy is going to refuse. The record's form still
            // lands as a cited alternative in field_sources.
            if case .stringField(let field, _) = item, let profile,
               !ApplyEngine.shouldOverwriteStringField(
                   existing: ApplyEngine.existingString(field, of: profile),
                   existingSources: profile.sources[field] ?? [],
                   candidateOrigin: origin
               ) {
                label += " (as cited alternative)"
            }
            return label
        }
    }
}

nonisolated extension Absorption {
    /// One-line review label, or nil for items not worth surfacing.
    var reviewLabel: String? {
        switch self {
        case .dateField(let field, let date):
            let what = field == .birthDate ? "birth date" : "death date"
            return "\(what) \(Self.dateLabel(date))"
        case .stringField(let field, let value):
            let what: String
            switch field {
            case .birthLocation: what = "birth place"
            case .deathLocation: what = "death place"
            case .firstName:     what = "given name"
            case .middleName:    what = "middle name"
            default:             what = field.rawValue
            }
            return "\(what) \(value)"
        case .spouseEdge(let marriage):
            if let spouse = (marriage.spouseName ?? marriage.partnerSurnameFromSamePage)?
                .trimmingCharacters(in: .whitespaces), !spouse.isEmpty {
                return "marriage to \(spouse)"
            }
            return "marriage"
        case .lifeEvent(let event):
            switch event.type {
            case .occupation: return event.description.map { "occupation \($0)" }
            case .residence:  return event.location.map { "residence \($0)" }
            default:
                let place = event.location.map { " \($0)" } ?? ""
                return "\(event.type.displayName.lowercased())\(place)"
            }
        }
    }

    /// Compact date phrasing: age-*calculated* dates read as "about YYYY[–YYYY]";
    /// everything else shows its original genealogical string ("Dec 1883").
    private static func dateLabel(_ date: GenealogicalDate) -> String {
        if date.qualifier == .calculated, let earliest = date.earliest, let latest = date.latest {
            return earliest == latest ? "about \(latest)" : "about \(earliest)–\(latest)"
        }
        return date.original
    }
}
