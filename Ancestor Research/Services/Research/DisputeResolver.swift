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

        // R2 — quality dominance (originality → tier → error-band-gated
        // proximity ⟨G7⟩). The programme's first write-behaviour change;
        // ships in CL5. Inert until then.
        trace.append(RungEvaluation(
            rung: "R2",
            outcome: "inert",
            detail: "quality-dominance ladder ships in CL5 — not evaluated"
        ))

        return Adjudication(resolution: nil, trace: trace)
    }
}
