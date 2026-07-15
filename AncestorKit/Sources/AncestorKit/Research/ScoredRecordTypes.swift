import Foundation

/// Scored result — a source record classified through 4 gates.
/// Codable so the FULL scorer output persists to `evidence_records`
/// (gates_json + summary columns, CAMPAIGN_REVIEW_SPEC Change 2) — the
/// evidence chain is stored, not recomputed-only.
public nonisolated struct ScoredRecord: Identifiable, Sendable, Codable {
    public let id: String
    public let record: SourceRecord
    public let verdict: RecordVerdict
    public let gates: [GateResult]
    public let summary: String

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: String, record: SourceRecord, verdict: RecordVerdict, gates: [GateResult], summary: String) {
        self.id = id
        self.record = record
        self.verdict = verdict
        self.gates = gates
        self.summary = summary
    }

}

public nonisolated enum RecordVerdict: String, Codable, Sendable {
    case fact, lead, impossible
}

public nonisolated struct GateResult: Sendable, Codable {
    public let gate: ScoringGate
    public let outcome: GateOutcome
    public let reason: String

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(gate: ScoringGate, outcome: GateOutcome, reason: String) {
        self.gate = gate
        self.outcome = outcome
        self.reason = reason
    }

}

public nonisolated enum ScoringGate: String, Codable, Sendable {
    case name, date, geography, familyContext
}

public nonisolated enum GateOutcome: String, Codable, Sendable {
    case pass
    case fail           // hard fail — disqualifies (name mismatch, date impossibility)
    case softFail       // non-disqualifying — geography/type mismatch is suspicious but not fatal
    case impossible     // violates hard temporal rules
    case skip           // gate not applicable (no data to check)
}
