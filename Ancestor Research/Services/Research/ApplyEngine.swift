import Foundation

/// The single record-level commit path: takes a scored record that a human
/// (or a rules-gated automation) has accepted and writes its data onto the
/// tree — directional overwrite policies, provenance, spouse-edge fills.
///
/// Extracted from `ResearchViewModel` (Phase 1 slice 3,
/// the 2026-07 architecture review) so the UI accept path, the run-watcher
/// auto-accept path, and placeholder write-back share ONE implementation
/// instead of three drifting copies — the accept-flow bug class of 2026-05
/// existed precisely because these paths were maintained separately.
///
/// Write failures are collected and returned, not thrown: one failed field
/// write must not abort the remaining fields (pre-existing behaviour), and
/// must never be silent — callers surface every failure to log + UI.
nonisolated struct ApplyEngine {

    /// One failed persistence write during an apply.
    struct WriteFailure {
        let what: String
        let error: any Error
    }

    /// WriteFailure-grade notice for a detected conflict that is NOT a
    /// persistence failure (Conflict layer T-A). Rides the
    /// existing failure channel so callers surface it to log + UI without
    /// a new outcome type — e.g. DS-12's marriage-spouse mismatch, which
    /// previously vanished in a silent `return`.
    struct ConflictNotice: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Record-level apply

    /// Write an accepted record's data onto the subject profile.
    /// BMD types write date/location fields under the overwrite policies;
    /// subject-side marriages fill the matching spouse edge; non-BMD types
    /// are the caller's LifeEvent-projection concern, not field writes.
    static func applyFactToSubject(
        _ scored: ScoredRecord,
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) -> [WriteFailure] {
        var failures: [WriteFailure] = []
        // Applying IS a human saying "this record is this person" — when the
        // spellings differ, that is a confirmed surname variant for this
        // tree. Learned HERE, at the choke point, because wiring it into one
        // ViewModel apply path meant the cluster review, the per-fact apply
        // and the parent-unlock flows all taught nothing (confirmed by the
        // 2026-08-23 adversarial sweep: "the primary apply flows all bypass
        // it").
        AppState.learnSurnameEquivalence(from: scored.record, profile: profile, db: db)
        let origin = SourceOrigin(identifier: scored.record.sourceID)
        // Sourcing-gate fix (2026-07-15): every applied field carries the
        // record's citation on its FieldSource — same renderer the review
        // UI and exports use, so the text matches everywhere.
        let rendered = CitationRenderer.cite(scored.record)
        let citation = Citation(
            title: rendered.short,
            url: rendered.url,
            dateAccessed: rendered.accessedAt,
            notes: rendered.full
        )
        // Evidence absorption Change 4 — walk the record's declarative
        // absorption plan instead of a per-type switch. The plan (identity
        // fields + spouse edge + implied-date corroboration + life events, in
        // the legacy write order) is the single enumeration the review preview
        // also reads, so display and write can't drift. Life events are the
        // caller's `projectToLifeEvents` concern, so they're skipped here.
        //
        // EV21 (owner dogfood 2026-08-26) — `landedSomething` tracks whether
        // this apply actually reached the tree. It exists because a marriage
        // whose spouse edge cannot be resolved writes NOTHING at all (a BMD
        // marriage projects no life event, and usually carries no name
        // enrichment either), yet the row was still stamped `applied_at` below
        // and rendered a green "Applied" badge over zero writes. Note the
        // distinction from a *policy-blocked* apply, which stays stamped: a
        // refused field still writes its alternative fact and its citation, so
        // its plan item counts as a write.
        let plan = scored.record.absorptionPlan(profileID: profile.id, profile: profile)
        var landedSomething = false
        for item in plan {
            switch item {
            case .dateField(let field, let candidate):
                // EV21 follow-up (review M2): count the write OUTCOME, not the
                // plan item. Counting at the call site meant a field whose
                // every persistence attempt threw (locked DB, disk full) still
                // read as landed, and the row was stamped `applied_at` over
                // zero writes — the exact state EV21 is named for.
                if applyDateField(
                    field, existing: existingDate(field, of: profile),
                    existingSources: profile.sources[field] ?? [],
                    candidate: candidate, profileID: profile.id, origin: origin, db: db,
                    citation: citation, failures: &failures
                ) {
                    landedSomething = true
                }
            case .stringField(let field, let candidate):
                if applyStringField(
                    field, existing: existingString(field, of: profile),
                    existingSources: profile.sources[field] ?? [],
                    candidate: candidate, profileID: profile.id, origin: origin, db: db,
                    citation: citation, failures: &failures
                ) {
                    landedSomething = true
                }
            case .spouseEdge(let m):
                // Reports whether an edge was actually resolved AND filled —
                // the one plan item that can silently have nowhere to go.
                if applyMarriageToSubjectSpouseEdge(
                    m, profileID: profile.id, snapshot: snapshot, db: db, failures: &failures) {
                    landedSomething = true
                }
            case .lifeEvent:
                // Executed by the caller via projectToLifeEvents — but it IS a
                // write onto the profile, so it counts: a burial/census record
                // whose whole absorption is its timeline event must still read
                // as applied in the ledger. (Its outcome happens after this
                // call returns, so unlike the field cases it cannot be
                // observed here — review M2.)
                landedSomething = true
            }
        }
        // Slice C (Location model Part II) — populate the structured birth
        // registration district from an applied BMD birth record. Derived
        // metadata, not a cited fact: its provenance is the birth citation the
        // plan already wrote onto birthDate/birthLocation, so it takes no
        // FieldSource (same posture as birthLocationCode). Check-before-overwrite
        // is enforced by the writer — a user-set or earlier-resolved RD wins, and
        // re-applying the same record is a no-op.
        if let rdID = birthRegistrationDistrictID(for: scored.record, profile: profile) {
            try? db.setBirthRegistrationDistrictIfEmpty(profileID: profile.id, district: rdID)
        }
        // v56 — record that the apply ACTION ran for this record (even a
        // fully-blocked apply was a deliberate act; Remove clears it). This
        // is what lets external consumers distinguish applied evidence from
        // merely-scored evidence.
        //
        // EV21 (2026-08-26) narrows "fully-blocked" to "blocked BY THE
        // OVERWRITE POLICY" — which still writes alternative facts and
        // citations, and so still deserves the stamp. An apply whose plan had
        // work to do and landed literally none of it is not an apply, and must
        // not wear the badge `wasApplied` reads: the owner's verified Hannah
        // Hewkin marriage (Jun q 1858, Chesterfield 7b/741) showed a green
        // "Applied" with no marriage date anywhere on the tree. A record with
        // an EMPTY plan (a citation-only manual record with no facts) keeps
        // today's behaviour — nothing was asked of it, so nothing was dropped.
        if plan.isEmpty || landedSomething {
            try? db.markEvidenceApplied(evidenceID: "\(profile.id)|\(scored.id)")
        }
        return failures
    }

    /// The registration-district `PlaceAuthority` id an applied birth record
    /// implies, for `Profile.birthRegistrationDistrict` (Slice C). Only a
    /// `.birth` record carries a GRO *birth* registration district; every other
    /// shape returns nil (a death/marriage/census `district` is a different
    /// event's district, not the birth one). The subject's own birthplace
    /// supplies the Chapman anchor that disambiguates a district name shared
    /// across counties; a nil anchor is tolerated (the resolver still resolves a
    /// nationally-unique name, else declines).
    private static func birthRegistrationDistrictID(for record: SourceRecord, profile: Profile) -> String? {
        guard case .birth(let r) = record,
              let district = r.district?.trimmingCharacters(in: .whitespaces), !district.isEmpty
        else { return nil }
        let chapman = RegistrationDistrictResolver.chapman(forProfile: profile)
        return RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: district, chapman: chapman, year: r.birthYear)
    }

    /// The profile's current value for a plan-emitted date field.
    private static func existingDate(_ field: ProfileField, of profile: Profile) -> GenealogicalDate? {
        switch field {
        case .birthDate: return profile.birthDate
        case .deathDate: return profile.deathDate
        default:         return nil
        }
    }

    /// The profile's current value for a plan-emitted string field.
    /// Internal (not private) because `absorptionPreview` reads it to label
    /// kept-as-alternative items honestly.
    static func existingString(_ field: ProfileField, of profile: Profile) -> String? {
        switch field {
        case .birthLocation: return profile.birthLocation
        case .deathLocation: return profile.deathLocation
        // Name fields (1b name enrichment). Without these cases an OCCUPIED
        // middle/first name would present as nil to the overwrite policy and
        // be silently overwritten — the default-nil trap.
        case .firstName:     return profile.firstName
        case .middleName:    return profile.middleName
        case .lastName:      return profile.lastName
        default:             return nil
        }
    }

    // MARK: - Evidence absorption Change 3 — implied dates

    /// The birth date a record implies, if any, for corroboration. `.birth`
    /// returns nil (its own case writes birthDate directly — no double write);
    /// every other type that carries a birth signal offers it here:
    /// - census: explicit `birthYear`, else derived from `age` at census year
    /// - death / military: derived from `age` at death year
    /// - burial (FindAGrave): explicit `birthDate`, else `birthYear`
    /// - probate: explicit `birthDate`, else derived from `ageAtDeath`
    static func impliedBirthDate(for record: SourceRecord) -> GenealogicalDate? {
        switch record {
        case .birth, .marriage, .pedigree:
            return nil
        case .parish(let r):
            // Parish absorption. A burial's deceased-age and a
            // marriage principal's age each imply a (wide, `.calculated`)
            // birth; a baptism's explicit birth_date is a precise birth.
            // The baptism DATE is never treated as a birth date.
            switch r.detail?.event {
            case .burial(let b):
                guard let age = b.deceased.ageInt,
                      let year = parsedDateOrNil(b.deathDate)?.latest
                        ?? parsedDateOrNil(r.eventDate)?.latest ?? r.eventYear
                else { return nil }
                return birthDateFromAge(age: age, at: year)
            case .baptism(let bap):
                return parsedDateOrNil(bap.birthDate)
            case .marriage(let m):
                let role = m.role(forGiven: r.common.givenName, surname: r.common.surname, gender: nil)
                guard let age = m.principal(as: role).ageInt,
                      let year = parsedDateOrNil(m.marriageDate)?.latest
                        ?? parsedDateOrNil(r.eventDate)?.latest ?? r.eventYear
                else { return nil }
                return birthDateFromAge(age: age, at: year)
            case nil:
                return nil
            }
        case .census(let r):
            if let year = r.birthYear { return yearGranularDate(year) }
            if let age = r.age { return birthDateFromAge(age: age, at: r.censusYear) }
            return nil
        case .death(let r):
            guard let age = r.age, let deathYear = r.deathYear else { return nil }
            return birthDateFromAge(age: age, at: deathYear)
        case .military(let r):
            guard let age = r.age, let deathYear = r.deathYear else { return nil }
            return birthDateFromAge(age: age, at: deathYear)
        case .burial(let r):
            if let parsed = parsedDateOrNil(r.birthDate) { return parsed }
            if let year = r.birthYear { return yearGranularDate(year) }
            return nil
        case .probate(let r):
            if let parsed = parsedDateOrNil(r.birthDate) { return parsed }
            if let age = r.ageAtDeath, let ref = r.deathYear ?? yearOf(r.probateDate) {
                return birthDateFromAge(age: age, at: ref)
            }
            return nil
        }
    }

    /// The death date a record implies, if any, for corroboration. `.death`
    /// returns nil (its own case writes deathDate directly). FindAGrave,
    /// probate, and military records all carry a death date/year that today
    /// reaches no profile field at all.
    static func impliedDeathDate(for record: SourceRecord) -> GenealogicalDate? {
        switch record {
        case .death, .birth, .census, .marriage, .pedigree:
            return nil
        case .parish(let r):
            // Parish absorption — a burial dates a death to within
            // days: prefer the entry's explicit death date, else the burial
            // (event) date/year. Baptism/marriage imply no death.
            guard case .burial(let b)? = r.detail?.event else { return nil }
            return parsedDateOrNil(b.deathDate)
                ?? parsedDateOrNil(r.eventDate)
                ?? r.eventYear.map(yearGranularDate)
        case .burial(let r):
            return parsedDateOrNil(r.deathDate) ?? r.deathYear.map(yearGranularDate)
        case .probate(let r):
            return parsedDateOrNil(r.deathDate) ?? r.deathYear.map(yearGranularDate)
        case .military(let r):
            return parsedDateOrNil(r.dateOfDeath) ?? r.deathYear.map(yearGranularDate)
        }
    }

    /// Birth date *calculated* from an age at a reference year. A person aged
    /// `age` at `referenceYear` was born in `[referenceYear-age-1, referenceYear-age]`
    /// — the birthday may or may not have passed, so it's honestly a two-year
    /// span, qualifier `.calculated`. Its span (1) always exceeds a precise
    /// value's (0), so the directional policy never lets it overwrite one.
    /// Rejects nonsense ages and pre-year-1 results.
    static func birthDateFromAge(age: Int, at referenceYear: Int) -> GenealogicalDate? {
        guard age >= 0, age <= 120 else { return nil }
        let latest = referenceYear - age
        let earliest = latest - 1
        guard earliest > 0 else { return nil }
        return GenealogicalDate(
            original: "calc \(earliest)–\(latest)",
            earliest: earliest, latest: latest,
            isApproximate: true, qualifier: .calculated
        )
    }

    /// A year-granularity date (earliest == latest == year), matching how the
    /// BMD path stores year-only facts.
    private static func yearGranularDate(_ year: Int) -> GenealogicalDate {
        GenealogicalDate(
            original: String(year), earliest: year, latest: year,
            isApproximate: false, qualifier: .yearOnly
        )
    }

    /// Parse a date string, returning nil for empty/unparseable input (so a
    /// blank FindAGrave field never produces a phantom date).
    private static func parsedDateOrNil(_ raw: String?) -> GenealogicalDate? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        let parsed = GenealogicalDate(parsing: trimmed)
        return (parsed.earliest != nil || parsed.latest != nil) ? parsed : nil
    }

    /// Extract a year from a free-text date string (probate reference year
    /// fallback when no explicit deathYear is present).
    private static func yearOf(_ raw: String?) -> Int? {
        parsedDateOrNil(raw)?.latest
    }

    /// Evidence absorption Change 1 — the birthplace a census carries,
    /// composed into an *anchor-able* string. A bare parish ("Alport") does
    /// not derive a Chapman anchor (it isn't a registration district), but
    /// "Alport, Derbyshire" does via `deriveHomeChapmanCode`'s county
    /// extraction — the difference between a subject stranded on anchorless
    /// National search and one whose own records score Confirmed. So when the
    /// census gives a separate birth county, append it unless the place string
    /// already names it. Returns nil when the census has no birthplace at all.
    static func censusBirthLocation(_ r: CensusRecord) -> String? {
        let place = r.birthPlace?.trimmingCharacters(in: .whitespaces)
        let county = r.birthCounty?.trimmingCharacters(in: .whitespaces)
        guard let place, !place.isEmpty else {
            return (county?.isEmpty == false) ? county : nil
        }
        guard let county, !county.isEmpty,
              !place.localizedCaseInsensitiveContains(county) else { return place }
        return "\(place), \(county)"
    }

    /// Apply a subject-side marriage record to the spouse edge between this
    /// subject and the matching spouse profile. Match is by surname (the
    /// `Spouse` field in BMD post-1912 marriage rows carries the spouse's
    /// surname). Marriage data is written only into nil columns via
    /// `fillRelationshipMarriage` — existing values the user typed manually
    /// are never overwritten (`Check Before Overwrite` rule).
    ///
    /// Returns true when an edge was resolved and filled. `applyFactToSubject`
    /// needs that answer before it stamps `applied_at`: this is the one plan
    /// item that can have nowhere at all to write (EV21, 2026-08-26).
    private static func applyMarriageToSubjectSpouseEdge(
        _ m: MarriageRecord,
        profileID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) -> Bool {
        let spouseEdges = snapshot.relationships.filter { rel in
            rel.type == .spouse && (rel.from == profileID || rel.to == profileID)
        }
        let otherEnd: (Relationship) -> String = { $0.from == profileID ? $0.to : $0.from }

        // The three partner signals a marriage record can carry, resolved once
        // up front. Hoisted out of the ladder (EV21, 2026-08-26) because step 3
        // and the failure report both have to know when the record names
        // NOBODY, not just when a named partner failed to match.
        let nonEmptyTrimmed: (String?) -> String? = { s in
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t
        }
        let corroboratedID = nonEmptyTrimmed(m.corroboratingSpouseProfileID)
        let statedSpouse = nonEmptyTrimmed(m.spouseName)
        let inferredSpouse = nonEmptyTrimmed(m.partnerSurnameFromSamePage)

        // Resolve the target spouse edge, most-reliable signal first.
        var edge: Relationship?

        // 1. The same-page / cross-profile machinery identified the exact
        //    partner PROFILE (#CPC `corroboratingSpouseProfileID`). Strongest
        //    link, and the ONLY one that works for a pre-1912 record carrying
        //    NEITHER a spouse column NOR a recovered surname — which is
        //    exactly Ida Louisa Land × George Herbert Brooks, Dec 1911
        //    7b/1397: her record names no spouse at all, so surname matching
        //    had nothing to work with and her accepted marriage never reached
        //    the edge (live-observed 2026-07-26).
        if let corroboratedID {
            edge = spouseEdges.first { otherEnd($0) == corroboratedID }
        }

        // 2. Surname match — post-Sep-1912 rows carry the partner surname in
        //    `spouseName`; pre-1912 rows don't, but the same-page pairing pass
        //    recovers it into `partnerSurnameFromSamePage` (validated against
        //    the tree spouse by the family-context gate). Prefer the stated
        //    column; fall back to the recovered partner.
        var statedSpouseMismatch: String?
        if edge == nil, let recordSpouseRaw = statedSpouse ?? inferredSpouse {
            // BMD spouse field is normally just a surname (post-1912).
            // Defensive split: trailing token of "GIVEN SURNAME".
            let recordSpouseSurname = (recordSpouseRaw.split(separator: " ").last.map(String.init)
                ?? recordSpouseRaw).uppercased()
            edge = spouseEdges.first { rel in
                guard let other = snapshot.profiles[otherEnd(rel)] else { return false }
                // Match against ALL of the spouse's surnames (maiden/married/
                // name-forms), not just lastName — a marriage names the maiden
                // surname, but a wife may be stored under her married surname.
                return ConflictSweep.knownSurnames(of: other).contains(recordSpouseSurname)
            }
            // A same-page INFERENCE that matches no linked spouse is a
            // weaker signal than a stated column (the family-context gate
            // already vetted it) — stay silent, never manufacturing a
            // dispute. Only a STATED column that misses is DS-12.
            if edge == nil && statedSpouse != nil {
                statedSpouseMismatch = recordSpouseSurname
            }
        }

        // Does this record name a partner AT ALL? The GRO marriage index does
        // not print the spouse before the Sep 1912 quarter, so for every
        // pre-1912 entry `spouseName` is nil, `partnerSurnameFromSamePage` is
        // empty unless the same-page pairing pass happened to run, and
        // `corroboratingSpouseProfileID` is nil unless a tree-linked spouse
        // already holds the same registration.
        let recordNamesNoPartner = corroboratedID == nil && statedSpouse == nil && inferredSpouse == nil

        // 3. EV21 (owner dogfood 2026-08-26) — the record names NOBODY, and the
        //    subject has exactly ONE spouse on the tree. There is nothing to
        //    choose between: that is the fill a human makes without hesitation,
        //    and it is the ONLY way a pre-1912 marriage index entry can ever
        //    reach the tree. The DS-12 repair below never covered this leg — it
        //    handles "the record STATES a spouse the tree doesn't know", not
        //    "the record states no spouse at all" — so the guard fell through to
        //    a bare `return`: no write, no failure, no trace. The owner's
        //    verified Hannah Hewkin marriage (Jun q 1858, Chesterfield 7b/741)
        //    applied to a green badge and an empty spouse edge.
        //
        //    With zero or two-plus spouse edges we do NOT guess — "when in
        //    doubt, split": picking the wrong marriage is not something the
        //    user can see, let alone undo. The ambiguity is reported instead.
        if edge == nil, recordNamesNoPartner, spouseEdges.count == 1 {
            edge = spouseEdges.first
        }

        guard let edge else {
            // Conflict layer T-A / Change 1 AC2 — DS-12. A
            // post-1912 record STATING a spouse the tree doesn't know used to
            // silently no-op here: no write, no failure, no trace. It now
            // opens an F4b spouseIdentity dispute AND reports on the outcome
            // channel.
            if let recordSpouseSurname = statedSpouseMismatch {
                let conflict = ConflictDetector.spouseIdentityConflict(
                    marriage: m,
                    recordSpouseSurname: recordSpouseSurname,
                    profileID: profileID,
                    spouseEdges: spouseEdges,
                    snapshot: snapshot,
                    origin: SourceOrigin(identifier: m.common.sourceID)
                )
                let adjudication = DisputeResolver.adjudicate(conflict)
                attempt("Record spouse-identity dispute", into: &failures) {
                    _ = try db.upsertDispute(
                        profileID: profileID, conflict: conflict, adjudication: adjudication
                    )
                }
                failures.append(WriteFailure(
                    what: "Marriage record spouse mismatch",
                    error: ConflictNotice(message: "Marriage record names spouse surname \(recordSpouseSurname), which matches no linked spouse — opened a spouse-identity dispute")
                ))
                return false
            }
            // EV21 (2026-08-26) — every remaining leg used to be the bare
            // `return` above the DS-12 block: no write, no failure, no trace,
            // and the caller stamped the row "Applied" anyway. Each one now
            // names what stopped it, so a marriage that did not land can no
            // longer be mistaken for one that did. No dispute is opened here:
            // a same-page INFERENCE that misses is deliberately not DS-12
            // (see step 2), and "nobody is named" is an ambiguity, not a
            // disagreement between sources.
            let subjectName = snapshot.profiles[profileID]?.displayName ?? "this person"
            let reason: String
            if recordNamesNoPartner {
                reason = spouseEdges.isEmpty
                    ? "The marriage index names no spouse (GRO entries before September 1912 don't print one) and \(subjectName) has no spouse linked on the tree — link the spouse, then apply this record again."
                    : "The marriage index names no spouse (GRO entries before September 1912 don't print one) and \(subjectName) has \(spouseEdges.count) linked spouses — record it on the right marriage rather than guessing which one this is."
            } else {
                let named = statedSpouse ?? inferredSpouse
                    ?? corroboratedID.flatMap { snapshot.profiles[$0]?.displayName }
                    ?? "an unlinked partner"
                reason = "The marriage record's partner (\(named)) matches no spouse linked to \(subjectName), so its date and place were not written."
            }
            failures.append(WriteFailure(
                what: "Record marriage on spouse edge",
                error: ConflictNotice(message: reason)
            ))
            return false
        }

        let dateCandidate = bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)
        let locationCandidate = m.marriagePlace ?? m.district
        // `fillRelationshipMarriage` is a gap-fill, so a re-apply onto an
        // already-populated edge is a legitimate no-op — `filled` records that
        // the write REACHED its target, which is what the applied stamp turns on.
        var filled = false
        attempt("Record marriage on spouse edge", into: &failures) {
            try db.fillRelationshipMarriage(
                relationshipID: edge.id,
                candidateDate: dateCandidate,
                candidateLocation: locationCandidate
            )
            filled = true
        }

        // Married-surname enrichment (owner request 2026-07-21): a marriage
        // record evidences that the female partner is now married under the
        // male partner's surname, so fill her (empty) marriedSurname as part
        // of the same absorption — cited to THIS record, not left for the
        // Tasks one-click. Same UK convention MarriedSurnameFromSpouseRule
        // encodes; GAP-FILL only (never overwrites a recorded married name),
        // and it writes to whichever partner of THIS edge is female (the
        // spouse when a man's record is applied; the subject when a woman's
        // is), so the two apply directions agree.
        enrichMarriedSurnameFromMarriage(
            edge: edge, subjectID: profileID, snapshot: snapshot,
            origin: SourceOrigin(identifier: m.common.sourceID), db: db, failures: &failures)
        return filled
    }

    /// Fill the female partner's married surname from the male partner's, for
    /// the two people joined by `edge`. Gap-fill, cited to the applied
    /// marriage record's source. Shares the audit's convention (female
    /// partner adopts the differently-surnamed partner's surname) so a
    /// research-time write and the Tasks one-click can't disagree.
    private static func enrichMarriedSurnameFromMarriage(
        edge: Relationship, subjectID: String, snapshot: FamilyGraphSnapshot,
        origin: SourceOrigin, db: ProjectDatabase, failures: inout [WriteFailure]
    ) {
        let otherID = edge.from == subjectID ? edge.to : edge.from
        // EV21 (2026-08-26): this was a bare `return`. Both ends of an edge
        // that came out of THIS snapshot must be in the same snapshot — if one
        // isn't, the relationship graph and the profile table disagree and the
        // married-surname half of the absorption was dropped without a word.
        // Narrowed, not deleted: the guard is still right to refuse the write.
        guard let subject = snapshot.profiles[subjectID],
              let other = snapshot.profiles[otherID]
        else {
            failures.append(WriteFailure(
                what: "Fill married surname from marriage",
                error: ConflictNotice(message: "The spouse edge points at a profile that isn't in the loaded tree, so the married-surname enrichment was skipped.")
            ))
            return
        }
        // (recipient, surname-source) both ways — only the female partner
        // with an empty married surname and a differently-surnamed partner
        // is written.
        for (recipient, surnameSource) in [(subject, other), (other, subject)] {
            guard recipient.gender == .female,
                  (recipient.marriedSurname ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let adopted = surnameSource.lastName?.trimmingCharacters(in: .whitespaces),
                  !adopted.isEmpty,
                  adopted.uppercased() != (recipient.lastName ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            else { continue }
            attempt("Fill \(recipient.displayName) married surname", into: &failures) {
                _ = try db.editProfile(
                    profileID: recipient.id,
                    changes: [(.marriedSurname, recipient.marriedSurname, adopted)],
                    dateChanges: [], source: origin)
            }
        }
    }

    /// EV21 (2026-08-26): `candidate` is non-optional. It used to be
    /// `GenealogicalDate?` guarded by a bare `guard let … else { return }` —
    /// an unreportable no-op that could only ever fire on a plan bug, since
    /// `Absorption.dateField` carries a non-optional date. Making the nil case
    /// unrepresentable is better than reporting it.
    ///
    /// EV21 follow-up (review M2): returns whether at least one write reached
    /// the database — same contract as the spouse-edge executor's `filled`,
    /// and what the caller's `landedSomething` (and so the applied stamp)
    /// turns on. A policy-blocked apply still lands its alternative fact,
    /// dispute row and citation, so it still counts — but only when those
    /// writes actually succeed.
    private static func applyDateField(
        _ field: ProfileField,
        existing: GenealogicalDate?,
        existingSources: [FieldSource],
        candidate: GenealogicalDate,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase,
        citation: Citation? = nil,
        failures: inout [WriteFailure]
    ) -> Bool {
        var landed = false
        if shouldOverwriteDateField(existing: existing, candidate: candidate) {
            if attempt("Apply \(field) date", into: &failures, {
                _ = try db.editProfile(profileID: profileID, changes: [], dateChanges: [(field, existing, candidate)], source: origin)
            }) { landed = true }
        } else {
            // Conflict layer T-A — F1 runs before the
            // alternative-fact write. Compatible-but-not-narrower keeps
            // today's behaviour (alternative fact only); an INCOMPATIBLE
            // candidate is preserved as data AND as signal (DS-13 part 3):
            // the same evidence row, plus an open dispute. The write
            // outcome itself is untouched (Change 1 AC5).
            let conflict = ConflictDetector.dateFieldConflict(
                field: field, existing: existing, existingSources: existingSources,
                candidate: candidate, candidateOrigin: origin, profileID: profileID
            )
            var alternativeTx: Transaction?
            if attempt("Record alternative \(field) fact", into: &failures, {
                alternativeTx = try db.recordAlternativeFact(profileID: profileID, field: field, rawValue: candidate.original, source: origin)
            }) { landed = true }
            if let conflict {
                let adjudication = DisputeResolver.adjudicate(conflict)
                if attempt("Record \(field) dispute", into: &failures, {
                    _ = try db.upsertDispute(
                        profileID: profileID, conflict: conflict,
                        adjudication: adjudication, transactionID: alternativeTx?.id
                    )
                }) { landed = true }
                // CL5 — the programme's first write-behaviour change,
                // confined to same-span date conflicts (previously silent
                // first-writer-wins, DS-09). When the R2 quality-dominance
                // ladder resolves FOR THE CANDIDATE, the higher-quality
                // value displaces the field; the displaced value stays in
                // field_sources and the dispute persists as resolved with
                // its full ladder trace. R3 shields user values upstream.
                if case .rule(let ruleID, let accepted)? = adjudication.resolution,
                   accepted.origin.identifier == origin.identifier,
                   accepted.raw == candidate.original {
                    if attempt("Apply \(field) via \(ruleID) quality dominance", into: &failures, {
                        _ = try db.editProfile(profileID: profileID, changes: [], dateChanges: [(field, existing, candidate)], source: origin)
                    }) { landed = true }
                }
            }
        }
        if let citation {
            if attempt("Attach \(field) citation", into: &failures, {
                try db.attachFieldSourceCitation(profileID: profileID, field: field, origin: origin, citation: citation)
            }) { landed = true }
        }
        return landed
    }

    /// EV21 (2026-08-26): `candidate` is non-optional, for the same reason as
    /// `applyDateField` — `Absorption.stringField` carries a non-optional,
    /// already-`nonEmpty`-filtered string, so the old
    /// `guard let trimmed = candidate?…` swallowed nothing a caller could
    /// legitimately produce. The trim stays (a source can pad a value); a
    /// blank surviving it would be a plan defect, so it reports rather than
    /// returning silently.
    ///
    /// EV21 follow-up (review M2): returns whether at least one write reached
    /// the database — see `applyDateField`.
    private static func applyStringField(
        _ field: ProfileField,
        existing: String?,
        existingSources: [FieldSource],
        candidate: String,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase,
        citation: Citation? = nil,
        failures: inout [WriteFailure]
    ) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            failures.append(WriteFailure(
                what: "Apply \(field) value",
                error: ConflictNotice(message: "The record offered a blank \(field) — nothing was written.")
            ))
            return false
        }
        var landed = false
        if shouldOverwriteStringField(field: field, existing: existing,
                                      existingSources: existingSources,
                                      candidate: trimmed, candidateOrigin: origin) {
            if attempt("Apply \(field) value", into: &failures, {
                _ = try db.editProfile(profileID: profileID, changes: [(field, existing, trimmed)], dateChanges: [], source: origin)
            }) { landed = true }
        } else {
            // Conflict layer T-A — F2 mirror of the date hook:
            // a normalised-mismatch candidate still lands as an alternative
            // fact (today's write outcome, AC5) and additionally opens a
            // fieldValue dispute so the losing value stops being buried in
            // field_sources (DS-09's surfacing half / DS-13 part 3).
            //
            // Name-refinement carve-out: when kept and candidate are
            // COMPATIBLE FORMS of one name ("Geoff" vs "Geoffrey", middle
            // "W" vs "William") there is no genuine disagreement — the
            // plan's fuller-form gate certified the pair. A dispute here
            // would be guaranteed noise (R3 refuses auto-resolution on
            // user-authoritative fields, so it stays open forever) and would
            // block auto-approval on the field. The alternative fact
            // below still lands, so the record's form stays cited.
            let conflict = isCompatibleNameForm(field: field, existing: existing, candidate: trimmed)
                ? nil
                : ConflictDetector.stringFieldConflict(
                    field: field, existing: existing, existingSources: existingSources,
                    candidate: trimmed, candidateOrigin: origin, profileID: profileID
                )
            var alternativeTx: Transaction?
            if attempt("Record alternative \(field) fact", into: &failures, {
                alternativeTx = try db.recordAlternativeFact(profileID: profileID, field: field, rawValue: trimmed, source: origin)
            }) { landed = true }
            if let conflict {
                let adjudication = DisputeResolver.adjudicate(conflict)
                if attempt("Record \(field) dispute", into: &failures, {
                    _ = try db.upsertDispute(
                        profileID: profileID, conflict: conflict,
                        adjudication: adjudication, transactionID: alternativeTx?.id
                    )
                }) { landed = true }
            }
        }
        if let citation {
            if attempt("Attach \(field) citation", into: &failures, {
                try db.attachFieldSourceCitation(profileID: profileID, field: field, origin: origin, citation: citation)
            }) { landed = true }
        }
        return landed
    }

    /// EV21 follow-up (review M2): reports whether the write ran clean —
    /// `true` when `op` completed, `false` when its throw was captured as a
    /// WriteFailure — so the field executors can count only writes that
    /// actually landed. Discardable because most call sites (disputes on the
    /// spouse-edge path, ghost upgrades) don't gate anything on the outcome.
    @discardableResult
    private static func attempt(_ what: String, into failures: inout [WriteFailure], _ op: () throws -> Void) -> Bool {
        do { try op(); return true } catch {
            failures.append(WriteFailure(what: what, error: error))
            return false
        }
    }

    // MARK: - Overwrite policies

    /// Should an applied date overwrite the profile's existing value, or only
    /// be logged as an alternative fact?
    ///
    /// The "Check Before Overwrite" rule (`the Check Before Overwrite rule`)
    /// is **directional**: never overwrite *precise* data with *imprecise*
    /// data. The original `existing == nil` guard implemented the rule as
    /// **absolute** — any set value blocks any incoming value — which means a
    /// wide GEDCOM range like `BET 1869 AND 1896` blocks a 31-source
    /// cluster-confirmed `Dec 1883`. Fix: overwrite when the candidate's
    /// year-span is **strictly narrower** than the existing value's.
    ///
    /// Same-span candidates (e.g. two different precise quarters) do not
    /// overwrite — that's a disambiguation problem (the multi-hypothesis
    /// pivot owns it). They still land in `field_sources` via the
    /// `recordAlternativeFact` branch, preserving evidence for later.
    static func shouldOverwriteDateField(
        existing: GenealogicalDate?,
        candidate: GenealogicalDate
    ) -> Bool {
        guard let existing else { return true }
        return yearSpan(of: candidate) < yearSpan(of: existing)
    }

    private static func yearSpan(of date: GenealogicalDate) -> Int {
        guard let earliest = date.earliest, let latest = date.latest else { return .max }
        return latest - earliest
    }

    /// Should an applied string overwrite the profile's existing value, or
    /// only be logged as an alternative fact?
    ///
    /// Strings have no precision axis like dates, so we substitute
    /// provenance via `SourceOrigin.tier`. A higher-tier candidate
    /// overrides a lower-tier existing value:
    ///
    /// - existing nil/empty → write candidate
    /// - existing's highest known tier < candidate's tier → overwrite
    /// - otherwise → keep existing, log candidate as alternative fact
    ///
    /// Defensive default when the existing value is set but `field_sources`
    /// is empty: treat existing as `.userAuthoritative` (don't overwrite).
    /// In normal use every Profile.* write also writes `field_sources`, so
    /// this branch only fires if the audit log is corrupt — better to err
    /// toward preserving the user's data than to silently overwrite.
    ///
    /// Same-tier candidates do not overwrite — that's a disambiguation
    /// problem (multi-hypothesis investigation owns it for cases where two
    /// research sources disagree). They still land in `field_sources` via
    /// `recordAlternativeFact`.
    ///
    /// LOCATION fields additionally carry a precision axis, the way dates do
    /// and other strings don't: a registration district strictly contains the
    /// parish inside it. Tier alone gets this wrong, because the BMD index is
    /// a high-tier source that names the DISTRICT a birth was registered in,
    /// never the town it happened in. So a coarser place is refused however
    /// well-sourced, and lands as an alternative fact instead.
    static func shouldOverwriteStringField(
        field: ProfileField = .firstName,
        existing: String?,
        existingSources: [FieldSource],
        candidate: String = "",
        candidateOrigin: SourceOrigin
    ) -> Bool {
        if (existing ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if field == .birthLocation || field == .deathLocation,
           isCoarserPlace(candidate: candidate, existing: existing) {
            return false
        }
        guard let existingTier = existingSources.map(\.origin.tier).max() else {
            return false
        }
        return candidateOrigin.tier > existingTier
    }

    /// True when `candidate` names a strictly broader place than `existing`
    /// already does — a single bare component against a qualified place that
    /// does not mention it. "Chesterfield" against "Whittington, Derbyshire,
    /// England" is the live case (owner dogfood 2026-08-25: Emma Gladwin's
    /// parish-level birthplace was displaced by her registration district,
    /// cited to a different family's registration).
    ///
    /// Deliberately narrow: it fires only on a bare single component, so a
    /// genuinely more specific two-part place still overwrites normally, and
    /// a candidate the existing value already names ("Chesterfield" against
    /// "Chesterfield, Derbyshire") is not treated as coarser.
    nonisolated static func isCoarserPlace(candidate: String, existing: String?) -> Bool {
        func parts(_ s: String) -> [String] {
            s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let e = parts(existing ?? ""), c = parts(candidate)
        guard c.count == 1, e.count >= 2 else { return false }
        return !e.contains { $0.caseInsensitiveCompare(c[0]) == .orderedSame }
    }

    /// True when an existing name-field value and a refused candidate are
    /// compatible FORMS of the same name rather than a genuine disagreement:
    /// equal after case/whitespace fold, a fuller/shorter pair in either
    /// direction, the same nickname family, or (middles) an initial-vs-full
    /// pair. Drives the F2 carve-out in `applyStringField` — a refinement
    /// never opens a dispute; genuinely different names still do.
    static func isCompatibleNameForm(field: ProfileField, existing: String?, candidate: String) -> Bool {
        guard field == .firstName || field == .middleName else { return false }
        let e = (existing ?? "").trimmingCharacters(in: .whitespaces)
        let c = candidate.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !c.isEmpty else { return false }
        if e.caseInsensitiveCompare(c) == .orderedSame { return true }
        if ScoringRules.isFullerGivenForm(record: c, profile: e)
            || ScoringRules.isFullerGivenForm(record: e, profile: c) { return true }
        if ScoringRules.givenNameVariants(of: e).contains(c.uppercased()) { return true }
        if field == .middleName,
           ScoringRules.isFullerMiddleForm(record: c, stored: e)
            || ScoringRules.isFullerMiddleForm(record: e, stored: c) { return true }
        return false
    }

    // MARK: - BMD dates

    /// Build a `GenealogicalDate` from a BMD record's year + quarter. BMD
    /// quarters are labelled by the END month ("Mar quarter" = Jan–Mar);
    /// year-granularity storage means we keep that nuance in the original
    /// string ("Mar 1976") rather than in earliest/latest.
    static func bmdDate(year: Int?, quarter: String?, exact: String?) -> GenealogicalDate? {
        if let exact = exact?.trimmingCharacters(in: .whitespaces), !exact.isEmpty {
            return GenealogicalDate(parsing: exact)
        }
        guard let year else { return nil }
        if let q = quarter?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            return GenealogicalDate(parsing: "\(q) \(year)")
        }
        return GenealogicalDate(parsing: String(year))
    }

    // MARK: - Proposal-level accept (parent proposals)

    /// Outcome of accepting a parent proposal — callers use it for
    /// bookkeeping (UI decision state, auto-accept promotion counts).
    enum ProposalAcceptOutcome {
        case linkedExisting(String)
        case createdNew
    }

    /// The single parent-proposal accept path: dedup against existing
    /// profiles, link-or-create, and the lossless given-name upgrade.
    /// Shared by the UI accept flow and the run-watcher auto-accept so
    /// the two can never diverge — the watcher previously called
    /// `db.acceptProposedRelative` directly, bypassing dedup, and could
    /// create duplicate ghosts the UI path would have linked.
    ///
    /// The essential link/create write throws; the non-essential
    /// given-name upgrade reports into `failures` instead so its failure
    /// never aborts an otherwise-successful accept.
    ///
    /// `@MainActor` because `ProposalDedup` is main-actor-isolated (project
    /// default isolation); both callers (the ViewModel and the run watcher)
    /// are main-actor anyway.
    @MainActor
    static func acceptParentProposal(
        _ proposal: ProposedRelative,
        subjectID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) throws -> ProposalAcceptOutcome {
        let candidates = Array(snapshot.profiles.values)
        switch ProposalDedup.decide(
            query: ProposalDedup.Query(parentProposal: proposal),
            candidates: candidates
        ) {
        case .matched(let existingID):
            try ensureParentEdge(
                fromExistingProfile: existingID,
                toSubject: subjectID,
                role: parentRole(for: proposal.gender),
                drivingEvidence: proposal.evidence.first,
                in: snapshot,
                db: db
            )
            // Slice 12 — lossless upgrade. The matched existing ghost
            // may have been created by an earlier run (e.g. surname-only
            // before the parent-marriage was findable). Today's proposal
            // carries a recovered given name from the marriage cross-
            // reference. Fill the existing ghost's `first_name` rather
            // than leaving the user with "Land — 1/7" forever. Never
            // overwrite an existing first_name (that would be an
            // identity correction, not an enrichment).
            upgradeGhostFirstNameIfApplicable(
                existingID: existingID,
                proposal: proposal,
                snapshot: snapshot,
                db: db,
                failures: &failures
            )
            openParentRoleDisputeIfOccupied(
                proposal: proposal, subjectID: subjectID,
                acceptedParentID: existingID,
                snapshot: snapshot, db: db, failures: &failures
            )
            return .linkedExisting(existingID)
        case .noMatch, .multipleMatches:
            // multipleMatches still creates new — CLAUDE.md "When
            // in doubt, split". Audit's duplicateDetection rule
            // surfaces the trio for the user to merge manually.
            _ = try db.acceptProposedRelative(proposal)
            openParentRoleDisputeIfOccupied(
                proposal: proposal, subjectID: subjectID,
                acceptedParentID: nil,
                snapshot: snapshot, db: db, failures: &failures
            )
            return .createdNew
        }
    }

    // MARK: - F4a — parent-role conflict on accept (Conflict layer T-A)

    /// Pre-computed warning for the accept UI ( Change 1 AC3): non-nil
    /// when accepting this proposal would put a second biological parent
    /// into an occupied role ("Subject already has a mother: BOWN").
    /// Shares its predicate with the accept-time dispute hook via
    /// `ConflictDetector.occupiedBiologicalRole` so UI and producer can
    /// never disagree. `@MainActor` because dedup is (the same reason the
    /// accept itself is).
    @MainActor
    static func parentRoleConflictWarning(
        for proposal: ProposedRelative,
        subjectID: String,
        snapshot: FamilyGraphSnapshot
    ) -> String? {
        let role = parentRole(for: proposal.gender)
        guard role == .father || role == .mother else { return nil }
        let acceptedParentID: String? = switch ProposalDedup.decide(
            query: ProposalDedup.Query(parentProposal: proposal),
            candidates: Array(snapshot.profiles.values)
        ) {
        case .matched(let id): id
        case .noMatch, .multipleMatches: nil
        }
        guard let occupied = ConflictDetector.occupiedBiologicalRole(
            subjectID: subjectID, role: role,
            excludingParentID: acceptedParentID, snapshot: snapshot
        ) else { return nil }
        return ConflictDetector.parentRoleWarning(role: role, occupant: occupied.occupant)
    }

    /// The accept proceeds (human decided), but DS-26's two-mothers state
    /// can no longer exist invisibly: an F4a `parentRole` dispute opens in
    /// the same breath. Dispute write failures ride the failure channel —
    /// they never abort the accept.
    @MainActor
    private static func openParentRoleDisputeIfOccupied(
        proposal: ProposedRelative,
        subjectID: String,
        acceptedParentID: String?,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) {
        // EV21 audit (2026-08-26): both early returns here are *decisions*, not
        // dropped writes — an unspecified role can't collide, and an unoccupied
        // role has no conflict to open. Nothing is silently skipped, so they
        // stay silent.
        let role = parentRole(for: proposal.gender)
        guard role == .father || role == .mother else { return }
        guard let occupied = ConflictDetector.occupiedBiologicalRole(
            subjectID: subjectID, role: role,
            excludingParentID: acceptedParentID, snapshot: snapshot
        ) else { return }

        let proposedName = [
            proposal.proposedGivenName?.capitalized,
            proposal.proposedSurname,
        ].compactMap { $0 }.joined(separator: " ")
        let origin = SourceOrigin(
            identifier: proposal.evidence.first?.record.sourceID ?? "engine.enrichment"
        )
        let conflict = ConflictDetector.parentRoleConflict(
            subjectID: subjectID,
            role: role,
            occupant: occupied.occupant,
            occupantEdge: occupied.edge,
            proposedParentDescription: proposedName.isEmpty ? "(unnamed)" : proposedName,
            proposedParentOrigin: origin,
            evidenceRecordIDs: proposal.evidence.map { $0.record.id }
        )
        let adjudication = DisputeResolver.adjudicate(conflict)
        attempt("Record parent-role dispute", into: &failures) {
            _ = try db.upsertDispute(
                profileID: subjectID, conflict: conflict, adjudication: adjudication
            )
        }
    }

    /// Add a parent → subject edge using the existing profile, only
    /// when no equivalent edge already exists. Idempotent — repeated
    /// calls do nothing after the first.
    ///
    /// `drivingEvidence` (E4 / Model evolution Change 4): the record that
    /// attests this parent edge — the proposal's first evidence record, the
    /// child's birth record that implied the parent surname. Passed through to
    /// `addRelationshipIfAbsent`, which writes the `existence` provenance row
    /// (and de-dups it on re-run). Nil ⇒ no existence row; forward-only, never
    /// fabricated.
    private static func ensureParentEdge(
        fromExistingProfile parentID: String,
        toSubject subjectID: String,
        role: ParentRole,
        drivingEvidence: ScoredRecord?,
        in snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        // Snapshot-level pre-check avoids the DB round-trip when we
        // already know the edge is there.
        let existingParents = Set(snapshot.parentsOf(subjectID).map(\.id))
        guard !existingParents.contains(parentID) else { return }

        let edge = Relationship(
            id: UUID(),
            from: parentID,
            to: subjectID,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
        let existence: ProjectDatabase.RelationshipExistenceEvidence? =
            drivingEvidence.map { .record($0) }
        _ = try db.addRelationshipIfAbsent(edge, existenceEvidence: existence)
    }

    private static func parentRole(for gender: Gender?) -> ParentRole {
        switch gender {
        case .male:   .father
        case .female: .mother
        default:      .unspecified
        }
    }

    /// Slice 12 — given-name upgrade-on-accept. When the dedup matched
    /// an existing surname-only ghost AND the proposal carries a
    /// recovered given name (from the parent-marriage cross-reference),
    /// fill the ghost's `first_name`.
    private static func upgradeGhostFirstNameIfApplicable(
        existingID: String,
        proposal: ProposedRelative,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) {
        // EV21 (2026-08-26): the two halves of this guard were one bare
        // `return` covering two very different things. "Nothing to upgrade" is
        // a legitimate policy decision and stays silent; "the profile we just
        // matched isn't in the snapshot" is a graph inconsistency that was
        // dropping a recovered given name without a word.
        guard let existing = snapshot.profiles[existingID] else {
            failures.append(WriteFailure(
                what: "Upgrade ghost first name",
                error: ConflictNotice(message: "The matched existing profile isn't in the loaded tree, so the recovered given name wasn't written.")
            ))
            return
        }
        guard let upgrade = firstNameUpgrade(for: proposal, existing: existing) else { return }
        let origin = SourceOrigin(identifier: proposal.evidence.first?.record.sourceID ?? "freebmd")
        attempt("Upgrade ghost first name", into: &failures) {
            try db.editProfile(
                profileID: existingID,
                changes: [(.firstName, nil, upgrade)],
                dateChanges: [],
                source: origin
            )
        }
    }

    /// Slice 12 pure-function gate. Returns the canonical first-name to
    /// write iff the existing ghost has no first_name AND the proposal
    /// carries a non-empty proposedGivenName. Never overwrites an
    /// existing non-empty first_name (that would be an identity
    /// correction, not a recovery). Capitalised for consistency with
    /// the rest of the editProfile pipeline. Static for unit testing.
    static func firstNameUpgrade(
        for proposal: ProposedRelative,
        existing: Profile
    ) -> String? {
        let currentFirstName = (existing.firstName ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard currentFirstName.isEmpty else { return nil }
        guard let proposed = proposal.proposedGivenName?
                .trimmingCharacters(in: .whitespaces),
              !proposed.isEmpty
        else { return nil }
        return proposed.capitalized
    }

    // MARK: - Birth-year candidate

    /// Pure apply: does the actual write through `ProjectDatabase`.
    /// Static + nonisolated so unit tests can exercise it without an
    /// `AppState` harness. Returns void on success; throws on missing
    /// profile / unsuitable hypothesis.
    static func applyBirthYearCandidate(
        _ hypothesis: ResearchHypothesis,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        guard case .birthYearCandidate(let profileID, let year) = hypothesis.kind else {
            throw ApplyBirthYearCandidateError.wrongKind
        }
        guard hypothesis.isDeterministicallySupported else {
            throw ApplyBirthYearCandidateError.notSupported
        }
        guard let profile = snapshot.profiles[profileID] else {
            throw ApplyBirthYearCandidateError.profileMissing(profileID)
        }

        // Prefer an existing precise source attesting to this year — its
        // raw preserves month detail ("Dec 1883" vs bare "1883") and its
        // origin preserves provenance tier.
        let chosen = (profile.sources[.birthDate] ?? []).first { src in
            let parsed = GenealogicalDate(parsing: src.raw)
            guard let e = parsed.earliest, let l = parsed.latest else { return false }
            return e == l && e == year
        }
        // EV9 (2026-08-26): an accept-path FieldSource carries
        // "<value> [<sourceTitle>]" in `raw`. `GenealogicalDate` would still
        // find the year, but `.original` would carry the bracketed title
        // straight onto the profile column. Only the value may reach a column.
        let raw = chosen.map { AppliedFactTarget.parseRaw($0.raw).value } ?? String(year)
        let origin = chosen?.origin ?? .engineEnrichment
        let candidate = GenealogicalDate(parsing: raw)

        _ = try db.editProfile(
            profileID: profile.id,
            changes: [],
            dateChanges: [(.birthDate, profile.birthDate, candidate)],
            source: origin
        )
    }

    /// Errors thrown by `applyBirthYearCandidate`.
    enum ApplyBirthYearCandidateError: Error {
        case wrongKind
        case notSupported
        case profileMissing(String)
    }

    /// CL5 — accept a `.deathYearCandidate`: clones the birth recipe
    /// (prefer the attested FieldSource's raw for month detail), then in
    /// the same user action resolves the linked deathDate dispute
    /// (`.accepted(chosenSource)`) and marks every group rival
    /// `.contradicted` ⟨G5⟩. Reached ONLY from the human Accept click —
    /// hypothesis verdicts propose, they never apply.
    static func applyDeathYearCandidate(
        _ hypothesis: ResearchHypothesis,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        guard case .deathYearCandidate(let profileID, let year) = hypothesis.kind else {
            throw ApplyBirthYearCandidateError.wrongKind
        }
        guard hypothesis.isDeterministicallySupported else {
            throw ApplyBirthYearCandidateError.notSupported
        }
        guard let profile = snapshot.profiles[profileID] else {
            throw ApplyBirthYearCandidateError.profileMissing(profileID)
        }

        let chosen = (profile.sources[.deathDate] ?? []).first { src in
            let parsed = GenealogicalDate(parsing: src.raw)
            guard let e = parsed.earliest, let l = parsed.latest else { return false }
            return e == l && e == year
        }
        // EV9 (2026-08-26): an accept-path FieldSource carries
        // "<value> [<sourceTitle>]" in `raw`. `GenealogicalDate` would still
        // find the year, but `.original` would carry the bracketed title
        // straight onto the profile column. Only the value may reach a column.
        let raw = chosen.map { AppliedFactTarget.parseRaw($0.raw).value } ?? String(year)
        let origin = chosen?.origin ?? .engineEnrichment
        let candidate = GenealogicalDate(parsing: raw)

        _ = try db.editProfile(
            profileID: profile.id,
            changes: [],
            dateChanges: [(.deathDate, profile.deathDate, candidate)],
            source: origin
        )

        // Accepting the candidate IS resolving the conflict: the linked
        // open deathDate dispute (if any) records the user's choice.
        let accepted = chosen ?? FieldSource(origin: origin, raw: raw, addedAt: Date())
        _ = try? db.resolveFieldDispute(
            profileID: profile.id, field: .deathDate,
            resolution: .accepted(accepted))

        // EV35 (2026-08-26) — same hook as `AppState.resolveDispute`: the
        // deathDate is now settled, so the records its openness held back are
        // re-scored. The snapshot is rebuilt first — the one passed in
        // predates both the `editProfile` above and this resolution, so a
        // subject built from it would still read the field as contested.
        // Placed before `contradictRivals` on purpose: that call is `try` and
        // can throw, which would skip the re-score. It writes
        // `research_hypotheses`, not `evidence_records`, so the ordering is
        // otherwise immaterial.
        if let fresh = try? db.buildSnapshot() {
            DisputeRescorer.rescoreAfterResolution(
                profileID: profile.id, field: .deathDate, db: db, snapshot: fresh)
        }

        // Choose-one semantics: every rival in the group is contradicted
        // in the same user action ⟨G5⟩.
        if let groupID = hypothesis.candidateGroupID {
            try db.contradictRivals(inCandidateGroup: groupID, acceptedID: hypothesis.id)
        }
    }
}
