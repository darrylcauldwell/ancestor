import Foundation

/// Accumulating state for one person's research session.
/// Records are in a single array; verdict determines partition.
struct ResearchState: Sendable {
    var subject: ResearchSubject
    var scoredRecords: [ScoredRecord] = []
    var householdMembers: [HouseholdMember] = []
    var searchHistory: [SearchAttempt] = []
    var discrepancies: [ResearchDiscrepancy] = []
    /// IDs of records collected by hypothesis-flow dispatch (marriage
    /// enrichment, sibling candidate search). Kept in `scoredRecords`
    /// so they persist as evidence and reach the lead store, but
    /// excluded from clustering — they answer per-hypothesis questions,
    /// not "is this another candidate life of the subject".
    var enrichmentRecordIDs: Set<String> = []
    var activeRecordTypes: Set<RecordType>
    var iteration: Int = 0

    // Computed partitions — single source of truth is scoredRecords + verdict
    var confirmedFacts: [ScoredRecord] { scoredRecords.filter { $0.verdict == .fact } }
    var leads: [ScoredRecord] { scoredRecords.filter { $0.verdict == .lead } }
    var rejectedRecords: [ScoredRecord] { scoredRecords.filter { $0.verdict == .impossible } }

    init(subject: ResearchSubject) {
        self.subject = subject
        self.activeRecordTypes = [.birth, .death, .marriage, .census, .burial, .probate, .parish, .pedigree]
    }
}

/// A record of a search that was executed.
nonisolated struct SearchAttempt: Sendable {
    let sourceID: String
    let recordType: RecordType
    let searchKey: String
    let resultCount: Int
    let timestamp: Date
}

/// Configuration for a research run.
nonisolated struct ResearchConfig: Sendable {
    let maxIterations: Int
    let maxFacts: Int
    let mode: ResearchMode
    let scope: ResearchScope

    init(
        maxIterations: Int,
        maxFacts: Int,
        mode: ResearchMode,
        scope: ResearchScope = .county
    ) {
        self.maxIterations = maxIterations
        self.maxFacts = maxFacts
        self.mode = mode
        self.scope = scope
    }

    static let verify = ResearchConfig(maxIterations: 2, maxFacts: 20, mode: .verify)
    static let extend = ResearchConfig(maxIterations: 4, maxFacts: 50, mode: .extend)
    static let discover = ResearchConfig(maxIterations: 4, maxFacts: 100, mode: .discover)
    /// Most thorough preset — supersets Discover with extra iterations and
    /// a higher fact cap. No early stop. Use for "I'm not sure, throw it all".
    static let all = ResearchConfig(maxIterations: 6, maxFacts: 200, mode: .all)

    /// Look up the canonical config for any mode.
    static func preset(for mode: ResearchMode) -> ResearchConfig {
        switch mode {
        case .verify:   return .verify
        case .extend:   return .extend
        case .discover: return .discover
        case .all:      return .all
        }
    }

    func with(scope: ResearchScope) -> ResearchConfig {
        ResearchConfig(maxIterations: maxIterations, maxFacts: maxFacts, mode: mode, scope: scope)
    }
}

/// A discrepancy detected between a source record and existing tree data.
nonisolated struct ResearchDiscrepancy: Sendable {
    let field: String               // e.g. "birthYear", "deathYear"
    let existingValue: String       // What the tree says
    let sourceValue: String         // What the source says
    let sourceID: String
    let severity: DiscrepancySeverity
    let reasoning: String           // Why this severity was assigned
}

/// The output of a research run.
nonisolated struct ResearchResult: Sendable {
    let confirmedFacts: [ScoredRecord]
    let leads: [ScoredRecord]
    let allScoredRecords: [ScoredRecord]
    let clusters: [LifeCluster]
    let discrepancies: [ResearchDiscrepancy]
    let householdMembers: [HouseholdMember]
    let searchHistory: [SearchAttempt]
    /// Pipeline-generated research hypotheses (V2 spec §4.1). Populated
    /// by `HypothesisEngine` after the post-loop phase. T12 completed
    /// the migration: `.siblingExists`, `.parentInferred`, and
    /// `.parentMarriage` hypotheses are the sole sources of truth for
    /// sibling discovery and parent inference — the legacy
    /// `proposedSiblings` and `proposedRelatives` fields that mirrored
    /// them are now deleted. The UI projects through
    /// `ResearchPipeline.projectSiblingExistsToProposals` /
    /// `projectParentInferredToProposal` on demand for accept/reject.
    let hypotheses: [ResearchHypothesis]

    init(
        confirmedFacts: [ScoredRecord],
        leads: [ScoredRecord],
        allScoredRecords: [ScoredRecord],
        clusters: [LifeCluster],
        discrepancies: [ResearchDiscrepancy],
        householdMembers: [HouseholdMember],
        searchHistory: [SearchAttempt],
        hypotheses: [ResearchHypothesis] = []
    ) {
        self.confirmedFacts = confirmedFacts
        self.leads = leads
        self.allScoredRecords = allScoredRecords
        self.clusters = clusters
        self.discrepancies = discrepancies
        self.householdMembers = householdMembers
        self.searchHistory = searchHistory
        self.hypotheses = hypotheses
    }

    static let empty = ResearchResult(
        confirmedFacts: [], leads: [], allScoredRecords: [],
        clusters: [], discrepancies: [], householdMembers: [], searchHistory: []
    )
}
