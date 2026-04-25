import Foundation

/// Accumulating state for one person's research session.
/// Records are in a single array; verdict determines partition.
struct ResearchState: Sendable {
    var subject: ResearchSubject
    var scoredRecords: [ScoredRecord] = []
    var householdMembers: [HouseholdMember] = []
    var searchHistory: [SearchAttempt] = []
    var activeRecordTypes: Set<RecordType>
    var iteration: Int = 0

    // Computed partitions — single source of truth is scoredRecords + verdict
    var confirmedFacts: [ScoredRecord] { scoredRecords.filter { $0.verdict == .fact } }
    var leads: [ScoredRecord] { scoredRecords.filter { $0.verdict == .lead } }
    var rejectedRecords: [ScoredRecord] { scoredRecords.filter { $0.verdict == .impossible } }

    init(subject: ResearchSubject) {
        self.subject = subject
        self.activeRecordTypes = [.birth, .death, .marriage, .census, .burial]
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

    static let verify = ResearchConfig(maxIterations: 2, maxFacts: 20, mode: .verify)
    static let extend = ResearchConfig(maxIterations: 4, maxFacts: 50, mode: .extend)
    static let discover = ResearchConfig(maxIterations: 4, maxFacts: 100, mode: .discover)
}

/// The output of a research run.
nonisolated struct ResearchResult: Sendable {
    let confirmedFacts: [ScoredRecord]
    let leads: [ScoredRecord]
    let allScoredRecords: [ScoredRecord]
    let clusters: [LifeCluster]
    let householdMembers: [HouseholdMember]
    let searchHistory: [SearchAttempt]

    static let empty = ResearchResult(
        confirmedFacts: [], leads: [], allScoredRecords: [],
        clusters: [], householdMembers: [], searchHistory: []
    )
}
