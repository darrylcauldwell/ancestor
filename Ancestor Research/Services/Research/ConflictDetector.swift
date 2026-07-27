import Foundation

/// One typed conflict finding from `ConflictDetector` — the unit the
/// dispute producer persists (CONFLICT_LAYER_SPEC §4.2 / C2).
///
/// Carries everything `DisputeStore.upsertDispute` needs: kind, field key,
/// competing attestations, `DisputeReason`, graded severity, a deterministic
/// reasoning string, and the detecting producer for `detected_by` ⟨G6⟩.
nonisolated struct DetectedConflict: Sendable {
    let kind: DisputeKind
    let profileID: String
    /// Field key persisted in `field_disputes.field`. For `.fieldValue`
    /// kinds this is a `ProfileField.rawValue`; structural kinds use their
    /// own keys (`father`/`mother` for parent roles, `spouse` for spouse
    /// identity) that deliberately do NOT parse as `ProfileField`, so the
    /// snapshot's `[ProfileField: FieldDispute]` map never collides.
    let field: String
    let reason: DisputeReason
    let severity: DiscrepancySeverity
    /// Competing attestations, candidate included. Structural kinds
    /// represent the tree's side with an origin-`tree` entry so the
    /// incumbent is visible in the same list (no silent home advantage).
    let competingSources: [FieldSource]
    /// Non-FieldSource competitors BY REFERENCE (§5): relationship IDs and
    /// record refs for F4a/F4b. Never WitnessKeys (§2.6).
    let evidenceJSON: String?
    let reasoning: String
    let detectedBy: DisputeProducer
    /// CL4 F5 — true when every competing attestation reduces to ONE
    /// witness (transcription variance, not evidential conflict): R0 may
    /// auto-resolve by transcription quality.
    var sameWitness: Bool = false
}

/// CONFLICT_LAYER_SPEC §4.2 — C2, the producer's brain. Pure, nonisolated,
/// fully unit-testable detection rules over profile state + one incoming
/// candidate attestation.
///
/// CL1 ships F1 (date fields), F2 (location/string fields), F4a (parent
/// role), and F4b (spouse identity). F5 needs WitnessIdentity (CL4);
/// F3/T-D ship with the standing sweep (CL2).
///
/// 100% deterministic — no MLX anywhere in this layer (decision log #2).
nonisolated struct ConflictDetector {

    // MARK: - Interim trust-tier derivation (CL1–CL3)

    /// Trust tier for a provenance origin identifier, mirroring each source
    /// plugin's declared `trustTier` (the same values `buildSourceInfoMap`
    /// feeds `DiscrepancySeverityTable` at run time — see
    /// `ResearchPipeline.detectDiscrepancies`). Static because the apply
    /// path has no registry in scope; a parity test pins this table to the
    /// live plugin declarations so the two can never drift. Unknown
    /// identifiers grade `.community` — the registry's own default
    /// direction for unknown provenance.
    /// R2a's originality axis ⟨G7⟩ — mirror of the plugin declarations
    /// (same parity discipline as `trustTier(forOriginIdentifier:)`): CWGC
    /// and Probate publish from their own registers (primary); the
    /// volunteer transcription sites transcribe originals directly;
    /// FindAGrave memorial content is derivative of family knowledge.
    static func evidenceDirectness(forOriginIdentifier identifier: String) -> EvidenceDirectness {
        switch identifier {
        case "cwgc", "probate":
            return .primary
        case "freebmd", "freecen", "freereg", "wirksworth", "familysearch":
            return .directTranscription
        default:
            return .derivative
        }
    }

    static func trustTier(forOriginIdentifier identifier: String) -> SourceTrustTier {
        switch identifier {
        case "freebmd", "freecen", "freereg", "wirksworth", "familysearch":
            return .transcription
        case "cwgc", "probate":
            return .primary
        default:
            return .community
        }
    }

    // MARK: - F1 — date-field conflict (birthDate / deathDate)

    /// How two genealogical year-ranges relate (F1's incompatibility test).
    enum DateRangeRelation: Equatable, Sendable {
        /// Same (earliest, latest) window — one value at year granularity.
        case identical
        /// One range strictly contains the other — a refinement, never a
        /// conflict (R1 restated; matches ApplyEngine's narrower-span rule).
        case containment
        /// Ranges overlap but neither contains the other.
        case partialOverlap
        /// Ranges do not touch; `gap` is the year distance between them.
        case disjoint(gap: Int)
        /// Either side lacks a parseable (earliest, latest) window. A
        /// conflict cannot be *proven*, so none is reported — the
        /// conservative direction (silence here is covered by the wide
        /// range being visibly imprecise, not by a lost contradiction).
        case unknown
    }

    static func relation(_ a: GenealogicalDate, _ b: GenealogicalDate) -> DateRangeRelation {
        guard let aE = a.earliest, let aL = a.latest,
              let bE = b.earliest, let bL = b.latest else { return .unknown }
        if aE == bE && aL == bL { return .identical }
        if (aE <= bE && aL >= bL) || (bE <= aE && bL >= aL) { return .containment }
        if aL < bE { return .disjoint(gap: bE - aL) }
        if bL < aE { return .disjoint(gap: aE - bL) }
        return .partialOverlap
    }

    /// F1 — parse every attested raw via `GenealogicalDate(parsing:)`; the
    /// candidate conflicts with a value when their year-ranges are disjoint
    /// (`.noOverlap`) or overlap only partially with neither containing the
    /// other (`.approximateOverlap`). Strict containment = refinement, not
    /// a conflict (R1). Tested against the existing canonical value AND
    /// every attested `field_sources` value (§4.4 T-A).
    ///
    /// Severity comes from `DiscrepancySeverityTable` with `.singleSource`
    /// convergence — the CL1–CL3 lineage-based interim stated in §4.2; the
    /// witness-counted per-value convergence feed arrives with CL4.
    static func dateFieldConflict(
        field: ProfileField,
        existing: GenealogicalDate?,
        existingSources: [FieldSource],
        candidate: GenealogicalDate,
        candidateOrigin: SourceOrigin,
        profileID: String,
        detectedBy: DisputeProducer = .applyEngine
    ) -> DetectedConflict? {
        // Collect every incompatible attested value (with its source row).
        var competing: [FieldSource] = []
        var sawDisjoint = false
        var maxGap = 0
        var details: [String] = []
        var canonicalRepresented = false

        func note(_ relation: DateRangeRelation, of raw: String) -> Bool {
            switch relation {
            case .disjoint(let gap):
                sawDisjoint = true
                maxGap = max(maxGap, gap)
                details.append("'\(raw)' is disjoint from candidate '\(candidate.original)' (gap \(gap)y)")
                return true
            case .partialOverlap:
                details.append("'\(raw)' only partially overlaps candidate '\(candidate.original)' with neither containing the other")
                return true
            case .identical, .containment, .unknown:
                return false
            }
        }

        let canonicalWindow: (Int, Int)? = existing.flatMap { e in
            guard let lo = e.earliest, let hi = e.latest else { return nil }
            return (lo, hi)
        }

        for source in existingSources {
            let attested = GenealogicalDate(parsing: source.raw)
            guard note(relation(attested, candidate), of: source.raw) else { continue }
            competing.append(source)
            if let (lo, hi) = canonicalWindow,
               attested.earliest == lo, attested.latest == hi {
                canonicalRepresented = true
            }
        }

        // The canonical value itself may be incompatible without any
        // attested row parsing to its window (imports predating the
        // provenance journal). Represent it explicitly so the dispute
        // always shows both sides.
        if let existing, note(relation(existing, candidate), of: existing.original),
           !canonicalRepresented {
            competing.append(FieldSource(
                origin: SourceOrigin(identifier: "tree"),
                raw: existing.original,
                addedAt: Date()
            ))
        }

        guard !competing.isEmpty else { return nil }

        competing.append(FieldSource(
            origin: candidateOrigin,
            raw: candidate.original,
            addedAt: Date()
        ))

        let graded = DiscrepancySeverityTable.severity(
            sourceID: candidateOrigin.identifier,
            sourceTier: trustTier(forOriginIdentifier: candidateOrigin.identifier),
            recordType: nil,
            absDelta: maxGap,
            convergence: .singleSource // CL1–CL3 interim (§4.2): witness-counted per-value convergence lands in CL4.
        )

        let reason: DisputeReason = sawDisjoint ? .noOverlap : .approximateOverlap
        let reasoning = "F1 \(field.rawValue) conflict: "
            + details.joined(separator: "; ")
            + ". \(graded.reasoning)"

        return DetectedConflict(
            kind: .fieldValue,
            profileID: profileID,
            field: field.rawValue,
            reason: reason,
            severity: graded.severity,
            competingSources: competing,
            evidenceJSON: nil,
            reasoning: reasoning,
            detectedBy: detectedBy
        )
    }

    // MARK: - F2 — location/string-field conflict

    /// Collapse a place string for comparison: case, whitespace runs,
    /// comma spacing.
    static func normalisedPlace(_ s: String) -> String {
        s.lowercased()
            .split(separator: ",")
            .map { $0.split(separator: " ").joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Derive a Chapman county code from free place text via the existing
    /// derivation chain (`ResearchSubject.deriveHomeChapmanCode` step 2 —
    /// the registration-district catalogue). Tries the full string, then
    /// each comma component. **No hardcoded regions** — everything comes
    /// from the bundled catalogue.
    static func chapmanCode(forPlaceText text: String) -> String? {
        // Delegates to the single canonical resolver (Stage 1 of the
        // location-model pass) — previously a divergent copy that lacked the
        // county-name fallback ResearchSubject had.
        ChapmanCodeResolver.chapmanCode(forPlaceText: text)
    }

    /// F2 — normalised inequality after collapse (case, whitespace,
    /// trailing county). Severity `.note` unless a county derives for both
    /// sides via the chapman chain and the counties differ → `.conflict`.
    static func stringFieldConflict(
        field: ProfileField,
        existing: String?,
        existingSources: [FieldSource],
        candidate: String,
        candidateOrigin: SourceOrigin,
        profileID: String,
        detectedBy: DisputeProducer = .applyEngine
    ) -> DetectedConflict? {
        guard let existing = existing?.trimmingCharacters(in: .whitespaces),
              !existing.isEmpty else { return nil }
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !candidateTrimmed.isEmpty else { return nil }

        let a = normalisedPlace(existing)
        let b = normalisedPlace(candidateTrimmed)
        guard a != b else { return nil }

        // Trailing-qualifier collapse: "Belper" vs "Belper, Derbyshire" is
        // one value with a trailing county appended, not a conflict.
        let aParts = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let bParts = b.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if aParts == Array(bParts.dropLast()) || bParts == Array(aParts.dropLast()) {
            return nil
        }

        var severity = DiscrepancySeverity.note
        var countyDetail = ""
        if let existingCounty = chapmanCode(forPlaceText: existing),
           let candidateCounty = chapmanCode(forPlaceText: candidateTrimmed) {
            if existingCounty != candidateCounty {
                severity = .conflict
                countyDetail = " Derived counties differ (\(existingCounty) vs \(candidateCounty))."
            } else {
                countyDetail = " Both derive county \(existingCounty)."
            }
        }

        // The existing value's own attestations are the tree's side of the
        // dispute; fall back to an origin-`tree` entry when the audit log
        // carries none.
        var competing = existingSources.filter {
            normalisedPlace($0.raw) == a
        }
        if competing.isEmpty {
            competing.append(FieldSource(
                origin: SourceOrigin(identifier: "tree"),
                raw: existing,
                addedAt: Date()
            ))
        }
        competing.append(FieldSource(
            origin: candidateOrigin,
            raw: candidateTrimmed,
            addedAt: Date()
        ))

        let reasoning = "F2 \(field.rawValue) conflict: '\(existing)' vs '\(candidateTrimmed)' differ after normalisation.\(countyDetail)"

        return DetectedConflict(
            kind: .fieldValue,
            profileID: profileID,
            field: field.rawValue,
            reason: .valueMismatch,
            severity: severity,
            competingSources: competing,
            evidenceJSON: nil,
            reasoning: reasoning,
            detectedBy: detectedBy
        )
    }

    // MARK: - F4a — parent-role conflict (DS-26)

    /// The occupant of a biological parent role, if the role is already
    /// filled by a profile other than `excludingParentID`. Shared predicate
    /// for the accept-time hook and the pre-computed accept-UI warning so
    /// the two can never disagree.
    static func occupiedBiologicalRole(
        subjectID: String,
        role: ParentRole,
        excludingParentID: String?,
        snapshot: FamilyGraphSnapshot
    ) -> (occupant: Profile, edge: Relationship)? {
        guard role == .father || role == .mother else { return nil }
        for edge in snapshot.relationships
        where edge.type == .parent
            && edge.to == subjectID
            && edge.subtype == .biological
            && edge.role == role
            && edge.from != excludingParentID {
            if let occupant = snapshot.profiles[edge.from] {
                return (occupant, edge)
            }
        }
        return nil
    }

    /// Human-readable pre-computed warning for the accept UI (§4.4 T-A):
    /// "Subject already has a mother: BOWN".
    static func parentRoleWarning(
        role: ParentRole,
        occupant: Profile
    ) -> String {
        "Subject already has a \(role.rawValue): \(occupant.displayName)"
    }

    /// F4a — a second biological parent is being accepted into an occupied
    /// role. The accept still proceeds (human decided) but the two-mothers
    /// state can no longer exist invisibly (DS-26).
    static func parentRoleConflict(
        subjectID: String,
        role: ParentRole,
        occupant: Profile,
        occupantEdge: Relationship,
        proposedParentDescription: String,
        proposedParentOrigin: SourceOrigin,
        evidenceRecordIDs: [String],
        detectedBy: DisputeProducer = .applyEngine
    ) -> DetectedConflict {
        // The tree is a witness too ⟨G11⟩ — the incumbent edge enters the
        // competing list with its own provenance, never a silent
        // home-field advantage.
        let competing = [
            FieldSource(
                origin: SourceOrigin(identifier: "tree"),
                raw: "existing \(role.rawValue): \(occupant.displayName)",
                addedAt: Date()
            ),
            FieldSource(
                origin: proposedParentOrigin,
                raw: "accepted \(role.rawValue): \(proposedParentDescription)",
                addedAt: Date()
            ),
        ]
        let evidence: [String: [String]] = [
            "relationshipIDs": [occupantEdge.id.uuidString],
            "recordIDs": evidenceRecordIDs,
        ]
        let evidenceJSON = (try? JSONEncoder().encode(evidence))
            .flatMap { String(data: $0, encoding: .utf8) }
        let reasoning = "F4a parent-role conflict: subject \(subjectID) now has two biological \(role.rawValue)s — '\(occupant.displayName)' (existing edge) and '\(proposedParentDescription)' (accepted proposal). One person has one biological \(role.rawValue) (DS-26)."
        return DetectedConflict(
            kind: .parentRole,
            profileID: subjectID,
            field: role.rawValue,
            reason: .valueMismatch,
            severity: .conflict,
            competingSources: competing,
            evidenceJSON: evidenceJSON,
            reasoning: reasoning,
            detectedBy: detectedBy
        )
    }

    // MARK: - F4b — spouse-identity conflict (DS-12)

    /// F4b — an accepted marriage attestation whose record spouse-surname
    /// matches NO existing spouse edge's surname: the exact predicate that
    /// silently no-opped at `ApplyEngine.applyMarriageToSubjectSpouseEdge`.
    /// Graded `.conflict` when the tree knows at least one spouse (the
    /// record contradicts an accepted identity); `.note` when the tree has
    /// no spouse edge at all (an unmatched assertion, record-spouse ∉ ∅).
    static func spouseIdentityConflict(
        marriage m: MarriageRecord,
        recordSpouseSurname: String,
        profileID: String,
        spouseEdges: [Relationship],
        snapshot: FamilyGraphSnapshot,
        origin: SourceOrigin,
        detectedBy: DisputeProducer = .applyEngine
    ) -> DetectedConflict {
        let knownSpouses: [String] = spouseEdges.compactMap { edge in
            let otherID = edge.from == profileID ? edge.to : edge.from
            return snapshot.profiles[otherID]?.displayName
        }

        let yearLabel = m.marriageYear.map(String.init) ?? "unknown year"
        var competing = [
            FieldSource(
                origin: origin,
                raw: "marriage (\(yearLabel)) names spouse surname \(recordSpouseSurname)",
                addedAt: Date()
            ),
        ]
        if !knownSpouses.isEmpty {
            competing.append(FieldSource(
                origin: SourceOrigin(identifier: "tree"),
                raw: "known spouse(s): \(knownSpouses.joined(separator: ", "))",
                addedAt: Date()
            ))
        }

        let evidence: [String: [String]] = [
            "relationshipIDs": spouseEdges.map { $0.id.uuidString },
            "recordIDs": [m.common.id],
        ]
        let evidenceJSON = (try? JSONEncoder().encode(evidence))
            .flatMap { String(data: $0, encoding: .utf8) }

        let reasoning: String
        let severity: DiscrepancySeverity
        if knownSpouses.isEmpty {
            severity = .note
            reasoning = "F4b spouse-identity: accepted marriage record (\(yearLabel)) names spouse surname \(recordSpouseSurname), but the tree has no spouse edge for this subject to receive it (DS-12 predicate — record-spouse ∉ edge-spouses)."
        } else {
            severity = .conflict
            reasoning = "F4b spouse-identity conflict: accepted marriage record (\(yearLabel)) names spouse surname \(recordSpouseSurname), which matches no linked spouse (known: \(knownSpouses.joined(separator: ", "))). The strongest wrong-person signal a marriage record can carry (DS-12)."
        }

        return DetectedConflict(
            kind: .spouseIdentity,
            profileID: profileID,
            field: "spouse",
            reason: .valueMismatch,
            severity: severity,
            competingSources: competing,
            evidenceJSON: evidenceJSON,
            reasoning: reasoning,
            detectedBy: detectedBy
        )
    }

    // MARK: - F3 — timeline: death vs later-alive evidence (DS-15)

    /// F3 — the profile's death is contradicted by alive-evidence dated
    /// after it. Predicate shared with `RecordAfterDeathRule` via
    /// `ConflictPredicates.aliveEvidence` (CL2 AC2). Symmetric arm: a
    /// burial/probate life event's year contradicted by later sightings.
    /// Order-independent and retroactive — this is the sweep's rule, not
    /// an apply-order artefact (DS-15's exact gap).
    static func deathVsLaterAliveConflict(
        profileID: String,
        deathDate: GenealogicalDate?,
        lifeEvents: [LifeEvent],
        detectedBy: DisputeProducer = .consistencySweep
    ) -> DetectedConflict? {
        // Anchor year: deathDate.latest, else the earliest burial/probate
        // event year (symmetric arm — a burial is death-grade evidence).
        let anchor: (year: Int, label: String)? = {
            if let y = deathDate?.latest {
                return (y, "deathDate '\(deathDate?.original ?? String(y))'")
            }
            let burialYears = lifeEvents
                .filter { $0.type == .burial || $0.type == .probate }
                .compactMap { e in e.date?.earliest.map { (y: $0, t: e.type.rawValue) } }
                .sorted { $0.y < $1.y }
            return burialYears.first.map { ($0.y, "\($0.t) life event \($0.y)") }
        }()
        guard let anchor else { return nil }

        let later = ConflictPredicates.aliveEvidence(afterYear: anchor.year, in: lifeEvents)
        guard !later.isEmpty else { return nil }

        var competing = [FieldSource(
            origin: SourceOrigin(identifier: "tree"),
            raw: anchor.label,
            addedAt: Date()
        )]
        for (event, year) in later {
            competing.append(FieldSource(
                origin: SourceOrigin(identifier: event.sources.first?.origin.identifier ?? "tree"),
                raw: "\(event.type.rawValue) \(year)\(event.location.map { " at \($0)" } ?? "")",
                addedAt: Date()
            ))
        }
        let evidence: [String: [String]] = [
            "lifeEventIDs": later.map { $0.event.id.uuidString },
        ]
        let evidenceJSON = (try? JSONEncoder().encode(evidence))
            .flatMap { String(data: $0, encoding: .utf8) }
        let detail = later.map { "\($0.event.type.rawValue) \($0.year)" }
            .joined(separator: ", ")
        return DetectedConflict(
            kind: .timeline,
            profileID: profileID,
            field: "death-vs-alive",
            reason: .valueMismatch,
            severity: .conflict,
            competingSources: competing,
            evidenceJSON: evidenceJSON,
            reasoning: "F3 timeline conflict: \(anchor.label) is contradicted by later alive-evidence (\(detail)). A person cannot be recorded alive after death (DS-15).",
            detectedBy: detectedBy
        )
    }

    // MARK: - T-D (tree-state arm) — same-enumeration-year impossibility ⟨G13⟩

    /// Two census life events for the SAME census year on one subject.
    /// One person is enumerated once per year — duplicates are an
    /// impossibility, never corroboration. Field key carries the year
    /// (`census-1881`) so each year gets its own ≤1-open-dispute identity.
    static func sameEnumerationYearConflicts(
        profileID: String,
        lifeEvents: [LifeEvent],
        detectedBy: DisputeProducer = .consistencySweep
    ) -> [DetectedConflict] {
        ConflictPredicates.sameYearCensusDuplicates(in: lifeEvents)
            .sorted { $0.key < $1.key }
            .map { year, events in
                let competing = events.map { event in
                    FieldSource(
                        origin: SourceOrigin(identifier: event.sources.first?.origin.identifier ?? "tree"),
                        raw: "census \(year)\(event.location.map { " at \($0)" } ?? "") [\(event.id.uuidString.prefix(8))]",
                        addedAt: Date()
                    )
                }
                let evidence: [String: [String]] = [
                    "lifeEventIDs": events.map(\.id.uuidString),
                ]
                let evidenceJSON = (try? JSONEncoder().encode(evidence))
                    .flatMap { String(data: $0, encoding: .utf8) }
                return DetectedConflict(
                    kind: .timeline,
                    profileID: profileID,
                    field: "census-\(year)",
                    reason: .valueMismatch,
                    severity: .conflict,
                    competingSources: competing,
                    evidenceJSON: evidenceJSON,
                    reasoning: "T-D same-enumeration-year impossibility: \(events.count) census events for \(year) on one subject. One person is enumerated once per census year (⟨G13⟩).",
                    detectedBy: detectedBy
                )
            }
    }

    // MARK: - F5 — same-witness transcription disagreement (CL4)

    /// Two fact-grade records reduce to ONE WitnessKey yet assert
    /// different values: a transcription disagreement, graded low and
    /// R0-resolvable — never evidential conflict (§4.2 F5).
    static func sameWitnessDisagreements(
        profileID: String,
        records: [SourceRecord],
        detectedBy: DisputeProducer = .consistencySweep
    ) -> [DetectedConflict] {
        var conflicts: [DetectedConflict] = []
        var seenPairs = Set<String>()
        for i in records.indices {
            for j in records.indices where j > i {
                let a = records[i], b = records[j]
                let ka = WitnessIdentity.key(for: a), kb = WitnessIdentity.key(for: b)
                guard WitnessIdentity.sameWitness(ka, kb) else { continue }
                let va = ConvergenceEngine.valueKey(for: a)
                let vb = ConvergenceEngine.valueKey(for: b)
                guard va != vb else { continue }
                let pairKey = [a.id, b.id].sorted().joined(separator: "|")
                guard seenPairs.insert(pairKey).inserted else { continue }
                let fieldKey = "witness-\(ka.eventShape)-\(ka.year.map(String.init) ?? "?")"
                conflicts.append(DetectedConflict(
                    kind: .fieldValue,
                    profileID: profileID,
                    field: fieldKey,
                    reason: .valueMismatch,
                    severity: .note,
                    competingSources: [
                        FieldSource(origin: SourceOrigin(identifier: a.common.sourceID),
                                    raw: "\(va) [\(a.id)]", addedAt: Date()),
                        FieldSource(origin: SourceOrigin(identifier: b.common.sourceID),
                                    raw: "\(vb) [\(b.id)]", addedAt: Date()),
                    ],
                    evidenceJSON: (try? JSONEncoder().encode(["recordIDs": [a.id, b.id]]))
                        .flatMap { String(data: $0, encoding: .utf8) },
                    reasoning: "F5 same-witness disagreement: two transcriptions of one register entry (\(ka.eventShape) \(ka.year.map(String.init) ?? "?")) assert \(va) vs \(vb) — transcription variance, not corroboration.",
                    detectedBy: detectedBy,
                    sameWitness: true
                ))
            }
        }
        return conflicts
    }
}
