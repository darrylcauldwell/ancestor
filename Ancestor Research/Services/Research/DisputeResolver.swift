import Foundation

/// CONFLICT_LAYER_SPEC §4.6 — C6, the deterministic resolution ladder.
/// Runs at detection time, before a dispute is persisted. A conflict is
/// auto-resolved ONLY if a rule fires; everything else stays open
/// (decision log #4 — default disposition = open + surfaced).
///
/// Every evaluation — fired or not — appends to the ladder trace ⟨G2⟩; the
/// trace persists on the dispute row as the written proof argument GPS
/// element 4 requires and the verbatim-groundable input the T9 dossier
/// consumes.
///
/// CL1 state (spec §6 Change 1): R3 (user-authoritative shield) and R1
/// (precision subsumption, filtered at detection) are live; **R0 is inert
/// until CL4** (needs WitnessIdentity) and **R2 until CL5** (quality
/// dominance is the programme's first write-behaviour change). Because no
/// rung can select a winner in CL1, `adjudicate` never returns a
/// resolution — the zero-write-outcome guarantee: the only new persistence
/// anywhere in Change 1 is open dispute rows.
nonisolated struct DisputeResolver {

    /// One evaluated rung: `{rung, outcome, detail}` — persisted as the
    /// `ladder_trace` JSON array ⟨G2⟩.
    struct RungEvaluation: Codable, Equatable, Sendable {
        let rung: String
        let outcome: String
        let detail: String
    }

    /// Adjudication result. `resolution == nil` means the dispute stays
    /// open (always the case in CL1).
    struct Adjudication: Sendable {
        let resolution: DisputeResolution?
        let trace: [RungEvaluation]

        var traceJSON: String {
            (try? JSONEncoder().encode(trace))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
    }

    /// Evaluate the ladder over a detected conflict, in spec order:
    /// R3 → R0 → R1 → R2.
    static func adjudicate(_ conflict: DetectedConflict) -> Adjudication {
        var trace: [RungEvaluation] = []

        // R3 — user-authoritative shield, evaluated first (§4.6). Any
        // competing attestation with a user-manual origin blocks
        // auto-resolution in BOTH directions; the dispute stays open for
        // the human (check-before-overwrite).
        let userSources = conflict.competingSources.filter {
            $0.origin.tier == .userAuthoritative
        }
        if !userSources.isEmpty {
            let origins = userSources.map(\.origin.identifier).joined(separator: ", ")
            trace.append(RungEvaluation(
                rung: "R3",
                outcome: "fired",
                detail: "user-authoritative attestation present (\(origins)) — no auto-resolution in either direction; dispute stays open for the human"
            ))
            for (rung, note) in [("R0", "shielded by R3"), ("R1", "shielded by R3"), ("R2", "shielded by R3")] {
                trace.append(RungEvaluation(rung: rung, outcome: "skipped", detail: note))
            }
            return Adjudication(resolution: nil, trace: trace)
        }
        trace.append(RungEvaluation(
            rung: "R3",
            outcome: "not-fired",
            detail: "no user-authoritative attestation among competitors"
        ))

        // R0 — same-witness reduction (CL4, live). A conflict whose every
        // competitor reduces to ONE witness is transcription variance:
        // when exactly one competing attestation carries a strictly higher
        // trust tier, that transcription wins — recorded, never silent.
        if conflict.sameWitness {
            let ranked = conflict.competingSources
                .map { (source: $0, tier: ConflictDetector.trustTier(forOriginIdentifier: $0.origin.identifier)) }
                .sorted { $0.tier > $1.tier }
            if let best = ranked.first, ranked.count >= 2, best.tier > ranked[1].tier {
                trace.append(RungEvaluation(
                    rung: "R0",
                    outcome: "fired",
                    detail: "same-witness transcription variance — '\(best.source.origin.identifier)' (\(best.tier.rawValue)) outranks the other transcription(s); higher-quality transcription accepted"
                ))
                for (rung, note) in [("R1", "resolved at R0"), ("R2", "resolved at R0")] {
                    trace.append(RungEvaluation(rung: rung, outcome: "not-evaluated", detail: note))
                }
                return Adjudication(
                    resolution: .rule(id: "R0", accepted: best.source),
                    trace: trace)
            }
            trace.append(RungEvaluation(
                rung: "R0",
                outcome: "not-fired",
                detail: "same-witness variance but no transcription strictly outranks the others — stays open for the human"
            ))
        } else {
            trace.append(RungEvaluation(
                rung: "R0",
                outcome: "not-fired",
                detail: "competitors span more than one witness — genuine evidential conflict, not transcription variance"
            ))
        }

        // R1 — precision subsumption. A strictly-contained value never
        // opens a dispute at all: F1 filters containment as refinement at
        // detection (ApplyEngine's narrower-span rule restated), so by
        // construction no competitor pair here strictly contains another.
        trace.append(RungEvaluation(
            rung: "R1",
            outcome: "not-fired",
            detail: "no strict containment among competing values (refinements are filtered at detection and never open disputes)"
        ))

        // R2 — quality dominance (CL5, live): R2a originality strictly
        // first (⟨G7⟩ — EvidenceDirectness before SourceTrustTier, the
        // GPS-canonical primary axis), R2b trust tier, R2c error-band-
        // gated proximity. Date fieldValue conflicts only; every other
        // kind stays a human decision.
        if conflict.kind == .fieldValue,
           conflict.field == ProfileField.birthDate.rawValue
            || conflict.field == ProfileField.deathDate.rawValue {

            // Competitors with parseable years; the 'tree' pseudo-origin
            // is neutral — it carries the incumbent value whose real
            // provenance lives in field_sources and is represented by the
            // attested competitor rows.
            let ranked = conflict.competingSources.map { source in
                (source: source,
                 directness: ConflictDetector.evidenceDirectness(forOriginIdentifier: source.origin.identifier),
                 tier: ConflictDetector.trustTier(forOriginIdentifier: source.origin.identifier),
                 year: GenealogicalDate(parsing: source.raw).earliest)
            }

            // R2a — originality dominance.
            if let winner = uniqueMax(ranked, by: { $0.directness.rawValue }) {
                trace.append(RungEvaluation(
                    rung: "R2a", outcome: "fired",
                    detail: "originality dominance: '\(winner.source.origin.identifier)' (\(winner.directness)) strictly outranks every competitor"
                ))
                return Adjudication(
                    resolution: .rule(id: "R2a", accepted: winner.source), trace: trace)
            }
            trace.append(RungEvaluation(
                rung: "R2a", outcome: "not-fired",
                detail: "no competitor strictly dominates on originality"
            ))

            // R2b — trust-tier dominance.
            if let winner = uniqueMax(ranked, by: { tierRank($0.tier) }) {
                trace.append(RungEvaluation(
                    rung: "R2b", outcome: "fired",
                    detail: "tier dominance: '\(winner.source.origin.identifier)' (\(winner.tier.rawValue)) strictly outranks every competitor"
                ))
                return Adjudication(
                    resolution: .rule(id: "R2b", accepted: winner.source), trace: trace)
            }
            trace.append(RungEvaluation(
                rung: "R2b", outcome: "not-fired",
                detail: "no competitor strictly dominates on trust tier"
            ))

            // R2c — error-band-gated proximity ⟨G7⟩: the at-event class
            // wins ONLY when every losing value's delta from the winner
            // lies within the losing record-class's error band (a delta
            // the losing class can plausibly explain as its own noise).
            if let winner = uniqueMax(ranked, by: { proximityRank($0.source.origin.identifier) }),
               let winnerYear = winner.year {
                let losers = ranked.filter { $0.source.origin.identifier != winner.source.origin.identifier }
                let bandChecks = losers.map { loser -> (ok: Bool, detail: String) in
                    guard let loserYear = loser.year else {
                        return (false, "'\(loser.source.origin.identifier)' has no parseable year")
                    }
                    let delta = abs(loserYear - winnerYear)
                    let band = errorBand(forOriginIdentifier: loser.source.origin.identifier)
                    return (delta <= band,
                            "'\(loser.source.origin.identifier)' delta \(delta)y vs band ±\(band)y")
                }
                let arithmetic = bandChecks.map(\.detail).joined(separator: "; ")
                if bandChecks.allSatisfy(\.ok) {
                    trace.append(RungEvaluation(
                        rung: "R2c", outcome: "fired",
                        detail: "proximity dominance within error bands: \(arithmetic)"
                    ))
                    return Adjudication(
                        resolution: .rule(id: "R2c", accepted: winner.source), trace: trace)
                }
                trace.append(RungEvaluation(
                    rung: "R2c", outcome: "not-fired",
                    detail: "delta outside the losing class's error band: \(arithmetic)"
                ))
            } else {
                trace.append(RungEvaluation(
                    rung: "R2c", outcome: "not-fired",
                    detail: "no competitor strictly dominates on proximity class (same-class rivals)"
                ))
            }
        } else {
            trace.append(RungEvaluation(
                rung: "R2", outcome: "not-applicable",
                detail: "quality dominance applies to date fieldValue conflicts only — structural and string conflicts stay with the human"
            ))
        }

        return Adjudication(resolution: nil, trace: trace)
    }

    /// The element strictly greater than every other under `rank`, if any.
    private static func uniqueMax<T>(
        _ items: [T], by rank: (T) -> Int
    ) -> T? {
        guard let maxRank = items.map(rank).max() else { return nil }
        let top = items.filter { rank($0) == maxRank }
        return top.count == 1 && items.count > 1 ? top[0] : nil
    }

    private static func tierRank(_ tier: SourceTrustTier) -> Int {
        tier.rawValue
    }

    /// Proximity-to-event class per origin: registers created AT the event
    /// outrank derived/recollected classes. 'tree'/'gedcom' are neutral
    /// (their provenance is the attested competitors).
    private static func proximityRank(_ identifier: String) -> Int {
        switch identifier {
        case "cwgc", "probate", "freebmd", "freereg", "wirksworth": return 2
        case "freecen", "familysearch": return 1   // census-implied / mixed
        case "findagrave": return 1                 // memorial recollection
        default: return 0
        }
    }

    /// How far a value from this class can plausibly drift from the true
    /// event date through the class's OWN noise (census age-fudging,
    /// memorial recollection) — the ⟨G7⟩ gate for R2c.
    private static func errorBand(forOriginIdentifier identifier: String) -> Int {
        switch identifier {
        case "freecen", "familysearch": return 3   // census age-fudging ±3
        case "findagrave": return 2                 // memorial recollection ±2
        case "freebmd", "freereg", "wirksworth", "cwgc", "probate": return 1
        default: return 0
        }
    }
}
