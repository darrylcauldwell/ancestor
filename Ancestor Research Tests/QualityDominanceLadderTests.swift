import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL5 (Half A) — the R2 quality-dominance ladder:
/// R2a originality, R2b tier, R2c error-band-gated proximity ⟨G7⟩, the
/// DS-09 displacement scenario, and the R3 shield (AC1/2/3/7).
struct QualityDominanceLadderTests {

    private func dateConflict(
        sources: [(origin: String, raw: String)],
        field: ProfileField = .deathDate
    ) -> DetectedConflict {
        DetectedConflict(
            kind: .fieldValue, profileID: "p1", field: field.rawValue,
            reason: .noOverlap, severity: .conflict,
            competingSources: sources.map {
                FieldSource(origin: SourceOrigin(identifier: $0.origin), raw: $0.raw, addedAt: Date())
            },
            evidenceJSON: nil, reasoning: "test", detectedBy: .applyEngine)
    }

    // MARK: - AC1: R2a originality dominance (DS-09)

    @Test func cwgcPrimaryDisplacesFindAGraveViaR2a() {
        // CWGC (primary register) vs FindAGrave (derivative memorial):
        // originality strictly dominates → R2a fires for CWGC.
        let conflict = dateConflict(sources: [
            (origin: "findagrave", raw: "1918"),
            (origin: "cwgc", raw: "1917"),
        ])
        let adjudication = DisputeResolver.adjudicate(conflict)
        if case .rule(let id, let accepted)? = adjudication.resolution {
            #expect(id == "R2a")
            #expect(accepted.origin.identifier == "cwgc")
        } else {
            Issue.record("expected R2a resolution, got \(String(describing: adjudication.resolution))")
        }
        #expect(adjudication.trace.contains { $0.rung == "R2a" && $0.outcome == "fired" })
    }

    @Test func r2aResolutionPersistsWithFullLadderTrace() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "Robert", lastName: "Cauldwell",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1918"), deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)

        let conflict = dateConflict(sources: [
            (origin: "findagrave", raw: "1918"),
            (origin: "cwgc", raw: "1917"),
        ])
        let adjudication = DisputeResolver.adjudicate(conflict)
        _ = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudication)

        // Persisted as RESOLVED .rule("R2a") — not an open dispute.
        #expect(try db.openDisputes(profileID: "p1").isEmpty)
        let all = try db.allDisputes(profileID: "p1")
        #expect(all.count == 1)
        #expect(all.first?.resolutionRuleLabel == "R2a")
        #expect(all.first?.ladderTrace?.contains("R2a") == true)
        #expect(all.first?.ladderTrace?.contains("R3") == true)
    }

    // MARK: - AC2 (open half): same-class rivals stay open with a full trace

    @Test func twoFreeBMDQuartersStayOpenWithTieTrace() {
        // Two FreeBMD quarters: same originality, same tier, same
        // proximity class — no rung fires, dispute stays open.
        let conflict = dateConflict(sources: [
            (origin: "freebmd", raw: "Mar 1905"),
            (origin: "freebmd", raw: "Dec 1913"),
        ])
        let adjudication = DisputeResolver.adjudicate(conflict)
        #expect(adjudication.resolution == nil)
        #expect(adjudication.trace.contains { $0.rung == "R2a" && $0.outcome == "not-fired" })
        #expect(adjudication.trace.contains { $0.rung == "R2b" && $0.outcome == "not-fired" })
        #expect(adjudication.trace.contains { $0.rung == "R2c" && $0.outcome == "not-fired" })
    }

    // MARK: - AC3: error band blocks R2c ⟨G7⟩

    @Test func censusDeltaOutsideErrorBandBlocksR2c() {
        // freebmd (at-event, proximity 2) vs freecen (census-implied,
        // proximity 1, band ±3): a 9-year delta exceeds the census class's
        // own noise — proximity may NOT decide; the disagreement is real.
        let conflict = dateConflict(sources: [
            (origin: "freebmd", raw: "1905"),
            (origin: "freecen", raw: "1914"),
        ], field: .birthDate)
        let adjudication = DisputeResolver.adjudicate(conflict)
        // freebmd and freecen share .transcription tier and directness, so
        // R2a/R2b tie; R2c is the deciding rung and must NOT fire.
        #expect(adjudication.resolution == nil)
        let r2c = adjudication.trace.first { $0.rung == "R2c" }
        #expect(r2c?.outcome == "not-fired")
        #expect(r2c?.detail.contains("band") == true)
    }

    @Test func censusDeltaInsideErrorBandLetsR2cFire() {
        // Same classes, 2-year delta — inside the census ±3 band: the
        // at-event class's precision legitimately wins.
        let conflict = dateConflict(sources: [
            (origin: "freebmd", raw: "1905"),
            (origin: "freecen", raw: "1907"),
        ], field: .birthDate)
        let adjudication = DisputeResolver.adjudicate(conflict)
        if case .rule(let id, let accepted)? = adjudication.resolution {
            #expect(id == "R2c")
            #expect(accepted.origin.identifier == "freebmd")
        } else {
            Issue.record("expected R2c resolution, got \(String(describing: adjudication.resolution))")
        }
    }

    // MARK: - AC7: R3 shields user-authoritative values from R2

    @Test func r3ShieldsUserValuesFromR2InBothDirections() {
        // A user-manual attestation among the competitors blocks ALL
        // auto-resolution — even when CWGC would otherwise dominate.
        let conflict = DetectedConflict(
            kind: .fieldValue, profileID: "p1", field: ProfileField.deathDate.rawValue,
            reason: .noOverlap, severity: .conflict,
            competingSources: [
                FieldSource(origin: SourceOrigin(identifier: "manual.edit"), raw: "1918", addedAt: Date()),
                FieldSource(origin: SourceOrigin(identifier: "cwgc"), raw: "1917", addedAt: Date()),
            ],
            evidenceJSON: nil, reasoning: "test", detectedBy: .applyEngine)
        let adjudication = DisputeResolver.adjudicate(conflict)
        #expect(adjudication.resolution == nil)
        #expect(adjudication.trace.contains { $0.rung == "R3" && $0.outcome == "fired" })
    }

    // MARK: - Structural kinds never reach R2

    @Test func structuralConflictsAreNotR2Applicable() {
        let conflict = DetectedConflict(
            kind: .parentRole, profileID: "p1", field: "mother",
            reason: .valueMismatch, severity: .conflict,
            competingSources: [
                FieldSource(origin: SourceOrigin(identifier: "tree"), raw: "existing mother: BOWN", addedAt: Date()),
                FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "accepted mother: LAND", addedAt: Date()),
            ],
            evidenceJSON: nil, reasoning: "test", detectedBy: .consistencySweep)
        let adjudication = DisputeResolver.adjudicate(conflict)
        #expect(adjudication.resolution == nil)
        #expect(adjudication.trace.contains { $0.rung == "R2" && $0.outcome == "not-applicable" })
    }
}
