import Testing
import Foundation
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §4.6 — C6 ladder, CL1 state: R3 shield + R1 filter
/// live, R0/R2 honestly inert, every rung traced ⟨G2⟩, and the
/// zero-write-outcome guarantee (adjudicate NEVER resolves in CL1).
struct DisputeResolverTests {

    private func conflict(
        sources: [FieldSource],
        kind: DisputeKind = .fieldValue
    ) -> DetectedConflict {
        DetectedConflict(
            kind: kind,
            profileID: "p1",
            field: "deathDate",
            reason: .noOverlap,
            severity: .conflict,
            competingSources: sources,
            evidenceJSON: nil,
            reasoning: "test",
            detectedBy: .applyEngine
        )
    }

    // MARK: - CL1 zero-write-outcome guarantee

    @Test func cl1NeverAutoResolves() {
        // No rung can pick a winner in CL1: R0 needs WitnessIdentity
        // (CL4), R2 ships CL5, R1 conflicts are filtered at detection.
        // Every dispute persists open.
        let adjudication = DisputeResolver.adjudicate(conflict(sources: [
            FieldSource(origin: .gedcom, raw: "1901", addedAt: Date()),
            FieldSource(origin: .freebmd, raw: "Dec 1900", addedAt: Date()),
        ]))
        #expect(adjudication.resolution == nil)
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
        let rungs = adjudication.trace.map(\.rung)
        #expect(rungs == ["R3", "R0", "R1", "R2"])
        #expect(adjudication.trace.first { $0.rung == "R1" }?.outcome == "not-fired")
        // CL4: R0 is live — for a cross-witness conflict (this fixture)
        // it evaluates and does not fire (genuine evidential conflict).
        #expect(adjudication.trace.first { $0.rung == "R0" }?.outcome == "not-fired")
        #expect(adjudication.trace.first { $0.rung == "R0" }?.detail.contains("witness") == true)
        #expect(adjudication.trace.first { $0.rung == "R2" }?.outcome == "inert")
        #expect(adjudication.trace.first { $0.rung == "R2" }?.detail.contains("CL5") == true)
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
