import Foundation

/// Per-research-run aggregate of how candidate records flowed through
/// the 4-gate scorer (ENGINE_FOUNDATION_SPEC #Change4). Surfaces
/// whether the natural brake is engaged at the periphery — for a
/// rich subject we expect strong attrition at name + date gates; for
/// a thin subject we expect almost everything to pass the (now
/// permissive) gates and the verdict-cap from #Change1 to do the
/// filtering downstream.
///
/// Derived purely from `[ScoredRecord]` — the scorer doesn't need to
/// know about this aggregate.
public nonisolated struct ScorerAttrition: Sendable, Equatable {

    /// Total records scored — the denominator for every other count.
    public let candidatesEntered: Int

    /// Records whose name gate emitted `.pass`. Soft-fail and skip
    /// outcomes don't count as passed.
    public let namePassed: Int

    /// Records whose date gate emitted `.pass`. `.impossible` and
    /// `.fail` are both not-passed; `.impossible` short-circuits the
    /// verdict but still consumes the candidate.
    public let datePassed: Int

    /// Records whose geography gate emitted `.pass`. Soft-fail (out-of-
    /// home-county but UK) doesn't count.
    public let geographyPassed: Int

    /// Records where the family-context gate was applicable AND
    /// passed. The family-context gate is bonus — it `.skip`s when
    /// the record type doesn't carry family signal (e.g. a birth
    /// record without household members). Skipped records are
    /// excluded from `familyContextEvaluated`.
    public let familyContextPassed: Int

    /// Records where the family-context gate ran (was not `.skip`).
    public let familyContextEvaluated: Int

    /// Final verdict counts. The three add up to `candidatesEntered`
    /// — every scored record gets exactly one verdict.
    public let factCount: Int
    public let leadCount: Int
    public let impossibleCount: Int

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(candidatesEntered: Int, namePassed: Int, datePassed: Int, geographyPassed: Int, familyContextPassed: Int, familyContextEvaluated: Int, factCount: Int, leadCount: Int, impossibleCount: Int) {
        self.candidatesEntered = candidatesEntered
        self.namePassed = namePassed
        self.datePassed = datePassed
        self.geographyPassed = geographyPassed
        self.familyContextPassed = familyContextPassed
        self.familyContextEvaluated = familyContextEvaluated
        self.factCount = factCount
        self.leadCount = leadCount
        self.impossibleCount = impossibleCount
    }


    /// Compute attrition from a hop's scored records.
    public static func from(_ records: [ScoredRecord]) -> ScorerAttrition {
        var namePass = 0
        var datePass = 0
        var geoPass = 0
        var familyPass = 0
        var familyEval = 0
        var fact = 0
        var lead = 0
        var impossible = 0

        for r in records {
            for gate in r.gates {
                switch gate.gate {
                case .name:      if gate.outcome == .pass { namePass += 1 }
                case .date:      if gate.outcome == .pass { datePass += 1 }
                case .geography: if gate.outcome == .pass { geoPass += 1 }
                case .familyContext:
                    familyEval += 1
                    if gate.outcome == .pass { familyPass += 1 }
                }
            }
            switch r.verdict {
            case .fact:       fact += 1
            case .lead:       lead += 1
            case .impossible: impossible += 1
            }
        }

        return ScorerAttrition(
            candidatesEntered: records.count,
            namePassed: namePass,
            datePassed: datePass,
            geographyPassed: geoPass,
            familyContextPassed: familyPass,
            familyContextEvaluated: familyEval,
            factCount: fact,
            leadCount: lead,
            impossibleCount: impossible
        )
    }

    /// One-line human description for activity feed / logs.
    public var humanSummary: String {
        guard candidatesEntered > 0 else { return "0 candidates scored" }
        let factPct = factCount * 100 / candidatesEntered
        return "\(candidatesEntered) scored → \(factCount) facts, "
             + "\(leadCount) leads, \(impossibleCount) impossible "
             + "(\(factPct)% fact)"
    }
}
