import Foundation
import os

/// Deterministic-probabilistic-deterministic research pipeline.
/// Per iteration: dispatch → score → detect discrepancies → refine subject.
/// Between iterations: optional reasoning model suggests next search direction.
/// When the model and deterministic engine disagree, deterministic wins.
@MainActor
final class ResearchPipeline {
    let dispatcher: SearchDispatcher
    let snapshot: FamilyGraphSnapshot
    let sourceInfoMap: [String: SourceInfo]

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Pipeline")

    init(dispatcher: SearchDispatcher, snapshot: FamilyGraphSnapshot, sourceInfoMap: [String: SourceInfo]) {
        self.dispatcher = dispatcher
        self.snapshot = snapshot
        self.sourceInfoMap = sourceInfoMap
    }

    /// Run the research pipeline for a subject.
    func research(subject: ResearchSubject, config: ResearchConfig) async -> ResearchResult {
        var state = ResearchState(subject: subject)

        for iteration in 1...config.maxIterations {
            state.iteration = iteration

            // Check cancellation between iterations
            if Task.isCancelled { break }

            logger.info("Pipeline iteration \(iteration)/\(config.maxIterations) for \(subject.displayName)")

            // DETERMINISTIC: dispatch and score
            let records = await dispatcher.dispatch(
                subject: state.subject,
                recordTypes: state.activeRecordTypes
            )

            let scored = records.map { record in
                RecordScorer.classify(
                    record: record,
                    subject: state.subject,
                    searchType: record.recordType
                )
            }

            state.scoredRecords.append(contentsOf: scored)

            // Track search history
            let searchKey = "\(iteration)_\(state.activeRecordTypes.map(\.rawValue).sorted().joined(separator: ","))"
            state.searchHistory.append(SearchAttempt(
                sourceID: "all",
                recordType: .birth,  // placeholder — multi-type search
                searchKey: searchKey,
                resultCount: records.count,
                timestamp: Date()
            ))

            // DETERMINISTIC: extract household members from census results
            extractHouseholdMembers(from: scored, into: &state)

            // DETERMINISTIC: detect discrepancies between new records and existing tree
            let discrepancies = detectDiscrepancies(scored: scored, subject: state.subject)
            state.discrepancies.append(contentsOf: discrepancies)

            // DETERMINISTIC: refine subject from confirmed facts (learned date propagation)
            state.subject = refineSubject(state.subject, from: state.confirmedFacts)

            // PROBABILISTIC: optional reasoning model suggests next search direction
            // Only between iterations, never rules on specific records
            if iteration < config.maxIterations {
                let availableSources = dispatcher.registry.allSources().map(\.sourceID)
                if let suggestion = await ResearchInterpreter.suggestNextSearch(
                    subject: state.subject,
                    currentResults: ResearchResult(
                        confirmedFacts: state.confirmedFacts, leads: state.leads,
                        allScoredRecords: state.scoredRecords, clusters: [],
                        discrepancies: state.discrepancies,
                        householdMembers: state.householdMembers, searchHistory: state.searchHistory
                    ),
                    availableSources: availableSources
                ) {
                    logger.info("Reasoning model suggests: \(suggestion.sourceID) for \(suggestion.reason)")
                    // Model can suggest record types to prioritise — deterministic dispatch still decides
                    if let suggestedType = suggestion.recordType {
                        state.activeRecordTypes.insert(suggestedType)
                    }
                }
            }

            // STOPPING CONDITIONS
            if state.confirmedFacts.count >= config.maxFacts {
                logger.info("Max facts reached (\(config.maxFacts))")
                break
            }

            // Verify mode: stop early if all known facts corroborated
            if config.mode == .verify && !state.confirmedFacts.isEmpty {
                logger.info("Verify mode: facts found, stopping early")
                break
            }

            // Stable-point detection: if no new records found, stop
            if records.isEmpty {
                logger.info("No new records found, stopping")
                break
            }
        }

        logger.info("Pipeline complete: \(state.confirmedFacts.count) facts, \(state.leads.count) leads, \(state.rejectedRecords.count) rejected")

        // DETERMINISTIC: cluster records into candidate lives
        let clusters = ClusteringEngine.cluster(
            records: state.scoredRecords,
            sourceInfoMap: sourceInfoMap
        )

        logger.info("Clustering: \(clusters.count) clusters — \(clusters.filter { $0.confidence >= .moderate }.count) moderate+")

        return ResearchResult(
            confirmedFacts: state.confirmedFacts,
            leads: state.leads,
            allScoredRecords: state.scoredRecords,
            clusters: clusters,
            discrepancies: state.discrepancies,
            householdMembers: state.householdMembers,
            searchHistory: state.searchHistory
        )
    }

    // MARK: - Discrepancy Detection

    /// Detect discrepancies between new records and the existing tree.
    private func detectDiscrepancies(scored: [ScoredRecord], subject: ResearchSubject) -> [ResearchDiscrepancy] {
        var discrepancies: [ResearchDiscrepancy] = []

        for record in scored where record.verdict == .fact {
            let sourceInfo = sourceInfoMap[record.record.sourceID]

            switch record.record {
            case .birth(let r):
                if let existingYear = subject.birthYearFrom, let recordYear = r.birthYear, existingYear != recordYear {
                    let delta = abs(existingYear - recordYear)
                    let severity = DiscrepancySeverityTable.severity(
                        sourceTier: sourceInfo?.trustTier ?? .community,
                        absDelta: delta, convergence: .singleSource
                    )
                    discrepancies.append(ResearchDiscrepancy(
                        field: "birthYear", existingValue: String(existingYear),
                        sourceValue: String(recordYear), sourceID: record.record.sourceID,
                        severity: severity.severity,
                        reasoning: severity.reasoning
                    ))
                }

            case .death(let r):
                if let existingYear = subject.deathYearFrom, let recordYear = r.deathYear, existingYear != recordYear {
                    let delta = abs(existingYear - recordYear)
                    let severity = DiscrepancySeverityTable.severity(
                        sourceTier: sourceInfo?.trustTier ?? .community,
                        absDelta: delta, convergence: .singleSource
                    )
                    discrepancies.append(ResearchDiscrepancy(
                        field: "deathYear", existingValue: String(existingYear),
                        sourceValue: String(recordYear), sourceID: record.record.sourceID,
                        severity: severity.severity,
                        reasoning: severity.reasoning
                    ))
                }

            default:
                break
            }
        }

        return discrepancies
    }

    // MARK: - Learned Date Propagation

    private func refineSubject(_ subject: ResearchSubject, from facts: [ScoredRecord]) -> ResearchSubject {
        var refined = subject
        for fact in facts {
            switch fact.record {
            case .birth(let r):
                if let year = r.birthYear {
                    refined = refined.refined(withBirthYear: year)
                }
            case .death(let r):
                if let year = r.deathYear {
                    refined = refined.refined(withDeathYear: year)
                }
            case .census(let r):
                // Census-derived birth year
                if let age = r.age {
                    let impliedBirth = r.censusYear - age
                    if refined.birthYearFrom == nil {
                        refined = refined.refined(withBirthYear: impliedBirth)
                    }
                }
            default:
                break
            }
        }
        return refined
    }

    // MARK: - Household Extraction

    private func extractHouseholdMembers(from scored: [ScoredRecord], into state: inout ResearchState) {
        for record in scored where record.verdict == .fact {
            if case .census(let census) = record.record, let household = census.household {
                for member in household {
                    // Skip the subject themselves
                    let subjectName = state.subject.displayName.uppercased()
                    if member.name.uppercased() == subjectName { continue }

                    // Deduplicate by uppercase name
                    if state.householdMembers.contains(where: { $0.name.uppercased() == member.name.uppercased() }) {
                        continue
                    }

                    state.householdMembers.append(member)
                }
            }
        }
    }
}

// MARK: - SourceRecord convenience

extension SourceRecord {
    var recordType: RecordType {
        switch self {
        case .birth: .birth
        case .death: .death
        case .marriage: .marriage
        case .census: .census
        case .burial: .burial
        case .military: .death  // military records are death records for scoring
        case .probate: .probate
        case .parish: .parish
        case .pedigree: .pedigree
        }
    }
}
