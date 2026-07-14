import Testing
import Foundation
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §4.6/§4.7 — C6 ladder, CL5 state: R3 shield + R1
/// filter + R0 same-witness reduction live, R2 quality-dominance ladder
/// (R2a originality / R2b tier / R2c error-band-gated proximity) live for
/// DATE fieldValue conflicts (DS-09 write-behaviour change), every rung
/// traced ⟨G2⟩, and everything that isn't a date fieldValue conflict
/// stays a human decision.
struct DisputeResolverTests {

    private func conflict(
        sources: [FieldSource],
        kind: DisputeKind = .fieldValue,
        field: String = "deathDate"
    ) -> DetectedConflict {
        DetectedConflict(
            kind: kind,
            profileID: "p1",
            field: field,
            reason: .noOverlap,
            severity: .conflict,
            competingSources: sources,
            evidenceJSON: nil,
            reasoning: "test",
            detectedBy: .applyEngine
        )
    }

    // MARK: - R2 quality dominance (CL5, DS-09)

    @Test func r2aOriginalityDominanceResolvesDateConflict() {
        // A GRO-index transcription (freebmd, directTranscription)
        // strictly outranks a GEDCOM assertion on originality — R2a fires
        // and the dispute auto-resolves with a recorded trace. This is the
        // CL5 write-behaviour change (DS-09); the CL1-era zero-write
        // guarantee is deliberately superseded.
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .gedcom, raw: "1901", addedAt: Date()),
            FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
        ]))
        guard case .rule(let id, let accepted)? = adjudication.resolution else {
            Issue.record("Expected R2a rule resolution, got \(String(describing: adjudication.resolution))")
            return
        }
        #expect(id == "R2a")
        #expect(accepted.origin.identifier == "freebmd")
    }

    @Test func nonDateFieldValueConflictsNeverAutoResolve() {
        // The R2 ladder is date-fieldValue-only: string and structural
        // conflicts stay with the human, traced as not-applicable.
        let adjudication = DisputeResolver.adjudicate(conflict(
            sources: [
                FieldSource(origin: .gedcom, raw: "Derby", addedAt: Date()),
                FieldSource(origin: .freebmd, raw: "Belper", addedAt: Date()),
            ],
            field: "deathLocation"
        ))
        #expect(adjudication.resolution == nil)
        let r2 = adjudication.trace.first { $0.rung == "R2" }
        #expect(r2?.outcome == "not-applicable")
        #expect(r2?.detail.contains("date fieldValue") == true)
    }

    // MARK: - R3 user-authoritative shield (AC6)

    @Test func r3FiresWhenUserValueIsTheExistingSide() {
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .manual, raw: "1901", addedAt: Date()),
            FieldSource(origin: .cwgc, raw: "14 July 1918", addedAt: Date()),
        ]))
        #expect(adjudication.resolution == nil)
        let r3 = adjudication.trace.first { $0.rung == "R3" }
        #expect(r3?.outcome == "fired")
        #expect(r3?.detail.contains("manual") == true)
        // Downstream rungs are shielded, never evaluated past R3.
        for rung in ["R0", "R1", "R2"] {
            #expect(adjudication.trace.first { $0.rung == rung }?.outcome == "skipped")
        }
    }

    @Test func r3FiresWhenUserValueIsTheCandidateSide() {
        // "In either direction" — a user-entered candidate is shielded
        // exactly like a user-entered incumbent (check-before-overwrite).
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .cwgc, raw: "14 July 1918", addedAt: Date()),
            FieldSource(origin: .manualRecord, raw: "1919", addedAt: Date()),
        ]))
        #expect(adjudication.resolution == nil)
        #expect(adjudication.trace.first { $0.rung == "R3" }?.outcome == "fired")
    }

    @Test func r3DoesNotFireForResearchOnlyCompetitors() {
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .gedcom, raw: "1901", addedAt: Date()),
            FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
        ]))
        #expect(adjudication.trace.first { $0.rung == "R3" }?.outcome == "not-fired")
    }

    // MARK: - Trace completeness ⟨G2⟩ (AC1's R3/R1 evaluations)

    @Test func everyRungIsTracedFiredOrNot() {
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .gedcom, raw: "1901", addedAt: Date()),
            FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
        ]))
        // This fixture resolves at R2a (originality dominance), so the
        // ladder short-circuits there — R2b/R2c are never reached and
        // every evaluated rung is traced.
        let rungs = adjudication.trace.map(\.rung)
        #expect(rungs == ["R3", "R0", "R1", "R2a"])
        #expect(adjudication.trace.first { $0.rung == "R1" }?.outcome == "not-fired")
        // CL4: R0 is live — for a cross-witness conflict (this fixture)
        // it evaluates and does not fire (genuine evidential conflict).
        #expect(adjudication.trace.first { $0.rung == "R0" }?.outcome == "not-fired")
        #expect(adjudication.trace.first { $0.rung == "R0" }?.detail.contains("witness") == true)
        #expect(adjudication.trace.first { $0.rung == "R2a" }?.outcome == "fired")
        #expect(adjudication.trace.first { $0.rung == "R2a" }?.detail.contains("originality") == true)
    }

    @Test func traceSerialisesToJSONArray() throws {
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
        ]))
        let json = adjudication.traceJSON
        let decoded = try JSONDecoder().decode(
            [DisputeResolver.RungEvaluation].self, from: Data(json.utf8)
        )
        #expect(decoded == adjudication.trace)
        #expect(decoded.isEmpty == false)
    }
}
