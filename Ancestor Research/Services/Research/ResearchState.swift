import Foundation

/// Accumulating state for one person's research session.
/// Records are in a single array; verdict determines partition.
struct ResearchState: Sendable {
    var subject: ResearchSubject
    var scoredRecords: [ScoredRecord] = []
    var householdMembers: [HouseholdMember] = []
    var searchHistory: [SearchAttempt] = []
    /// Per-(source, query) honesty envelopes from the main iteration-loop
    /// dispatches (T1-01). Deliberately NOT populated by the post-loop
    /// pivot probes (post-marriage / mother-in-law / child-gap) — those
    /// search for other people or under substituted identities, so their
    /// clean-zero outcomes must never read as "the subject was searched
    /// and absent".
    var searchOutcomes: [SearchOutcomeEntry] = []
    var discrepancies: [ResearchDiscrepancy] = []
    /// IDs of records collected by hypothesis-flow dispatch (marriage
    /// enrichment, sibling candidate search). Kept in `scoredRecords`
    /// so they persist as evidence and reach the lead store, but
    /// excluded from clustering — they answer per-hypothesis questions,
    /// not "is this another candidate life of the subject".
    var enrichmentRecordIDs: Set<String> = []
    var activeRecordTypes: Set<RecordType>
    var iteration: Int = 0
    /// Count of consensus proposals (slice B subject-self-narrowing)
    /// written to `pending_facts` this run. Surfaced in the
    /// Research-Complete footer so the user notices new narrowing
    /// proposals waiting in Triage ( of the spec).
    var consensusProposalCount: Int = 0

    // Computed partitions — single source of truth is scoredRecords + verdict
    var confirmedFacts: [ScoredRecord] { scoredRecords.filter { $0.verdict == .fact } }
    var leads: [ScoredRecord] { scoredRecords.filter { $0.verdict == .lead } }
    var rejectedRecords: [ScoredRecord] { scoredRecords.filter { $0.verdict == .impossible } }

    init(subject: ResearchSubject) {
        self.subject = subject
        // When the caller set a focus, narrow to that focus's record
        // types instead of the full default set. See
        // Research pipeline.
        if let focus = subject.focus {
            self.activeRecordTypes = focus.recordTypes
        } else {
            self.activeRecordTypes = [.birth, .death, .marriage, .census, .burial, .probate, .parish, .pedigree]
        }
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

/// Per-(source, query) honesty-envelope record from one dispatcher
/// fan-out (connector-audit T1-01). Where `SearchAttempt` is the
/// human-facing aggregate history, these entries carry the per-query
/// availability/truncation truth that negative-evidence recording and
/// GPS criterion-1 accounting consume.
nonisolated struct SearchOutcomeEntry: Sendable {
    let sourceID: String
    let recordType: RecordType
    let strictness: SearchStrictness
    /// `QueryCache.cacheKey` for the query — stable per wire request.
    let queryKey: String
    let outcome: SearchOutcome
    /// A tree fact this query PRESUPPOSED that the tree cannot cite — see
    /// `ResearchSubject.unverifiedKinPremises`. Nil for the overwhelming
    /// majority of queries, and `var` only so the synthesised memberwise
    /// init keeps it optional for every existing construction site.
    ///
    /// A search is evidence of absence only if its premises hold. The Gladwin
    /// parents' marriage was searched twice under an uncited GEDCOM surname
    /// ("Wheatman"), came back empty both times because the surname was wrong
    /// (HEWKIN), and both empties were banked as durable negatives that went
    /// on suppressing the search. A premise-bearing empty is a fact about our
    /// assumption, not about the record.
    var unverifiedPremise: String? = nil

    /// The caveat this entry earns when it comes back empty — the phrasing
    /// the review surfaces show in place of a bare "searched, nothing found".
    var assumptionCaveat: String? {
        unverifiedPremise.map { "searched, but the query assumed \($0), which is unverified" }
    }
}

/// Aggregates per-query outcomes into the genuine negatives that may be
/// persisted to `negative_searches` (T1-01 piece 5). Pure and
/// deterministic — the persistence call site is
/// `ResearchRunService.persist`.
nonisolated enum NegativeSearchAggregator {

    struct Negative: Equatable {
        let sourceID: String
        let recordType: RecordType
        /// How many clean-zero queries back this negative — recorded in
        /// `negative_searches.search_params` for audit.
        let queryCount: Int
    }

    /// One persistable clean-negative WIRE query (connector-audit T1-04).
    /// Where `Negative` is the pair-level aggregate the run footer/log
    /// reports, this is the per-query grain the cross-run reader matches
    /// against: `queryKey` is `QueryCache.cacheKey` — the exact
    /// normalized-params identity of the outbound request. The reader
    /// suppresses a next-run query iff its cacheKey equals a stored
    /// `queryKey` within the freshness window.
    struct NegativeKey: Equatable {
        let sourceID: String
        let recordType: RecordType
        /// `QueryCache.cacheKey` — the normalized wire identity. Stored in
        /// `negative_searches.search_params` and matched verbatim on read,
        /// so write and read normalization are the SAME code path (T1-04
        /// correctness guard (d): params normalization must match exactly).
        let queryKey: String
    }

    /// A (source, recordType) pair is a genuine negative iff EVERY
    /// outcome for the pair is a clean negative (availability ok, not
    /// truncated, zero records) AND no scored record from that pair
    /// exists anywhere in the run (strategist/pivot/hypothesis flows
    /// dispatch outside the main fan-out, so a record in hand always
    /// vetoes). Any error, block, throttle, or truncation in the pair
    /// leaves its emptiness unproven — nothing is recorded.
    ///
    /// Suppressed replays (T1-04) are clean `.ok` zeros but
    /// `isCleanNegative == false` by construction, so a pair made up of
    /// only-suppressed replays is NOT re-persisted here — it's the same
    /// absence already on disk.
    ///
    /// Queries resting on an unverified premise are excluded (EV7): their
    /// emptiness is unproven for a reason no availability code captures — the
    /// wire answered honestly, we asked the wrong question. A pair made up of
    /// nothing but premise-bearing queries yields no negative at all.
    static func genuineNegatives(
        outcomes: [SearchOutcomeEntry],
        scoredRecords: [ScoredRecord]
    ) -> [Negative] {
        cleanPairs(outcomes: outcomes, scoredRecords: scoredRecords)
            .compactMap { pair -> Negative? in
                let proven = pair.entries.filter { $0.unverifiedPremise == nil }
                guard !proven.isEmpty else { return nil }
                return Negative(sourceID: pair.key.sourceID, recordType: pair.key.recordType,
                                queryCount: proven.count)
            }
            .sorted { ($0.sourceID, $0.recordType.rawValue) < ($1.sourceID, $1.recordType.rawValue) }
    }

    /// One clean-zero query whose premise the tree cannot cite — the honest
    /// counterpart to a `Negative`, for the surfaces that would otherwise
    /// report "searched, found nothing" about a question we asked wrong.
    struct AssumedNegative: Equatable {
        let sourceID: String
        let recordType: RecordType
        let queryKey: String
        /// "searched, but the query assumed …, which is unverified".
        let caveat: String
    }

    /// The clean-zero queries excluded from `genuineNegatives` because they
    /// rested on an uncited fact. Deliberately NOT persisted: a durable row
    /// is exactly what the Gladwin marriage search should never have earned.
    /// Same de-duplication and ordering as `genuineNegativeKeys`.
    static func assumedNegatives(
        outcomes: [SearchOutcomeEntry],
        scoredRecords: [ScoredRecord]
    ) -> [AssumedNegative] {
        var out: [AssumedNegative] = []
        var seen: Set<String> = []
        for (key, entries) in cleanPairs(outcomes: outcomes, scoredRecords: scoredRecords) {
            for entry in entries {
                guard let caveat = entry.assumptionCaveat else { continue }
                let dedupKey = "\(key.sourceID)|\(key.recordType.rawValue)|\(entry.queryKey)"
                guard seen.insert(dedupKey).inserted else { continue }
                out.append(AssumedNegative(
                    sourceID: key.sourceID, recordType: key.recordType,
                    queryKey: entry.queryKey, caveat: caveat))
            }
        }
        return out.sorted {
            ($0.sourceID, $0.recordType.rawValue, $0.queryKey)
                < ($1.sourceID, $1.recordType.rawValue, $1.queryKey)
        }
    }

    /// The per-wire-query keys backing the genuine negatives (T1-04
    /// persistent-negative cache). Same pair-veto as `genuineNegatives`
    /// — a queryKey is emitted only when its ENTIRE (source, recordType)
    /// pair was clean-zero with no record in hand — but at the grain the
    /// cross-run reader matches. De-duplicated per (pair, queryKey): the
    /// same wire query may repeat across ladder tiers (loose vs strict
    /// can be distinct keys; strict/variant may collapse), and each
    /// distinct key becomes one durable row.
    ///
    /// A query resting on an unverified premise is skipped (EV7) — see
    /// `assumedNegatives`, which is where those go instead.
    static func genuineNegativeKeys(
        outcomes: [SearchOutcomeEntry],
        scoredRecords: [ScoredRecord]
    ) -> [NegativeKey] {
        var out: [NegativeKey] = []
        var seen: Set<String> = []
        for (key, entries) in cleanPairs(outcomes: outcomes, scoredRecords: scoredRecords) {
            for entry in entries where entry.unverifiedPremise == nil {
                let dedupKey = "\(key.sourceID)|\(key.recordType.rawValue)|\(entry.queryKey)"
                guard seen.insert(dedupKey).inserted else { continue }
                out.append(NegativeKey(
                    sourceID: key.sourceID,
                    recordType: key.recordType,
                    queryKey: entry.queryKey
                ))
            }
        }
        return out.sorted {
            ($0.sourceID, $0.recordType.rawValue, $0.queryKey)
                < ($1.sourceID, $1.recordType.rawValue, $1.queryKey)
        }
    }

    private struct PairKey: Hashable {
        let sourceID: String
        let recordType: RecordType
    }

    /// Shared clean-pair computation for the three aggregators.
    private static func cleanPairs(
        outcomes: [SearchOutcomeEntry],
        scoredRecords: [ScoredRecord]
    ) -> [(key: PairKey, entries: [SearchOutcomeEntry])] {
        var grouped: [PairKey: [SearchOutcomeEntry]] = [:]
        for entry in outcomes {
            grouped[PairKey(sourceID: entry.sourceID, recordType: entry.recordType), default: []].append(entry)
        }
        let recordPairs: Set<PairKey> = Set(scoredRecords.map {
            PairKey(sourceID: $0.record.sourceID, recordType: $0.record.recordType)
        })
        return grouped.compactMap { key, entries in
            guard !recordPairs.contains(key),
                  entries.allSatisfy({ $0.outcome.isCleanNegative })
            else { return nil }
            return (key: key, entries: entries)
        }
    }
}

/// Configuration for a research run.
nonisolated struct ResearchConfig: Sendable {
    let maxIterations: Int
    let maxFacts: Int
    let mode: ResearchMode
    let scope: ResearchScope
    /// Force-refresh escape hatch for the cross-run negative-search cache
    /// (connector-audit T1-04 guard (c)). When true the pipeline ignores
    /// stored clean negatives and re-fires every query on the wire. Set
    /// implicitly for `.verify` (whose whole purpose is to re-check what
    /// is on the tree), and settable per-run by the user. `.extend`,
    /// `.discover`, and `.all` default to consulting the cache.
    let forceRefreshNegatives: Bool

    init(
        maxIterations: Int,
        maxFacts: Int,
        mode: ResearchMode,
        scope: ResearchScope = .county,
        forceRefreshNegatives: Bool? = nil
    ) {
        self.maxIterations = maxIterations
        self.maxFacts = maxFacts
        self.mode = mode
        self.scope = scope
        // `.verify` always re-verifies; other modes consult the cache
        // unless the caller overrides.
        self.forceRefreshNegatives = forceRefreshNegatives ?? (mode == .verify)
    }

    /// The in-app default (SOURCE_WEIGHTING companion): full strictness
    /// ladder walked on-miss, staged dispatch owns geography, stable-point
    /// + budgets own stopping. No verify-style early stop.
    static let adaptive = ResearchConfig(maxIterations: 4, maxFacts: 100, mode: .adaptive)
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
        case .adaptive: return .adaptive
        }
    }

    func with(scope: ResearchScope) -> ResearchConfig {
        ResearchConfig(
            maxIterations: maxIterations, maxFacts: maxFacts, mode: mode,
            scope: scope, forceRefreshNegatives: forceRefreshNegatives
        )
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
    /// Per-(source, query) honesty envelopes (T1-01) from the main
    /// iteration-loop dispatches. Empty on intermediate snapshots,
    /// `.empty`, and legacy results — consumers must treat "no
    /// outcomes" as "envelope unavailable", not "nothing searched"
    /// (see `GPSScorer.searchedSourceIDs`).
    let searchOutcomes: [SearchOutcomeEntry]
    /// Pipeline-generated research hypotheses (V2 spec). Populated
    /// by `HypothesisEngine` after the post-loop phase. T12 completed
    /// the migration: `.siblingExists`, `.parentInferred`, and
    /// `.parentMarriage` hypotheses are the sole sources of truth for
    /// sibling discovery and parent inference — the legacy
    /// `proposedSiblings` and `proposedRelatives` fields that mirrored
    /// them are now deleted. The UI projects through
    /// `ResearchPipeline.projectSiblingExistsToProposals` /
    /// `projectParentInferredToProposal` on demand for accept/reject.
    let hypotheses: [ResearchHypothesis]
    /// Per-run verdicts emitted by `VerdictEmitter` after the
    /// post-loop phase (MCP eval backend #Change2). Each is
    /// one of `"supported" | "contradicted" | "inconclusive"`, or
    /// `nil` for results that were never emitted (intermediate
    /// per-iteration `currentResults` snapshots, the static `.empty`).
    /// Persisted into `research_runs.result_json` (#Change3) and
    /// surfaced over MCP (#Change4).
    let parentLinkVerdict: String?
    let identityVerdict: String?
    let spouseVerdict: String?

    /// Record ids the run tagged as hypothesis-enrichment (excluded from
    /// candidate-life clustering). Threaded from `state.enrichmentRecordIDs`
    /// so persistence can flag the rows and a DB re-cluster can apply the
    /// same exclusion (Campaign review Change 2; the set was previously
    /// memory-only and lost at persist).
    let enrichmentRecordIDs: Set<String>

    /// Per-gate attrition summary across `allScoredRecords` for this
    /// run. Populated on the final result; nil on intermediate
    /// per-iteration snapshots (Engine foundation #Change4).
    let attrition: ScorerAttrition?

    /// Count of subject-self-narrowing proposals (slice B) written
    /// to `pending_facts` this run. Surfaced by the
    /// `ResearchProgressSheet` footer so the user notices new
    /// narrowing proposals waiting in Triage. Per spec.
    let consensusProposalCount: Int

    init(
        confirmedFacts: [ScoredRecord],
        leads: [ScoredRecord],
        allScoredRecords: [ScoredRecord],
        clusters: [LifeCluster],
        discrepancies: [ResearchDiscrepancy],
        householdMembers: [HouseholdMember],
        searchHistory: [SearchAttempt],
        searchOutcomes: [SearchOutcomeEntry] = [],
        hypotheses: [ResearchHypothesis] = [],
        parentLinkVerdict: String? = nil,
        identityVerdict: String? = nil,
        spouseVerdict: String? = nil,
        attrition: ScorerAttrition? = nil,
        consensusProposalCount: Int = 0,
        enrichmentRecordIDs: Set<String> = []
    ) {
        self.confirmedFacts = confirmedFacts
        self.leads = leads
        self.allScoredRecords = allScoredRecords
        self.clusters = clusters
        self.discrepancies = discrepancies
        self.householdMembers = householdMembers
        self.searchHistory = searchHistory
        self.searchOutcomes = searchOutcomes
        self.hypotheses = hypotheses
        self.parentLinkVerdict = parentLinkVerdict
        self.identityVerdict = identityVerdict
        self.spouseVerdict = spouseVerdict
        self.attrition = attrition
        self.consensusProposalCount = consensusProposalCount
        self.enrichmentRecordIDs = enrichmentRecordIDs
    }

    static let empty = ResearchResult(
        confirmedFacts: [], leads: [], allScoredRecords: [],
        clusters: [], discrepancies: [], householdMembers: [], searchHistory: []
    )

    /// A copy with `record` swapped in everywhere its source-record id appears
    /// — clusters, confirmed facts, leads, allScoredRecords. Verdict, gates and
    /// summary are kept; only the record payload changes. Used by the on-demand
    /// census household fetch: the fetch enriches the PERSISTED evidence, but
    /// the review renders this in-memory result, so without the swap the
    /// fetched roster never appears on screen (owner report 2026-08-06 — the
    /// "Load household from FreeCen" button seemed to do nothing).
    func replacingRecord(_ record: SourceRecord) -> ResearchResult {
        func swap(_ scored: ScoredRecord) -> ScoredRecord {
            guard scored.record.id == record.id else { return scored }
            return ScoredRecord(id: scored.id, record: record,
                                verdict: scored.verdict, gates: scored.gates, summary: scored.summary)
        }
        var newClusters = clusters
        for i in newClusters.indices {
            newClusters[i].records = newClusters[i].records.map(swap)
        }
        return ResearchResult(
            confirmedFacts: confirmedFacts.map(swap),
            leads: leads.map(swap),
            allScoredRecords: allScoredRecords.map(swap),
            clusters: newClusters,
            discrepancies: discrepancies,
            householdMembers: householdMembers,
            searchHistory: searchHistory,
            searchOutcomes: searchOutcomes,
            hypotheses: hypotheses,
            parentLinkVerdict: parentLinkVerdict,
            identityVerdict: identityVerdict,
            spouseVerdict: spouseVerdict,
            attrition: attrition,
            consensusProposalCount: consensusProposalCount,
            enrichmentRecordIDs: enrichmentRecordIDs
        )
    }
}
