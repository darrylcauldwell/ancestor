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

    /// Q2 Option B fallback (RESEARCH_PIPELINE_SPEC §5.14.1 clause 5).
    /// Optional lookup that returns a child profile's MMN sourced from
    /// the child's persisted research records when the child's
    /// `Profile.mothersMaidenName` field is empty. Pipeline call sites
    /// that have database access pass a closure wrapping
    /// `ProjectDatabase.loadEvidenceForProfile(_:)`. Nil means
    /// "profile-field-only" — slice 1 still functions, just doesn't
    /// catch the "researched but not accepted" gap.
    let childEvidenceMMNLookup: ((String) -> String?)?

    /// Firewall-respecting pending-fact writer (§5.14.5). Nil means no
    /// persistence — `state.subject.givenName` still mutates in memory
    /// so the iteration loop sees the rich subject for this run, but
    /// nothing reaches the user's pending-facts queue. Pipeline call
    /// sites with database access pass a closure wrapping
    /// `ProjectDatabase.savePendingFact(_:)`.
    let pendingFactWriter: ((PendingFact) -> Void)?

    /// Per-profile record-rejection lookup. The closure returns the set
    /// of `SourceRecord.id`s the user has discarded for a given
    /// profileID — drawn from `record_rejections` and from
    /// `evidence_records.user_status='discarded'`
    /// (see `ProjectDatabase.loadRejections`). Slice B's consensus
    /// detector consults this set so a user's "this isn't my person"
    /// gesture sticks across research runs.
    let rejectionLookup: ((String) -> Set<String>)?

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Pipeline")

    init(
        dispatcher: SearchDispatcher,
        snapshot: FamilyGraphSnapshot,
        sourceInfoMap: [String: SourceInfo],
        childEvidenceMMNLookup: ((String) -> String?)? = nil,
        pendingFactWriter: ((PendingFact) -> Void)? = nil,
        rejectionLookup: ((String) -> Set<String>)? = nil
    ) {
        self.dispatcher = dispatcher
        self.snapshot = snapshot
        self.sourceInfoMap = sourceInfoMap
        self.childEvidenceMMNLookup = childEvidenceMMNLookup
        self.pendingFactWriter = pendingFactWriter
        self.rejectionLookup = rejectionLookup
    }

    /// Build a `childEvidenceMMNLookup` closure backed by
    /// `ProjectDatabase.loadEvidenceForProfile(_:)`. Returns nil when
    /// the database is nil so call sites don't have to handle the
    /// optional themselves. The closure itself is defensive — load
    /// failures fall through to `nil`, never throw.
    static func makeChildEvidenceMMNLookup(database: ProjectDatabase?) -> ((String) -> String?)? {
        guard let database else { return nil }
        return { childProfileID in
            guard let evidence = try? database.loadEvidenceForProfile(childProfileID) else { return nil }
            for ev in evidence where ev.verdict != .impossible {
                if case .birth(let birth) = ev.record,
                   let mmn = birth.mothersMaidenName?
                        .trimmingCharacters(in: .whitespaces),
                   !mmn.isEmpty {
                    return mmn
                }
            }
            return nil
        }
    }

    /// Build a `pendingFactWriter` closure backed by
    /// `ProjectDatabase.savePendingFact(_:)`. The closure is defensive —
    /// save failures are logged at the call site, never thrown out of
    /// the pipeline (`runSubjectSpouseMarriageFlow` swallows + logs).
    static func makePendingFactWriter(database: ProjectDatabase?) -> ((PendingFact) -> Void)? {
        guard let database else { return nil }
        let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Pipeline.PendingFacts")
        return { fact in
            do {
                try database.savePendingFact(fact)
            } catch {
                logger.error("Failed to save pending fact \(fact.id): \(error.localizedDescription)")
            }
        }
    }

    /// Build a `rejectionLookup` closure backed by
    /// `ProjectDatabase.loadRejections(profileID:)`. Read-only — load
    /// failures fall through to an empty set so the pipeline keeps
    /// running even when rejection state can't be fetched.
    static func makeRejectionLookup(database: ProjectDatabase?) -> ((String) -> Set<String>)? {
        guard let database else { return nil }
        return { profileID in
            (try? database.loadRejections(profileID: profileID)) ?? []
        }
    }

    /// Run the research pipeline for a subject.
    func research(subject: ResearchSubject, config: ResearchConfig) async -> ResearchResult {
        var state = ResearchState(subject: subject)
        // Per-run query cache. Lives for the duration of this profile's
        // pipeline only — discarded when this function returns so cross-
        // profile pollution is impossible. Eliminates the 4× redundancy
        // of re-issuing identical district queries in each iteration.
        let queryCache = QueryCache()

        // Pre-iteration phase (RESEARCH_PIPELINE_SPEC §5.14). For thin
        // placeholder subjects (surname only, no given name, ≥1 linked
        // child with usable MMN anchor), probe the marriage index to
        // recover the given name *before* the iteration loop runs —
        // refining the subject after the loop would be too late.
        let preIterationHypotheses = await runSubjectSpouseMarriageFlow(
            state: &state, scope: config.scope, cache: queryCache
        )

        // Storm-guard (§5.14.2). When the pre-iteration probe ran and
        // left the subject thin (no name recovered — match was ambiguous,
        // no match found, or gender unresolved), running the iteration
        // loop would fan out surname-only queries across 8 record types
        // × N districts and hammer FreeBMD for ~zero useful evidence.
        // Skip the iteration loop AND the post-loop hypothesis flows;
        // return just the .subjectSpouseMarriage row plus the marriage
        // records the probe already collected. The Triage banner
        // surfaces the next step to the user.
        let subjectStillThin: Bool = {
            // Storm-guard only fires when pre-iteration actually ran.
            guard !preIterationHypotheses.isEmpty else { return false }
            let trimmed = (state.subject.givenName ?? "")
                .trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty
        }()
        if subjectStillThin {
            logger.info("Storm-guard: subject remains thin after pre-iteration probe — skipping iteration loop and post-loop phase for \(subject.displayName)")
            return ResearchResult(
                confirmedFacts: state.confirmedFacts,
                leads: state.leads,
                allScoredRecords: state.scoredRecords,
                clusters: [],
                discrepancies: state.discrepancies,
                householdMembers: state.householdMembers,
                searchHistory: state.searchHistory,
                hypotheses: preIterationHypotheses
            )
        }

        for iteration in 1...config.maxIterations {
            state.iteration = iteration

            // Check cancellation between iterations
            if Task.isCancelled { break }

            logger.notice("Pipeline iteration \(iteration)/\(config.maxIterations) for \(subject.displayName)")

            // DETERMINISTIC: dispatch and score
            let dispatchedRecords = await dispatcher.dispatch(
                subject: state.subject,
                recordTypes: state.activeRecordTypes,
                scope: config.scope,
                mode: state.subject.mode,
                cache: queryCache
            )

            // Capture prior record IDs before append, so the stopping check
            // below can detect a "stable point" — an iteration that returned
            // only records we've already collected. Without this we'd keep
            // hammering the same dispatch through iterations 2-4 even when
            // nothing new is being found.
            let priorRecordIDs = Set(state.scoredRecords.map(\.record.id))

            // Cross-source enrichment: when FamilySearch's aggregator
            // surfaces a Find a Grave memorial without the inscribed dates,
            // schedule a follow-up FAG detail fetch so the inscription /
            // bio mining can recover the death year. Spec §22.
            let records = await enrichFagBridge(
                dispatchedRecords,
                existingIDs: priorRecordIDs
            )

            // Same-page-couple pairing: pre-Sep-1912 FreeBMD marriage entries
            // don't carry the spouse-surname column, so a subject-side marriage
            // hit at vol 7b/page 1397 lands with `spouseName=nil`. The other
            // half of the marriage is registered on the same (vol, page) under
            // the spouse's surname — fetching that side and pairing on the
            // reference tuple recovers the partner surname. Runs before scoring
            // so the family-context gate can read the recovered partner.
            let pairedRecords = await annotateMarriagesWithSamePagePartner(
                records,
                subject: state.subject,
                scope: config.scope,
                cache: queryCache
            )

            let scored = pairedRecords.map { record in
                RecordScorer.classify(
                    record: record,
                    subject: state.subject,
                    searchType: record.recordType
                )
            }

            // Dedup before appending. Across iterations the dispatcher often
            // re-fetches the same records — especially in narrow scopes where
            // the candidate set is small. Without this filter each iteration
            // adds another copy of every re-found record, so a 2-iteration
            // run shows every record twice in cluster review (T29.x bug —
            // confirmed against the David × Holmes 1969 BELPER record which
            // appeared twice in evidence_records before this guard).
            // The stable-point detection below catches the "nothing new" case
            // to break the loop, but only AFTER append has already duplicated.
            let newScored = scored.filter { !priorRecordIDs.contains($0.record.id) }
            state.scoredRecords.append(contentsOf: newScored)
            let newRecordCount = newScored.count

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

            // DETERMINISTIC: birth-year consensus detection (Slice A). Logs
            // when scored records cluster on a single year for a subject
            // whose existing window is wide — closes the chicken-and-egg
            // loop where no single record gets promoted to `.fact` but the
            // *consensus* across records is itself strong evidence.
            // Logging-only for now; slice B will surface this as a one-click
            // profile-update proposal.
            // Resolve user-discarded record IDs for this profile so the
            // detector can honor them per spec §3.6. Empty set when the
            // subject isn't a profile (lead-only runs) or no lookup is
            // installed — keeping the previous behaviour for those paths.
            let rejectedIDs: Set<String> = {
                guard let profileID = state.subject.profileID,
                      let lookup = rejectionLookup
                else { return [] }
                return lookup(profileID)
            }()
            if let consensus = BirthYearConsensusDetector.detect(
                in: state.scoredRecords,
                for: state.subject,
                rejectedRecordIDs: rejectedIDs
            ) {
                let labels = consensus.supportingEvidence
                    .map { "\($0.typeLabel) (\($0.sourceID))" }
                    .joined(separator: ", ")
                logger.notice("Birth-year consensus: \(consensus.proposedBirthYear) [\(consensus.confidence.rawValue)] — \(consensus.agreeingRecordCount) records, \(consensus.distinctSourceCount) sources: \(labels)")

                // Slice B2 — surface as a pending fact so the user
                // reviews it on the same audit path as MCP-submitted
                // evidence. Only fires once per profile (idempotency
                // key is field+value+profileID-derived). Skipped when
                // the subject isn't a profile (lead-only research
                // runs) or the writer isn't installed (read-only
                // research mode).
                if let writer = pendingFactWriter,
                   let profileID = state.subject.profileID {
                    let fact = consensus.toPendingFact(profileID: profileID)
                    writer(fact)
                    state.consensusProposalCount += 1
                }
            }

            // Parent inference + marriage enrichment now run post-loop
            // via `runParentHypothesisFlow` (V2 spec §5.2 T12-parent
            // Phase 2). They were here in the iteration loop until the
            // framework path took over as the source of truth.

            // PROBABILISTIC: optional reasoning model suggests next search direction
            // Only between iterations, never rules on specific records
            if iteration < config.maxIterations {
                let availableSources = dispatcher.registry.allSources().map(\.sourceID)
                let currentResults = ResearchResult(
                    confirmedFacts: state.confirmedFacts, leads: state.leads,
                    allScoredRecords: state.scoredRecords, clusters: [],
                    discrepancies: state.discrepancies,
                    householdMembers: state.householdMembers, searchHistory: state.searchHistory
                )

                // Level 1 — record-type hint (existing).
                if let suggestion = await ResearchInterpreter.suggestNextSearch(
                    subject: state.subject,
                    currentResults: currentResults,
                    availableSources: availableSources
                ) {
                    logger.info("Reasoning model suggests: \(suggestion.sourceID) for \(suggestion.reason)")
                    if let suggestedType = suggestion.recordType {
                        state.activeRecordTypes.insert(suggestedType)
                    }
                }

                // Slice 13c — Level 2 query strategist. When this
                // iteration produced few/no facts, ask the model for
                // ONE targeted next query and dispatch it as a one-off
                // (separate from the next iteration's fan-out). The
                // dispatcher.dispatchOne path runs the query directly,
                // bypassing the strictness ladder and per-source query
                // builders. Results feed into state.scoredRecords like
                // any other dispatch, so subsequent iterations see the
                // new evidence. The strategist's `rationale` is logged
                // to `searchHistory` for audit.
                //
                // Only fire when the iteration was unproductive — a
                // productive iteration (many new facts, narrowed birth
                // window) is the deterministic engine already doing
                // what it should. The MLX cost (a few seconds per
                // model call) is best spent breaking through ruts.
                let iterationWasUnproductive = newRecordCount == 0
                    || state.confirmedFacts.isEmpty
                if iterationWasUnproductive {
                    // Publish a `sourceQueryStarted` for the synthetic
                    // "Level-2 Strategist" card so the user can see when
                    // the AI is thinking. Paired with a Completed below.
                    await ResearchActivityBus.shared.publish(
                        .sourceQueryStarted(
                            sourceID: "mlx-strategist",
                            summary: "Level-2 strategist · iter \(iteration)"
                        )
                    )
                    let searched = state.searchHistory.map(\.searchKey)
                    var strategistResultCount = 0
                    var strategistSummary = "Level-2 strategist · no suggestion"
                    if let focused = await ResearchInterpreter.suggestNextFocusedQuery(
                        subject: state.subject,
                        results: currentResults,
                        household: state.householdMembers,
                        searched: searched,
                        availableSources: availableSources
                    ) {
                        logger.notice("Level-2 focused query: \(focused.sourceID)/\(focused.recordType.rawValue) — \(focused.rationale)")
                        let extra = await dispatcher.dispatchOne(focused: focused, cache: queryCache)
                        strategistSummary = "Level-2: \(focused.rationale)"
                        if !extra.isEmpty {
                            let extraScored = extra.map { record in
                                RecordScorer.classify(
                                    record: record,
                                    subject: state.subject,
                                    searchType: record.recordType
                                )
                            }
                            let nowPriorIDs = Set(state.scoredRecords.map(\.record.id))
                            let newExtras = extraScored.filter { !nowPriorIDs.contains($0.record.id) }
                            state.scoredRecords.append(contentsOf: newExtras)
                            state.searchHistory.append(SearchAttempt(
                                sourceID: focused.sourceID,
                                recordType: focused.recordType,
                                searchKey: "focused_\(focused.sourceID)_\(focused.recordType.rawValue)_\(focused.rationale.prefix(40))",
                                resultCount: newExtras.count,
                                timestamp: Date()
                            ))
                            strategistResultCount = newExtras.count
                            // Re-run subject refinement so any new facts
                            // narrow the window for the next iteration.
                            state.subject = refineSubject(state.subject, from: state.confirmedFacts)
                        }
                    }
                    await ResearchActivityBus.shared.publish(
                        .sourceQueryCompleted(
                            sourceID: "mlx-strategist",
                            summary: strategistSummary,
                            resultCount: strategistResultCount
                        )
                    )
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

            // Stable-point detection: stop if (a) the dispatcher returned
            // nothing OR (b) every record was already collected in a prior
            // iteration. Subject refinement only narrows the search; an
            // iteration that re-fetches the same records will keep doing so
            // through the remaining iterations. Bail out and save the
            // queries — measured ~53% of FreeBMD requests on a typical
            // extend run come from these redundant iterations.
            if records.isEmpty {
                logger.info("No records returned, stopping")
                break
            }
            if iteration > 1 && newRecordCount == 0 {
                logger.notice("Stable point: iteration \(iteration) re-fetched \(records.count) records, none new — stopping")
                break
            }
        }

        // Post-iteration spouse-surname expansion. Mirrors Python's
        // agent/pipeline.py:_expand_post_marriage_searches. The
        // construction-time derivation in `ResearchSubject.fromProfile`
        // catches the linked-spouse case; this catches everything
        // else — a confirmed marriage record naming a spouse surname
        // we haven't searched yet (un-linked subject, or married
        // multiple times). For each new surname, re-dispatch the
        // death-shape record types so the pipeline finds the
        // subject's records filed under that married name.
        if state.subject.gender == .female {
            let knownSurnames: Set<String> = Set(
                [state.subject.surname, state.subject.marriedSurname]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            )
            let discoveredSurnames = Self.extractSpouseSurnames(from: state.confirmedFacts)
            let pivotSurnames = discoveredSurnames.filter {
                !knownSurnames.contains($0.lowercased())
            }

            if !pivotSurnames.isEmpty {
                logger.info("Post-marriage pivot: re-searching death-shape records for spouse surnames \(pivotSurnames.sorted())")
            }

            for newSurname in pivotSurnames.sorted() {
                if Task.isCancelled { break }
                var pivotSubject = state.subject
                pivotSubject.marriedSurname = newSurname
                let pivotRecords = await dispatcher.dispatch(
                    subject: pivotSubject,
                    recordTypes: [.death, .burial, .probate, .military],
                    scope: config.scope,
                    mode: state.subject.mode,
                    cache: queryCache
                )
                let priorIDs = Set(state.scoredRecords.map(\.record.id))
                let scored = pivotRecords.map { rec in
                    RecordScorer.classify(record: rec, subject: pivotSubject, searchType: rec.recordType)
                }
                let new = scored.filter { !priorIDs.contains($0.record.id) }
                state.scoredRecords.append(contentsOf: new)
                state.searchHistory.append(SearchAttempt(
                    sourceID: "post-marriage-pivot",
                    recordType: .death,
                    searchKey: "post-marriage:\(newSurname)",
                    resultCount: pivotRecords.count,
                    timestamp: Date()
                ))
            }
        }

        // Post-iteration: mother-in-law maiden-name pivot. When a
        // census household carries a mother-in-law under her own
        // surname, that surname IS the wife's maiden name — a
        // signal that's separate from the linked-spouse-father
        // derivation. Useful when the wife's father isn't a tree
        // profile. Mirrors `agent/analyser.py:_check_maiden_names`.
        // Only fires when the discovered surname is genuinely new
        // (differs from any spouseFatherSurname already set on
        // FamilyContext).
        if let headSurname = state.subject.surname {
            let derivedMaiden = Self.maidenNameFromMotherInLaw(
                household: state.householdMembers,
                headSurname: headSurname
            )
            let existing = (state.subject.familyContext?.spouseFatherSurname ?? "")
                .trimmingCharacters(in: .whitespaces).uppercased()
            if let maiden = derivedMaiden, maiden.uppercased() != existing {
                logger.info("Mother-in-law maiden pivot: re-probing marriage records with spouseFatherSurname=\(maiden)")
                var pivotSubject = state.subject
                if var ctx = pivotSubject.familyContext {
                    ctx = FamilyContext(
                        spouseName: ctx.spouseName,
                        spouseSurname: ctx.spouseSurname,
                        spouseGivenName: ctx.spouseGivenName,
                        spouseFatherSurname: maiden,
                        childNames: ctx.childNames,
                        fatherName: ctx.fatherName,
                        fatherSurname: ctx.fatherSurname,
                        fatherGivenName: ctx.fatherGivenName,
                        motherName: ctx.motherName,
                        motherSurname: ctx.motherSurname,
                        motherGivenName: ctx.motherGivenName
                    )
                    pivotSubject.familyContext = ctx
                }
                if !Task.isCancelled {
                    let pivotRecords = await dispatcher.dispatch(
                        subject: pivotSubject,
                        recordTypes: [.marriage],
                        scope: config.scope,
                        mode: state.subject.mode,
                        cache: queryCache
                    )
                    let priorIDs = Set(state.scoredRecords.map(\.record.id))
                    let scored = pivotRecords.map { rec in
                        RecordScorer.classify(record: rec, subject: pivotSubject, searchType: rec.recordType)
                    }
                    let new = scored.filter { !priorIDs.contains($0.record.id) }
                    state.scoredRecords.append(contentsOf: new)
                    state.searchHistory.append(SearchAttempt(
                        sourceID: "mother-in-law-pivot",
                        recordType: .marriage,
                        searchKey: "mother-in-law:\(maiden)",
                        resultCount: pivotRecords.count,
                        timestamp: Date()
                    ))
                }
            }
        }

        // Post-iteration: child-gap inference. When the subject is a
        // parent with multiple linked children showing year gaps > 3,
        // probe FreeBMD for deaths under the family surname in the
        // gap years — the classic Victorian-era "missing child died
        // young" pattern. Mirrors
        // `agent/analyser.py:_check_child_gaps`. Family surname is
        // taken from the children themselves (covers female subjects
        // whose own surname is maiden — children carry father's
        // surname). Civil-reg gate: pre-1837 deaths aren't in FreeBMD,
        // skip those gaps.
        if let subjectProfileID = state.subject.profileID {
            let children = snapshot.childrenOf(subjectProfileID)
            let childYears = children.compactMap { $0.birthDate?.earliest }
            let gaps = Self.childBirthYearGaps(childYears, threshold: 3)
            // Pick the most-common surname among children (handles
            // step-siblings with different surnames defensively).
            let childSurnames = children.compactMap { $0.lastName?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let familySurname = Self.mostCommon(childSurnames)
            if let familySurname, !gaps.isEmpty {
                logger.info("Child-gap inference: probing deaths for \(familySurname) in \(gaps.count) gap window(s)")
            }
            for (gapStart, gapEnd) in gaps {
                let yearFrom = gapStart + 1
                let yearTo = gapEnd - 1
                // Civil registration starts 1837 — pre-1837 deaths
                // aren't in FreeBMD. Gaps spanning the cutoff get
                // the in-coverage portion only.
                guard yearTo >= 1837, let familySurname else { continue }
                let effectiveFrom = max(yearFrom, 1837)
                if Task.isCancelled { break }

                var gapSubject = state.subject
                gapSubject.surname = familySurname
                gapSubject.givenName = nil  // Cast wide — any infant in the family
                gapSubject.birthYearFrom = nil
                gapSubject.birthYearTo = nil
                gapSubject.deathYearFrom = effectiveFrom
                gapSubject.deathYearTo = yearTo

                let gapRecords = await dispatcher.dispatch(
                    subject: gapSubject,
                    recordTypes: [.death],
                    scope: config.scope,
                    mode: state.subject.mode,
                    cache: queryCache
                )
                let priorIDs = Set(state.scoredRecords.map(\.record.id))
                let scored = gapRecords.map { rec in
                    RecordScorer.classify(record: rec, subject: gapSubject, searchType: rec.recordType)
                }
                let new = scored.filter { !priorIDs.contains($0.record.id) }
                state.scoredRecords.append(contentsOf: new)
                state.searchHistory.append(SearchAttempt(
                    sourceID: "child-gap-pivot",
                    recordType: .death,
                    searchKey: "child-gap:\(familySurname):\(effectiveFrom)-\(yearTo)",
                    resultCount: gapRecords.count,
                    timestamp: Date()
                ))
            }
        }

        logger.notice("Pipeline complete: \(state.confirmedFacts.count) facts, \(state.leads.count) leads, \(state.rejectedRecords.count) rejected")

        // DETERMINISTIC: biographical-fit reasoning (slice C). Cross-
        // checks candidate birth records against the subject's known
        // life timeline — children's birth years, age-at-death back-
        // calculation, infant-death elimination. Where Python's
        // orchestrator (a human) picked the biographically-consistent
        // candidate from a set of name-matching births, this does the
        // same arithmetic deterministically. Run once post-loop, after
        // all scoring, before clustering — gives the rest of the
        // pipeline a chance to consume the narrowed subject.
        let birthCandidates = state.scoredRecords.filter {
            if case .birth = $0.record { return $0.verdict != .impossible }
            return false
        }
        let deathShapeRecords = state.scoredRecords.filter {
            switch $0.record {
            case .death, .burial, .probate, .military:
                return $0.verdict != .impossible
            default: return false
            }
        }
        if !birthCandidates.isEmpty {
            let fitResults = BiographicalFitEvaluator.evaluate(
                candidates: birthCandidates,
                subject: state.subject,
                deathRecords: deathShapeRecords,
                snapshot: snapshot
            )
            for r in fitResults {
                logger.notice("Biographical fit: \(r.candidate.record.id) birth=\(r.candidateBirthYear) plausibility=\(String(format: "%.2f", r.plausibility)) matches=\(r.corroboratingMatches) — \(r.reasoning)")
            }
            // Pick the strongest-evidenced candidate by *corroborating
            // matches* (rule 2 age-at-death hits), not by "wasn't ruled
            // out". A candidate with 5 matches beats one with 0 matches
            // even if both have plausibility 1.00 — the latter just
            // happens to lack contradicting evidence in this run's
            // record pool. Real-world data often leaves multiple
            // candidates un-eliminated; we need positive evidence to
            // pick between them.
            //
            // Narrow only when:
            //   • the leader has at least `minMatchesToNarrow` (3) hits
            //   • the leader has at least `narrowMargin` (2) more hits
            //     than the runner-up (clear winner, not a near-tie)
            //   • the leader's plausibility is still ≥ 0.4 (anything
            //     this contradicted is suspect)
            let minMatchesToNarrow = 3
            let narrowMargin = 2
            let ranked = fitResults.sorted { $0.corroboratingMatches > $1.corroboratingMatches }
            if let leader = ranked.first,
               leader.corroboratingMatches >= minMatchesToNarrow,
               leader.plausibility >= 0.4 {
                let runnerUpMatches = ranked.dropFirst().first?.corroboratingMatches ?? 0
                if leader.corroboratingMatches - runnerUpMatches >= narrowMargin {
                    logger.notice("Biographical fit: narrowing subject to birth ~\(leader.candidateBirthYear) (leader has \(leader.corroboratingMatches) corroborating matches, runner-up has \(runnerUpMatches))")
                    state.subject = state.subject.refined(withBirthYear: leader.candidateBirthYear)
                }
            }
        }

        // DETERMINISTIC: cluster records into candidate lives.
        // Marriage-enrichment records describe the parents' marriage, not a
        // candidate life of the subject — they're surfaced under each parent
        // `ProposedRelative`'s evidence list instead of as standalone cluster
        // cards. Filter them out here so the cluster review doesn't show the
        // parents' marriage as e.g. a "DAVID N CAULDWELL" orphan cluster.
        let clusterInput = state.scoredRecords.filter {
            !state.enrichmentRecordIDs.contains($0.id)
        }
        let clusters = ClusteringEngine.cluster(
            records: clusterInput,
            sourceInfoMap: sourceInfoMap,
            homeChapmanCode: subject.homeChapmanCode
        )

        let confirmed = clusters.filter { $0.matchQuality == .confirmed }.count
        logger.info("Clustering: \(clusters.count) clusters — \(confirmed) with confirmed match quality")

        // DETERMINISTIC: sibling hypothesis flow (V2 spec §5.2,
        // T12-sibling — engine is the sole source of truth as of Phase 4).
        // generate → for each draft, dispatch the level-1 deficit query,
        // append candidates to state (marked for exclusion from
        // clustering) → grade. The UI projects supported hypotheses to
        // `SiblingProposal` on demand via
        // `ResearchViewModel.visibleSiblings(snapshot:)`.
        let siblingHypotheses = await runSiblingHypothesisFlow(state: &state)

        // DETERMINISTIC: parent hypothesis flow (V2 spec §5.2,
        // T12-parent — engine is the sole source of truth as of
        // Phase 2). Generates `.parentInferred` + `.parentMarriage`,
        // fans out marriage queries across `config.scope`, grades,
        // and reconciles marriage evidence onto the parent rows.
        let parentHypotheses = await runParentHypothesisFlow(
            state: &state, scope: config.scope, cache: queryCache
        )
        let firstPassHypotheses = preIterationHypotheses + siblingHypotheses + parentHypotheses

        // T7 second pass (V2 spec §5.3). At most once per research()
        // call; only fires when there's at least one inconclusive
        // hypothesis whose per-kind ladder has headroom. Right now
        // that's principally `.parentMarriage` rows whose first-pass
        // window came back empty/ambiguous — level-1 retry widens the
        // window by ±10 years.
        let allHypotheses = await runSecondPass(
            state: &state, hypotheses: firstPassHypotheses, scope: config.scope
        )

        // Re-cluster if the second pass appended records that weren't
        // tagged as enrichment-only. In current configuration every
        // second-pass record is tagged (it's evidence for a specific
        // hypothesis, not a candidate life), so the cluster set is
        // unchanged — but recompute defensively so future ladder
        // levels that add un-tagged candidates surface correctly.
        let postSecondPassClusterInput = state.scoredRecords.filter {
            !state.enrichmentRecordIDs.contains($0.id)
        }
        let finalClusters: [LifeCluster]
        if postSecondPassClusterInput.count != clusterInput.count {
            finalClusters = ClusteringEngine.cluster(
                records: postSecondPassClusterInput,
                sourceInfoMap: sourceInfoMap,
                homeChapmanCode: subject.homeChapmanCode
            )
            logger.info("Post-second-pass re-clustering: \(finalClusters.count) clusters (was \(clusters.count))")
        } else {
            finalClusters = clusters
        }

        let cacheStats = await queryCache.stats()
        let total = cacheStats.hits + cacheStats.misses
        let hitRate = total > 0 ? Double(cacheStats.hits) / Double(total) : 0
        logger.info("QueryCache for \(subject.displayName): \(cacheStats.hits) hits / \(cacheStats.misses) misses (\(Int(hitRate * 100))%), \(cacheStats.entries) entries")

        // SWIFT_MCP_EVAL_BACKEND_SPEC #Change3 — emit the three per-run
        // verdicts after clustering / hypothesis flows have settled, so
        // they see the final clusters and confirmedFacts. Verdicts
        // depend only on the result + snapshot + subject identity.
        let preliminaryResult = ResearchResult(
            confirmedFacts: state.confirmedFacts,
            leads: state.leads,
            allScoredRecords: state.scoredRecords,
            clusters: finalClusters,
            discrepancies: state.discrepancies,
            householdMembers: state.householdMembers,
            searchHistory: state.searchHistory,
            hypotheses: allHypotheses
        )
        let parentLink = VerdictEmitter.parentLinkVerdict(
            result: preliminaryResult,
            snapshot: snapshot,
            subjectProfileID: subject.profileID
        )
        let identity = VerdictEmitter.identityVerdict(result: preliminaryResult)
        let spouse = VerdictEmitter.spouseVerdict(
            result: preliminaryResult,
            snapshot: snapshot,
            subjectProfileID: subject.profileID
        )

        // ENGINE_FOUNDATION_SPEC #Change4: attrition summary across
        // this run's scored records + bus publish so the activity
        // feed shows "the brake is engaged" (rich subject, high
        // attrition) vs "everything passed" (thin subject, the
        // verdict-cap from #Change1 doing the work).
        let attrition = ScorerAttrition.from(state.scoredRecords)
        await ResearchActivityBus.shared.publish(.scorerAttrition(attrition))

        return ResearchResult(
            confirmedFacts: state.confirmedFacts,
            leads: state.leads,
            allScoredRecords: state.scoredRecords,
            clusters: finalClusters,
            discrepancies: state.discrepancies,
            householdMembers: state.householdMembers,
            searchHistory: state.searchHistory,
            hypotheses: allHypotheses,
            parentLinkVerdict: parentLink,
            identityVerdict: identity,
            spouseVerdict: spouse,
            attrition: attrition,
            consensusProposalCount: state.consensusProposalCount
        )
    }

    // MARK: - Subject-Spouse Marriage Flow (V2 spec §5.14 — pre-iteration)

    /// Run the `.subjectSpouseMarriage` strategy *before* the iteration
    /// loop (RESEARCH_PIPELINE_SPEC §5.14). For thin placeholder
    /// subjects (no given name) with at least one linked child whose
    /// MMN can be resolved, the marriage index is the right anchor —
    /// not the birth index. A `.unique` match recovers the subject's
    /// given name; slice 1 emits the hypothesis row only (write-back is
    /// slice 2).
    ///
    ///   1. Resolve each linked child's MMN (profile field first; if
    ///      empty AND `childEvidenceMMNLookup` is configured, fall
    ///      back to the child's persisted research records — Q2 Option B).
    ///   2. Generate one `.subjectSpouseMarriage` per distinct uppercased
    ///      MMN across the children (Q3+Q4 — same-MMN children collapse,
    ///      different-MMN children seed separate hypotheses including
    ///      the remarriage / step-children cases).
    ///   3. For each draft, fan out groom-side + bride-side FreeBMD
    ///      marriage queries across the scope's districts (mirrors
    ///      `.parentMarriage` dispatch).
    ///   4. Grade each draft — `.supported` / `.inconclusive` /
    ///      `.contradicted` per §5.14.4 outcomes.
    private func runSubjectSpouseMarriageFlow(
        state: inout ResearchState,
        scope: ResearchScope,
        cache: QueryCache? = nil
    ) async -> [ResearchHypothesis] {
        // Early bail: cheap predicate so the common rich-subject case
        // pays zero cost. Full trigger predicate lives in the generator.
        guard let subjectID = state.subject.profileID else { return [] }
        let trimmedGiven = (state.subject.givenName ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmedGiven.isEmpty else { return [] }
        guard let surname = state.subject.surname?.trimmingCharacters(in: .whitespaces),
              !surname.isEmpty else { return [] }
        let children = snapshot.childrenOf(subjectID)
        guard !children.isEmpty else { return [] }

        // Resolve per-child MMN via the Q2 Option B fallback. Only
        // populate the map for children whose profile MMN is empty —
        // the generator reads the profile field directly first and
        // falls back to this map.
        var childMMNs: [String: String] = [:]
        if let lookup = childEvidenceMMNLookup {
            for child in children {
                let profileMMN = child.mothersMaidenName?
                    .trimmingCharacters(in: .whitespaces)
                if profileMMN?.isEmpty == false { continue }
                if let recovered = lookup(child.id),
                   !recovered.trimmingCharacters(in: .whitespaces).isEmpty {
                    childMMNs[child.id] = recovered
                }
            }
        }

        let drafts = HypothesisEngine.generateSubjectSpouseMarriage(
            state: state, snapshot: snapshot, childMMNs: childMMNs
        )
        guard !drafts.isEmpty else { return [] }
        let subjectDisplay = state.subject.displayName
        logger.info("SubjectSpouseMarriage: \(drafts.count) draft(s) for \(subjectDisplay)")

        // Dispatch level-1 marriage queries for each draft. Two-sided
        // fan-out per pair (one query per district per side); records
        // feed back into state so the grader can read them.
        for draft in drafts {
            guard case .subjectSpouseMarriage(let groomSurname, let brideSurname, let window) = draft.kind else { continue }
            logger.info("SubjectSpouseMarriage dispatch: \(groomSurname) × \(brideSurname), \(window.lowerBound)–\(window.upperBound)")
            async let groomSide = dispatchMarriageQuery(
                surname: groomSurname, spouseSurname: brideSurname,
                yearFrom: window.lowerBound, yearTo: window.upperBound,
                scope: scope, cache: cache
            )
            async let brideSide = dispatchMarriageQuery(
                surname: brideSurname, spouseSurname: groomSurname,
                yearFrom: window.lowerBound, yearTo: window.upperBound,
                scope: scope, cache: cache
            )
            let groomScored = await groomSide
            let brideScored = await brideSide
            let priorIDs = Set(state.scoredRecords.map(\.id))
            let newRecords = (groomScored + brideScored).filter { !priorIDs.contains($0.id) }
            state.scoredRecords.append(contentsOf: newRecords)
            // Marriage records describe the subject's own marriage,
            // not a candidate birth/death record — tag as enrichment so
            // clustering ignores them (same pattern as parentMarriage).
            state.enrichmentRecordIDs.formUnion(newRecords.map(\.id))
        }

        let now = Date()
        let graded = drafts.map { draft in
            Self.finalizeHypothesis(
                draft: draft,
                gradeResult: HypothesisEngine.grade(draft, state: state, snapshot: snapshot),
                at: now
            )
        }

        // Slice 2 write-back (§5.14.5). Cross-hypothesis reconciliation
        // decides whether to mutate state.subject.givenName and emit a
        // pending fact. Runs only when at least one row is
        // `.supported`; the reconciliation handles the Q4 four cases
        // (zero / one / multi-agree / multi-disagree).
        reconcileAndApplyWriteback(
            from: graded, state: &state, subjectID: subjectID
        )

        return graded
    }

    /// Apply the §5.14.4 cross-hypothesis reconciliation: pick the
    /// recovered given name (if any), mutate `state.subject.givenName`
    /// so the iteration loop sees it, and (if a writer is configured)
    /// emit one pending fact citing every contributing marriage. Pure
    /// over inputs except for the two side effects clearly named here.
    /// Returns whether a write-back fired (so the storm-guard knows
    /// whether to short-circuit the iteration loop).
    @discardableResult
    private func reconcileAndApplyWriteback(
        from hypotheses: [ResearchHypothesis],
        state: inout ResearchState,
        subjectID: String
    ) -> Bool {
        // Resolve gender via the §5.14.4 ladder. The ladder is
        // deterministic over snapshot + childMMNs; at this point the
        // child profile fields are baked into the snapshot, so passing
        // `[:]` for childMMNs is the slice-1 default.
        let resolution = HypothesisEngine.resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: [:]
        )

        let decision = HypothesisEngine.reconcileSubjectSpouseWriteback(
            hypotheses: hypotheses,
            scoredRecords: state.scoredRecords,
            resolvedGender: resolution.resolvedGender
        )

        switch decision {
        case .noWriteback(let reason):
            logger.info("SubjectSpouseMarriage: no write-back — \(reason) (\(resolution.reasoningFragment))")
            return false
        case .applyName(let name, let groomLabel, let brideLabel, let citedIDs, let primaryURL, let primaryTitle):
            // Write-back 1: mutate state.subject.givenName so the
            // iteration loop sees a rich subject.
            state.subject.givenName = name
            logger.info("SubjectSpouseMarriage write-back: subject.givenName = '\(name)' (\(resolution.reasoningFragment))")

            // Write-back 2: emit one pending fact citing every
            // contributing marriage. Idempotency via the firewall's
            // standard key — re-running with the same (profile, field,
            // value, URL) is a no-op at the database layer.
            guard let writer = pendingFactWriter else { return true }
            let sourceURL = primaryURL ?? ""
            let sourceTitle = primaryTitle ?? "BMD marriage index"
            let citedSummary = citedIDs.joined(separator: ",")
            let evidenceText = "Subject given name '\(name)' recovered from BMD marriage \(groomLabel) × \(brideLabel)."
            let reasoning = "subjectSpouseMarriage write-back: \(resolution.reasoningFragment); cited marriages [\(citedSummary)]"
            let factID = EvidenceFirewall.idempotencyKey(
                profileID: subjectID, field: "firstName",
                value: name, sourceURL: sourceURL
            )
            let fact = PendingFact(
                id: factID,
                profileID: subjectID,
                field: "firstName",
                value: name,
                sourceURL: sourceURL,
                sourceTitle: sourceTitle,
                evidenceText: String(evidenceText.prefix(200)),
                reasoning: reasoning,
                confidence: "high",
                agentID: "subject-spouse-marriage",
                submittedAt: Date(),
                verificationStatus: .pending
            )
            writer(fact)
            return true
        }
    }

    // MARK: - Parent Hypothesis Flow (V2 spec §5.2 — engine is the
    //         sole source of truth as of Phase 2)

    /// Run the `.parentInferred` + `.parentMarriage` framework path:
    ///   1. generate `.parentInferred` drafts (one per parent surname
    ///      implied by BMD-birth-index records the iteration loop
    ///      collected),
    ///   2. grade each — `.supported` when a fact-or-lead birth record
    ///      attests the surname (mother via MMN, father via subject
    ///      surname),
    ///   3. generate `.parentMarriage` drafts — the generator gates on
    ///      "both parents linked" OR "subject identity resolved" so a
    ///      non-specific subject doesn't fan out marriage queries
    ///      across every MMN (V2 spec §5.2.1),
    ///   4. for each draft, fan out groom-side + bride-side FreeBMD
    ///      marriage queries across the scope's districts, append the
    ///      returned records to `state.scoredRecords` (also added to
    ///      `enrichmentRecordIDs` so any future clustering pass
    ///      excludes them),
    ///   5. grade each `.parentMarriage` draft — `MarriageEnrichmentEngine.match`
    ///      reunites groom-side / bride-side hits at the same reference
    ///      tuple,
    ///   6. reconcile — supported `.parentMarriage` record IDs +
    ///      given-name reasoning cross-reference onto the matching
    ///      `.parentInferred` rows.
    private func runParentHypothesisFlow(
        state: inout ResearchState,
        scope: ResearchScope,
        cache: QueryCache? = nil
    ) async -> [ResearchHypothesis] {
        let parentDrafts = HypothesisEngine.generate(
            for: .parentInferred, state: state, snapshot: snapshot
        )
        let marriageDrafts = HypothesisEngine.generate(
            for: .parentMarriage, state: state, snapshot: snapshot
        )
        if parentDrafts.isEmpty && marriageDrafts.isEmpty { return [] }

        // Grade parent inferreds first — they don't need any further
        // dispatch (state.scoredRecords already carries the BMD birth
        // evidence from the iteration loop).
        let now = Date()
        let parentGraded: [ResearchHypothesis] = parentDrafts.map { draft in
            Self.finalizeHypothesis(
                draft: draft,
                gradeResult: HypothesisEngine.grade(draft, state: state, snapshot: snapshot),
                at: now
            )
        }

        // Dispatch marriage queries for every gated `.parentMarriage`
        // draft. Two-sided fan-out per pair (one query per district per
        // side); records feed back into state so the grader can read
        // them.
        for draft in marriageDrafts {
            guard case .parentMarriage(let motherSurname, let fatherSurname, let window) = draft.kind else { continue }
            logger.info("Parent marriage dispatch: \(fatherSurname) × \(motherSurname), \(window.lowerBound)–\(window.upperBound)")
            async let groomSide = dispatchMarriageQuery(
                surname: fatherSurname, spouseSurname: motherSurname,
                yearFrom: window.lowerBound, yearTo: window.upperBound, scope: scope, cache: cache
            )
            async let brideSide = dispatchMarriageQuery(
                surname: motherSurname, spouseSurname: fatherSurname,
                yearFrom: window.lowerBound, yearTo: window.upperBound, scope: scope, cache: cache
            )
            let groomScored = await groomSide
            let brideScored = await brideSide
            let priorIDs = Set(state.scoredRecords.map(\.id))
            let newRecords = (groomScored + brideScored).filter { !priorIDs.contains($0.id) }
            state.scoredRecords.append(contentsOf: newRecords)
            // Exclusion tag mirrors the sibling-flow pattern — marriage
            // records describe the parents' marriage, not a candidate
            // life of the subject, so clustering should ignore them.
            state.enrichmentRecordIDs.formUnion(newRecords.map(\.id))
        }

        let marriageGraded: [ResearchHypothesis] = marriageDrafts.map { draft in
            Self.finalizeHypothesis(
                draft: draft,
                gradeResult: HypothesisEngine.grade(draft, state: state, snapshot: snapshot),
                at: now
            )
        }

        return HypothesisEngine.reconcileParentMarriages(
            hypotheses: parentGraded + marriageGraded
        )
    }

    /// Wrap a drafted hypothesis + its grade result into a finalised
    /// hypothesis with verdict, evidence, history. Shared between the
    /// sibling and parent flows.
    private static func finalizeHypothesis(
        draft: ResearchHypothesis,
        gradeResult: HypothesisEngine.GradeResult,
        at now: Date
    ) -> ResearchHypothesis {
        ResearchHypothesis(
            id: draft.id,
            subjectProfileID: draft.subjectProfileID,
            kind: draft.kind,
            verdict: gradeResult.verdict,
            isModelAssisted: gradeResult.isModelAssisted,
            supportingEvidence: gradeResult.supportingEvidence,
            contradictingEvidence: gradeResult.contradictingEvidence,
            reasoning: gradeResult.reasoning,
            createdAt: draft.createdAt,
            lastTestedAt: now,
            attempts: 1,
            history: [
                ResearchHypothesis.Transition(
                    verdict: gradeResult.verdict,
                    isModelAssisted: gradeResult.isModelAssisted,
                    at: now,
                    reason: "initial grading"
                )
            ]
        )
    }

    /// Project a `.supported` `.parentInferred` hypothesis to the
    /// `ProposedRelative` shape the UI's accept / reject flow expects.
    /// Mirrors the legacy `ParentInferenceEngine` output (V2 spec §5.2.1).
    ///
    /// Call sites: `ResearchViewModel.visibleProposedRelatives` and
    /// `RunRequestWatcher`'s auto-accept gate. T12-parent Phase 4
    /// removed the pipeline's mirror call; proposals are now computed
    /// on demand at the read site.
    ///
    /// `allHypotheses` lets the helper pull the matching
    /// `.parentMarriage` row's candidates (when verdict is
    /// `.inconclusive` = ambiguous match) into `ambiguousMarriages` so
    /// the UI can render the disambiguation affordance.
    static func projectParentInferredToProposal(
        hypothesis: ResearchHypothesis,
        allHypotheses: [ResearchHypothesis],
        scoredRecords: [ScoredRecord],
        subject: ResearchSubject
    ) -> ProposedRelative? {
        guard hypothesis.isDeterministicallySupported,
              case .parentInferred(let gender, let surname) = hypothesis.kind,
              let subjectID = subject.profileID
        else { return nil }
        let scoredByID = Dictionary(uniqueKeysWithValues: scoredRecords.map { ($0.id, $0) })
        let evidence = hypothesis.supportingEvidence.compactMap { scoredByID[$0] }
        let proposedGivenName = extractParentGivenName(
            gender: gender, surname: surname, from: evidence
        )
        let subjectBirthYear = subject.birthYearFrom
        let parentLow = subjectBirthYear.map { $0 - 45 }
        let parentHigh = subjectBirthYear.map { $0 - 18 }
        let rel = ProposedRelationship.parentOf(subjectID)

        let ambiguousMarriages: [ScoredRecord] = {
            for h in allHypotheses {
                guard h.subjectProfileID == hypothesis.subjectProfileID,
                      case .parentMarriage(let mother, let father, _) = h.kind,
                      h.verdict == .inconclusive
                else { continue }
                let matches: Bool
                switch gender {
                case .female: matches = mother.caseInsensitiveCompare(surname) == .orderedSame
                case .male:   matches = father.caseInsensitiveCompare(surname) == .orderedSame
                case .other, .unknown: matches = false
                }
                guard matches else { continue }
                return h.supportingEvidence.compactMap { scoredByID[$0] }
            }
            return []
        }()

        // Use the first BMD-birth evidence record (typically only one)
        // to name the inference chain — mirrors legacy text.
        let inferredFromSourceID: String = {
            for scored in evidence {
                if case .birth = scored.record { return scored.record.sourceID }
            }
            return "BMD"
        }()
        return ProposedRelative(
            id: ProposedRelative.stableID(
                relationship: rel, gender: gender, surname: surname
            ),
            proposedSurname: surname,
            proposedGivenName: proposedGivenName,
            gender: gender,
            birthYearLow: parentLow,
            birthYearHigh: parentHigh,
            relationship: rel,
            evidence: evidence,
            inferenceDepth: InferenceDepth(
                steps: 1,
                chain: ["Parent surname inferred from \(inferredFromSourceID) birth record"]
            ),
            ambiguousMarriages: ambiguousMarriages
        )
    }

    /// Pull the parent's given name from cross-referenced marriage
    /// records, if reconciliation attached any. Match by surname-side:
    /// mother → bride-side entry; father → groom-side entry.
    /// Return the most frequent element in the array, or nil if the
    /// array is empty. Ties broken by first-encountered ordering
    /// (Dictionary iteration isn't sorted, but for the child-surname
    /// use case ties don't matter — any common surname is fine).
    nonisolated static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// Derive the wife's maiden surname from a mother-in-law present
    /// in a census household. The pattern: census enumerators
    /// recorded a mother-in-law under her own surname, which (by
    /// convention) is the wife's maiden surname. Mirrors
    /// `agent/rules.py:maiden_name_from_mother_in_law`.
    ///
    /// Returns the mother-in-law's surname when:
    ///   - A household member has relationship containing both
    ///     "mother" and "law" (case-insensitive)
    ///   - Her surname differs from the head's surname (otherwise
    ///     it's not a new signal)
    ///
    /// Returns nil otherwise — the dispatcher's existing
    /// linked-father derivation is the primary path; this is the
    /// fallback when the wife's father isn't a tree profile.
    nonisolated static func maidenNameFromMotherInLaw(
        household: [HouseholdMember],
        headSurname: String
    ) -> String? {
        let headSurnameUpper = headSurname
            .trimmingCharacters(in: .whitespaces).uppercased()
        for member in household {
            let rel = member.relationship.lowercased()
            guard rel.contains("mother"), rel.contains("law") else { continue }
            let parts = member.name.split(separator: " ", omittingEmptySubsequences: true)
            guard let surname = parts.last.map(String.init) else { continue }
            let upper = surname.uppercased()
            if !upper.isEmpty, upper != headSurnameUpper {
                return surname
            }
        }
        return nil
    }

    /// Find gaps between consecutive children's birth years that
    /// exceed `threshold` years. A gap of more than 3 years between
    /// known siblings often hides infant deaths recorded under the
    /// family surname in the intervening years (typical Victorian
    /// child-mortality pattern). Mirrors
    /// `agent/rules.py:child_gap_suggests_death`.
    nonisolated static func childBirthYearGaps(_ years: [Int], threshold: Int = 3) -> [(Int, Int)] {
        guard years.count >= 2 else { return [] }
        let sorted = years.sorted()
        var gaps: [(Int, Int)] = []
        for i in 0..<(sorted.count - 1) {
            if sorted[i + 1] - sorted[i] > threshold {
                gaps.append((sorted[i], sorted[i + 1]))
            }
        }
        return gaps
    }

    /// Pull spouse surnames out of confirmed marriage records.
    /// FreeBMD post-Sep-1912 marriage rows carry the spouse's full
    /// name in `spouseName` ("JANE SMITH" or "Jane Smith"); the
    /// surname is the last whitespace-separated token. Used by the
    /// post-marriage death-shape pivot to find a woman's records
    /// filed under her married surname when the linked-spouse
    /// derivation in `ResearchSubject.fromProfile` didn't apply
    /// (un-linked spouse, multiple marriages, mid-run discovery).
    nonisolated static func extractSpouseSurnames(from facts: [ScoredRecord]) -> Set<String> {
        var surnames: Set<String> = []
        for scored in facts {
            guard case .marriage(let m) = scored.record else { continue }
            guard let name = m.spouseName?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            let parts = name.split(separator: " ", omittingEmptySubsequences: true)
            guard let surnameRaw = parts.last.map(String.init),
                  surnameRaw.count >= 2 else { continue }
            // Strip trailing punctuation but preserve hyphens / apostrophes
            // that legitimately appear in surnames (O'Brien, Smyth-Jones).
            let surname = surnameRaw.trimmingCharacters(in: .punctuationCharacters)
            if !surname.isEmpty {
                surnames.insert(surname)
            }
        }
        return surnames
    }

    private static func extractParentGivenName(
        gender: Gender,
        surname: String,
        from evidence: [ScoredRecord]
    ) -> String? {
        let upperSurname = surname.uppercased()
        for scored in evidence {
            guard case .marriage(let m) = scored.record else { continue }
            let recordSurname = (m.common.surname ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard recordSurname == upperSurname else { continue }
            if let given = m.common.givenName?
                .trimmingCharacters(in: .whitespaces), !given.isEmpty {
                return given
            }
        }
        return nil
    }

    // MARK: - Sibling Hypothesis Flow (V2 spec §5.2 Phase 2)

    /// Run the `.siblingExists` framework path:
    ///   1. generate drafts (engine checks preconditions),
    ///   2. for each draft, build the level-1 deficit query, dispatch it,
    ///      and append the returned candidate records to `state.scoredRecords`
    ///      (also added to `enrichmentRecordIDs` so clustering — which ran
    ///      already — wouldn't have included them; future clustering passes
    ///      won't either),
    ///   3. grade each draft against the now-populated state,
    ///   4. finalise the hypothesis with verdict, evidence, history.
    ///
    /// Returns the finalised hypotheses. The pipeline's caller projects
    /// `.supported` ones back into the legacy `SiblingProposal` shape
    /// for the UI surface.
    private func runSiblingHypothesisFlow(
        state: inout ResearchState
    ) async -> [ResearchHypothesis] {
        let drafts = HypothesisEngine.generate(
            for: .siblingExists,
            state: state,
            snapshot: snapshot
        )
        guard !drafts.isEmpty else {
            logger.info("Sibling hypothesis flow: no drafts (preconditions not met)")
            return []
        }
        var graded: [ResearchHypothesis] = []
        for draft in drafts {
            let queries = HypothesisEngine.deficitQuery(
                for: draft, atLevel: 1, state: state
            )
            if !queries.isEmpty {
                let priorIDs = Set(state.scoredRecords.map(\.id))
                var allCandidates: [ScoredRecord] = []
                for query in queries {
                    let candidates = await dispatchSiblingCandidateQuery(query)
                    allCandidates.append(contentsOf: candidates)
                }
                let newCandidates = allCandidates.filter { !priorIDs.contains($0.id) }
                // MMN+surname filter: of the raw district-fan-out results
                // (which include every BMD-registered surname-match in the
                // year window — for Holmes that's ~2929 records across
                // DBY), keep only those whose mother's maiden name matches
                // the subject's. This is the same logic `inferSiblings`
                // already runs at grading time, lifted up to the leads-
                // persistence boundary so we don't bloat the user's view
                // with non-sibling namesakes.
                //
                // Compression-safe: FreeBMD parser fills `birth.common.surname`
                // from the query surname when the field is blank (FreeBMD
                // omits the surname column on adjacent rows that repeat).
                // MMN can be genuinely empty for pre-Sep-1911 births — for
                // those the filter does nothing useful, but our test tree's
                // top-gen subjects all post-date 1912 so MMN is available.
                let mmnMatching: [ScoredRecord] = {
                    guard case .siblingExists(_, let hypothesisMMN, _) = draft.kind else {
                        return newCandidates
                    }
                    let mmnUpper = hypothesisMMN.uppercased().trimmingCharacters(in: .whitespaces)
                    guard !mmnUpper.isEmpty else { return newCandidates }
                    let subjectSurname = (state.subject.surname ?? "")
                        .uppercased().trimmingCharacters(in: .whitespaces)
                    return newCandidates.filter { scored in
                        guard case .birth(let birth) = scored.record else { return false }
                        let recordMMN = (birth.mothersMaidenName ?? "")
                            .uppercased().trimmingCharacters(in: .whitespaces)
                        let recordSurname = (birth.common.surname ?? "")
                            .uppercased().trimmingCharacters(in: .whitespaces)
                        return recordMMN == mmnUpper && recordSurname == subjectSurname
                    }
                }()
                logger.info("Sibling deficit-query level 1: \(queries.count) districts → \(allCandidates.count) candidates, \(newCandidates.count) new, \(mmnMatching.count) MMN-matching")
                state.scoredRecords.append(contentsOf: mmnMatching)
                // Same exclusion trick as marriage enrichment: keep the
                // records as evidence (and on disk via the lead store)
                // but hide them from clustering. They answer the
                // sibling-exists question, not "is there another life of
                // the subject" — surfacing them as standalone clusters
                // would confuse the cluster review.
                state.enrichmentRecordIDs.formUnion(mmnMatching.map(\.id))
            }
            let result = HypothesisEngine.grade(
                draft, state: state, snapshot: snapshot
            )
            let now = Date()
            graded.append(ResearchHypothesis(
                id: draft.id,
                subjectProfileID: draft.subjectProfileID,
                kind: draft.kind,
                verdict: result.verdict,
                isModelAssisted: result.isModelAssisted,
                supportingEvidence: result.supportingEvidence,
                contradictingEvidence: result.contradictingEvidence,
                reasoning: result.reasoning,
                createdAt: draft.createdAt,
                lastTestedAt: now,
                attempts: 1,
                history: [
                    ResearchHypothesis.Transition(
                        verdict: result.verdict,
                        isModelAssisted: result.isModelAssisted,
                        at: now,
                        reason: "initial grading after level-1 deficit query"
                    )
                ]
            ))
        }
        return graded
    }

    /// Dispatch a focused FreeBMD birth query (built by the engine's
    /// `deficitQuerySiblingExists`) for sibling candidate discovery.
    /// Returns each hit as a `.lead`-verdict ScoredRecord — the grader
    /// uses `SiblingInferenceEngine`'s field-equality rule, not the
    /// scorer's verdict, to decide which candidates count.
    private func dispatchSiblingCandidateQuery(
        _ query: RecordQuery
    ) async -> [ScoredRecord] {
        guard let freebmd = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            return []
        }
        let result = await freebmd.search(query)
        return result.records.map { record in
            ScoredRecord(id: record.id, record: record, verdict: .lead, gates: [], summary: "")
        }
    }

    /// Project a `.supported` `.siblingExists` hypothesis to the
    /// `SiblingProposal` shape the UI's accept / reject flow expects.
    /// Empty for non-supported / non-sibling hypotheses, or when the
    /// supporting evidence record IDs no longer resolve in
    /// `scoredRecords` (a stale-hypothesis case the UI shouldn't see).
    ///
    /// Sole call site: `ResearchViewModel.visibleSiblings(snapshot:)`,
    /// which feeds `result.allScoredRecords`. Phase 4 of T12-sibling
    /// removed the pipeline's mirror call; the engine's hypothesis list
    /// is now the only sibling-discovery surface and proposals are
    /// computed on demand for view rendering.
    static func projectSiblingExistsToProposals(
        hypothesis: ResearchHypothesis,
        scoredRecords: [ScoredRecord],
        snapshot: FamilyGraphSnapshot
    ) -> [SiblingProposal] {
        guard hypothesis.isDeterministicallySupported,
              case .siblingExists = hypothesis.kind,
              let subjectProfileID = hypothesis.subjectProfileID
        else { return [] }
        let parents = snapshot.parentsOf(subjectProfileID)
        guard let father = parents.first(where: { $0.gender == .male }),
              let mother = parents.first(where: { $0.gender == .female })
        else { return [] }
        let scoredByID = Dictionary(uniqueKeysWithValues: scoredRecords.map { ($0.id, $0) })
        return hypothesis.supportingEvidence.compactMap { recordID -> SiblingProposal? in
            guard let scored = scoredByID[recordID],
                  case .birth(let birth) = scored.record else { return nil }
            return SiblingProposal(
                id: "siblingOf:\(father.id):\(scored.id)",
                candidateRecordID: scored.id,
                proposedSurname: birth.common.surname,
                proposedGivenName: birth.common.givenName,
                gender: nil,
                birthYear: birth.birthYear,
                district: birth.district,
                fatherID: father.id,
                motherID: mother.id,
                evidence: [scored]
            )
        }
    }

    // MARK: - T7 second pass (V2 spec §5.3)

    /// Hypothesis-guided second pass. Runs at most once per
    /// `research(...)` call, after the first pass has assembled its
    /// hypothesis list. For each `.inconclusive` hypothesis whose
    /// per-kind ladder still has headroom
    /// (`deficitQuery(for:atLevel: attempts + 1, state:) != nil`),
    /// dispatches the focused query, appends new evidence to state,
    /// increments the hypothesis's `attempts`, and re-grades every
    /// hypothesis (so cross-references via `reconcileParentMarriages`
    /// pick up newly-supported `.parentMarriage` rows).
    ///
    /// Returns the updated hypothesis list. Caller decides whether to
    /// recompute clusters with the now-larger evidence set (records
    /// added here are tagged with `enrichmentRecordIDs` so default
    /// clustering excludes them — matches the first-pass convention).
    ///
    /// Stall-detection (V2 spec §5.3 Decision 4) is a two-condition
    /// gate; T7 first-cut uses the looser condition (b) only —
    /// "deficit-eligible inconclusive hypothesis exists." Condition
    /// (a) "dispatcher walked the full strictness ladder" needs
    /// dispatcher instrumentation that doesn't exist yet and is
    /// deferred. In practice (b) alone is sufficient because the
    /// deficit query is a deterministic rewrite of a specific
    /// hypothesis's inputs — dispatching once for a hypothesis the
    /// first pass already touched is bounded and cheap.
    private func runSecondPass(
        state: inout ResearchState,
        hypotheses: [ResearchHypothesis],
        scope: ResearchScope
    ) async -> [ResearchHypothesis] {
        let eligible = hypotheses.filter { h in
            guard h.verdict == .inconclusive else { return false }
            return !HypothesisEngine.deficitQuery(
                for: h, atLevel: h.attempts + 1, state: state
            ).isEmpty
        }
        guard !eligible.isEmpty else { return hypotheses }
        logger.info("T7 second pass: \(eligible.count) deficit-eligible inconclusive hypotheses")

        // Dispatch each eligible hypothesis's deficit query. Records
        // feed back into state so the re-grade below picks them up.
        var attemptsByID: [String: Int] = [:]
        for h in eligible {
            let nextLevel = h.attempts + 1
            let queries = HypothesisEngine.deficitQuery(
                for: h, atLevel: nextLevel, state: state
            )
            guard !queries.isEmpty else { continue }
            var appended: [ScoredRecord] = []
            var appendedIDs: Set<String> = []
            let priorIDs = Set(state.scoredRecords.map(\.id))
            var totalNewRecords = 0
            for query in queries {
                let newRecords = await dispatchHypothesisDeficitQuery(
                    query: query, hypothesisKind: h.kind, scope: scope
                )
                totalNewRecords += newRecords.count
                for r in newRecords where !priorIDs.contains(r.id) && !appendedIDs.contains(r.id) {
                    appended.append(r)
                    appendedIDs.insert(r.id)
                }
            }
            state.scoredRecords.append(contentsOf: appended)
            state.enrichmentRecordIDs.formUnion(appended.map(\.id))
            attemptsByID[h.id] = nextLevel
            logger.info("T7 deficit dispatch (\(h.kind.discriminator), level \(nextLevel)): \(queries.count) queries → \(totalNewRecords) records, \(appended.count) new")
        }

        // Re-grade every hypothesis with the now-populated state. The
        // `attempts` counter is bumped only on hypotheses that fired a
        // deficit query.
        let now = Date()
        let regraded: [ResearchHypothesis] = hypotheses.map { h in
            let result = HypothesisEngine.grade(h, state: state, snapshot: snapshot)
            let newAttempts = attemptsByID[h.id] ?? h.attempts
            let transition = ResearchHypothesis.Transition(
                verdict: result.verdict,
                isModelAssisted: result.isModelAssisted,
                at: now,
                reason: "T7 second-pass re-grading"
            )
            return ResearchHypothesis(
                id: h.id,
                subjectProfileID: h.subjectProfileID,
                kind: h.kind,
                verdict: result.verdict,
                isModelAssisted: result.isModelAssisted,
                supportingEvidence: result.supportingEvidence,
                contradictingEvidence: result.contradictingEvidence,
                reasoning: result.reasoning,
                createdAt: h.createdAt,
                lastTestedAt: now,
                attempts: newAttempts,
                history: h.history + (h.verdict != result.verdict ? [transition] : [])
            )
        }

        // Reconciliation re-runs so newly-supported `.parentMarriage`
        // hypotheses get their cross-references threaded onto the
        // matching `.parentInferred` rows.
        return HypothesisEngine.reconcileParentMarriages(hypotheses: regraded)
    }

    /// Per-kind dispatch routing for T7's deficit queries. The
    /// engine's deficit query returns a single `RecordQuery` per
    /// level; per-kind orchestration is the seam that handles
    /// district fan-out (parent-marriage) vs single-source dispatch
    /// (sibling).
    private func dispatchHypothesisDeficitQuery(
        query: RecordQuery,
        hypothesisKind: HypothesisKind,
        scope: ResearchScope
    ) async -> [ScoredRecord] {
        switch hypothesisKind {
        case .siblingExists:
            return await dispatchSiblingCandidateQuery(query)
        case .parentMarriage(let motherSurname, let fatherSurname, _):
            // The deficit query for .parentMarriage carries the wider
            // window in yearFrom/yearTo. Fan out groom-side + bride-side
            // across the scope's districts (same as the first-pass
            // marriage dispatch).
            let yearFrom = query.yearFrom ?? 0
            let yearTo = query.yearTo ?? 0
            async let groomSide = dispatchMarriageQuery(
                surname: fatherSurname, spouseSurname: motherSurname,
                yearFrom: yearFrom, yearTo: yearTo, scope: scope
            )
            async let brideSide = dispatchMarriageQuery(
                surname: motherSurname, spouseSurname: fatherSurname,
                yearFrom: yearFrom, yearTo: yearTo, scope: scope
            )
            let g = await groomSide
            let b = await brideSide
            return g + b
        case .subjectSpouseMarriage(let groomSurname, let brideSurname, _):
            // Same two-sided fan-out shape as .parentMarriage — the
            // wider window from the deficit query lives in yearFrom/yearTo;
            // (groomSurname × brideSurname) is the pair (RESEARCH_PIPELINE_SPEC §5.14.9).
            let yearFrom = query.yearFrom ?? 0
            let yearTo = query.yearTo ?? 0
            async let groomSide = dispatchMarriageQuery(
                surname: groomSurname, spouseSurname: brideSurname,
                yearFrom: yearFrom, yearTo: yearTo, scope: scope
            )
            async let brideSide = dispatchMarriageQuery(
                surname: brideSurname, spouseSurname: groomSurname,
                yearFrom: yearFrom, yearTo: yearTo, scope: scope
            )
            let g = await groomSide
            let b = await brideSide
            return g + b
        case .parentInferred, .subjectIdentity, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            // These kinds either have no ladder (parentInferred,
            // subjectIdentity, clusterIsSubject) or aren't yet in
            // V2 scope. deficitQuery returned non-nil so the caller
            // reached us; honour that even though nothing dispatches.
            return []
        }
    }

    // MARK: - Marriage Dispatch (shared by the parent flow)
    //
    // The legacy `enrichParentsWithMarriage` gate-and-pair pipeline
    // was deleted in T12-parent Phase 2. Its gating moved into
    // `HypothesisEngine.generateParentMarriage` (V2 spec §5.2.1
    // gating policy); its matching is now `gradeParentMarriage`;
    // its cross-validation is `reconcileParentMarriages`. The
    // FreeBMD-fan-out helpers below survive because the framework's
    // `runParentHypothesisFlow` still needs them for per-pair
    // dispatch.

    /// Build and dispatch a FreeBMD marriage query through the existing source.
    /// Honours scope by fanning out across the same district set as the main pipeline.
    private func dispatchMarriageQuery(
        surname: String,
        spouseSurname: String,
        yearFrom: Int,
        yearTo: Int,
        scope: ResearchScope,
        cache: QueryCache? = nil
    ) async -> [ScoredRecord] {
        // Build district codes for this scope. Marriage enrichment is
        // FreeBMD-only — mirrors the FreeBMD widening logic in
        // SearchDispatcher.buildQueries; see RESEARCH_AXES_SPEC §5.3.
        let districtCodes: [String]
        switch scope {
        case .parish:
            districtCodes = []
        case .district, .county, .adjacent:
            districtCodes = Array(dispatcher.regionConfig.districts.values)
        case .national:
            let yr = yearFrom...yearTo
            districtCodes = FreeBMDDistrictCatalogue.shared.covering(years: yr).map { $0.code }
        }
        guard !districtCodes.isEmpty else { return [] }

        // Locate the FreeBMD source instance via the registry.
        guard let freebmd = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            return []
        }

        let queries: [RecordQuery] = districtCodes.map { code in
            RecordQuery(
                surname: surname,
                givenName: nil,
                recordType: .marriage,
                yearFrom: yearFrom,
                yearTo: yearTo,
                gender: nil,
                region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: code,
                    wildcardSurname: false,
                    motherSurname: nil,
                    spouseSurname: spouseSurname
                ))
            )
        }

        // Dispatch and lightly score — we don't need the full RecordScorer machinery
        // because we're matching by reference tuple, not by name+date gates.
        var allRecords: [SourceRecord] = []
        for q in queries {
            let records = await QueryCache.wrappedSearch(source: freebmd, query: q, cache: cache)
            allRecords.append(contentsOf: records)
        }
        // Wrap each in a ScoredRecord with a rich per-record summary — so the
        // cluster review row shows what was actually found (year, district,
        // vol/page, given name, spouse) instead of just the search window.
        return allRecords.map { record in
            ScoredRecord(
                id: record.id,
                record: record,
                verdict: .lead,
                gates: [],
                summary: Self.marriageRecordSummary(record)
            )
        }
    }

    /// Build a per-record summary for marriage hits returned by the enrichment
    /// dispatch, e.g. "DAVID N CAULDWELL × HOLMES, Jan–Mar 1969, BELPER 3A/161".
    ///
    /// BMD quarters are labelled by their END month ("Mar quarter" = Jan/Feb/Mar)
    /// which is unintuitive to non-genealogists. We expand to "Jan–Mar" etc. to
    /// remove the ambiguity. Pre-1912 marriages lack spouse surname; handled.
    private static func marriageRecordSummary(_ record: SourceRecord) -> String {
        guard case .marriage(let m) = record else { return "Marriage" }
        let given = m.common.givenName ?? ""
        let surname = m.common.surname ?? ""
        let primary = [given, surname].filter { !$0.isEmpty }.joined(separator: " ")
        let withSpouse: String = {
            if let s = m.spouseName, !s.isEmpty { return "\(primary) × \(s)" }
            return primary
        }()
        var locationParts: [String] = []
        if let q = m.quarter {
            locationParts.append(expandBMDQuarter(q))
        }
        if let y = m.marriageYear { locationParts.append(String(y)) }
        if let d = m.district { locationParts.append(d) }
        var ref = ""
        if let v = m.volume, let p = m.page { ref = " \(v)/\(p)" }
        else if let v = m.volume { ref = " vol \(v)" }
        let loc = locationParts.isEmpty ? "" : ", \(locationParts.joined(separator: " "))"
        return "Marriage: \(withSpouse)\(loc)\(ref)"
    }

    /// Expand a BMD quarter abbreviation ("Mar"/"Jun"/"Sep"/"Dec" — labelled by
    /// END month of the quarter) into a human-readable month range so non-
    /// genealogists don't read "Mar 1969" as "March 1969".
    private static func expandBMDQuarter(_ q: String) -> String {
        switch q.prefix(3).lowercased() {
        case "mar": return "Jan–Mar"
        case "jun": return "Apr–Jun"
        case "sep": return "Jul–Sep"
        case "dec": return "Oct–Dec"
        default: return q
        }
    }

    // MARK: - FamilySearch → Find a Grave bridge (spec §22)
    //
    // When `FamilySearchSource` surfaces a Find a Grave memorial via the
    // FS aggregator endpoint, the GEDCOMx persona carries the FAG memorial
    // id (via ExtRecordId) but no inscribed dates — FS's search response
    // doesn't include inscription text. Without intervention, a perfect
    // name+place match with no year stalls as a lead, the 4-gate scorer
    // can't promote it, and the next-iteration subject refinement
    // (`refineSubject`) never gets a death year to propagate.
    //
    // The bridge: any `FamilySearch` burial record whose `memorialID` is
    // set but `deathYear` is nil triggers a follow-up
    // `FindAGraveSource.fetchDetail` call. The FAG detail parser mines
    // the inscription / bio for years (FindAGraveSource extension landed
    // earlier this session). The enriched FAG-detail record is appended
    // *alongside* the original FS persona — both score independently and
    // converge naturally in the cluster.
    //
    // Skip records whose memorial id is already present in
    // `existingIDs` (a prior iteration's bridge ran): keeps the FAG
    // 500ms-per-request rate-limit happy.

    private func enrichFagBridge(
        _ records: [SourceRecord],
        existingIDs: Set<String>
    ) async -> [SourceRecord] {
        guard let fagAny = dispatcher.registry.allSources().first(where: { $0.sourceID == "findagrave" }),
              let fagDetail = fagAny as? any DetailFetchingSource else {
            return records
        }
        var out: [SourceRecord] = []
        out.reserveCapacity(records.count)
        for record in records {
            out.append(record)
            guard case .burial(let burial) = record,
                  record.sourceID == "familysearch",
                  let memorialID = burial.memorialID,
                  burial.deathYear == nil
            else { continue }
            let detailID = "findagrave_\(memorialID)"
            // Skip if we've already pulled this FAG memorial in a prior
            // iteration. Both the FAG-detail record's id and any other
            // representation of the same memorial would carry this id.
            if existingIDs.contains(detailID) { continue }
            let result = await fagDetail.fetchDetail(recordID: detailID)
            guard case .results(let detail) = result, let enriched = detail.first else {
                logger.info("FAG bridge: detail fetch returned no result for memorial \(memorialID)")
                continue
            }
            logger.info("FAG bridge: enriched memorial \(memorialID) alongside FS persona")
            out.append(enriched)
        }
        return out
    }

    // MARK: - Same-page-couple pairing (pre-1912 marriage partner recovery)

    /// Fetch spouse-side marriage records and annotate subject-side
    /// marriages with `partnerSurnameFromSamePage`. Closes the pre-Sep-1912
    /// FreeBMD gap where the spouse-surname column is blank but both sides
    /// of the marriage share a `(vol, page)`.
    ///
    /// Gating:
    ///   * subject has a known spouse surname (via `familyContext.spouseSurname`
    ///     or `spouseFatherSurname` for inverted imports),
    ///   * subject has its own surname (needed as the spouse-side query's
    ///     `s_surname` filter for post-1912 narrowing),
    ///   * at least one subject-side marriage record exists in this batch
    ///     to annotate (no point fetching otherwise).
    ///
    /// The year window for the spouse-side fetch is taken from the subject-
    /// side marriages we want to annotate — narrower than `subject.yearRange`
    /// and cheap to compute. Spouse-side records themselves are used only
    /// in-memory for pairing; they're not appended to `state.scoredRecords`.
    private func annotateMarriagesWithSamePagePartner(
        _ records: [SourceRecord],
        subject: ResearchSubject,
        scope: ResearchScope,
        cache: QueryCache?
    ) async -> [SourceRecord] {
        // Known spouse surnames to probe — recorded married name plus the
        // recoverable maiden form (see `FamilyContext.spouseFatherSurname`).
        var knownSpouseSurnames: [String] = []
        if let s = subject.familyContext?.spouseSurname?
            .trimmingCharacters(in: .whitespaces), !s.isEmpty {
            knownSpouseSurnames.append(s)
        }
        if let m = subject.familyContext?.spouseFatherSurname?
            .trimmingCharacters(in: .whitespaces), !m.isEmpty,
           !knownSpouseSurnames.contains(where: {
               $0.caseInsensitiveCompare(m) == .orderedSame
           }) {
            knownSpouseSurnames.append(m)
        }
        guard !knownSpouseSurnames.isEmpty else { return records }

        guard let subjectSurname = subject.surname?
            .trimmingCharacters(in: .whitespaces),
              !subjectSurname.isEmpty else { return records }

        // Subject-side marriages worth annotating: ours, no partner yet, year known.
        let subjectMarriages: [MarriageRecord] = records.compactMap { rec -> MarriageRecord? in
            guard case .marriage(let m) = rec,
                  m.partnerSurnameFromSamePage == nil,
                  m.marriageYear != nil,
                  let s = m.common.surname?.trimmingCharacters(in: .whitespaces),
                  s.caseInsensitiveCompare(subjectSurname) == .orderedSame
            else { return nil }
            return m
        }
        guard !subjectMarriages.isEmpty else { return records }

        let years = subjectMarriages.compactMap(\.marriageYear)
        guard let yearFrom = years.min(), let yearTo = years.max() else { return records }

        // Dispatch spouse-side queries. The `spouseSurname` arg on
        // `dispatchMarriageQuery` becomes FreeBMD's `s_surname` filter —
        // narrows post-1912 results server-side; pre-1912 the column is
        // blank so the server returns the full surname set regardless,
        // which is what we need for pairing.
        var spouseSideMarriages: [MarriageRecord] = []
        for spouseSurname in knownSpouseSurnames {
            if spouseSurname.caseInsensitiveCompare(subjectSurname) == .orderedSame {
                continue   // same-surname couples have nothing to pair
            }
            let scored = await dispatchMarriageQuery(
                surname: spouseSurname,
                spouseSurname: subjectSurname,
                yearFrom: yearFrom,
                yearTo: yearTo,
                scope: scope,
                cache: cache
            )
            for s in scored {
                if case .marriage(let m) = s.record {
                    spouseSideMarriages.append(m)
                }
            }
        }
        guard !spouseSideMarriages.isEmpty else { return records }

        let (annotated, pairCount) = SamePageCouplePairing.annotate(
            subjectSideRecords: records,
            spouseSideMarriages: spouseSideMarriages
        )
        if pairCount > 0 {
            logger.info("Same-page pairing: annotated \(pairCount) subject-side marriages from \(spouseSideMarriages.count) spouse-side entries")
        }
        return annotated
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

