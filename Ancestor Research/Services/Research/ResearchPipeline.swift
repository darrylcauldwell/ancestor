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
                recordTypes: state.activeRecordTypes,
                scope: config.scope,
                mode: state.subject.mode
            )

            // Capture prior record IDs before append, so the stopping check
            // below can detect a "stable point" — an iteration that returned
            // only records we've already collected. Without this we'd keep
            // hammering the same dispatch through iterations 2-4 even when
            // nothing new is being found.
            let priorRecordIDs = Set(state.scoredRecords.map(\.record.id))

            let scored = records.map { record in
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

            // DETERMINISTIC: infer relatives from facts AND leads.
            // The mothersMaidenName field is transcribed from the BMD index and
            // doesn't depend on geography/family gates passing; if name+year
            // matched (which is what makes a record fact-or-lead vs. impossible),
            // the parent surnames it implies are worth surfacing. Confidence on
            // the resulting ProposedRelative reflects the source verdict.
            let pre = state.proposedRelatives.count
            state.proposedRelatives = inferRelatives(
                from: state.confirmedFacts + state.leads,
                subject: state.subject,
                existing: state.proposedRelatives
            )
            let post = state.proposedRelatives.count
            logger.info("inferRelatives: facts=\(state.confirmedFacts.count) leads=\(state.leads.count) → proposals \(pre)→\(post) (subjectID=\(state.subject.profileID ?? "nil"))")

            // DETERMINISTIC: enrich surname-only parent proposals with given names.
            // For each (mother, father) pair the inference engine produced, fan
            // out two FreeBMD marriage queries (groom-indexed + bride-indexed).
            // Same marriage appears under both — matching by reference tuple
            // yields both first names without ordering a certificate. Honours
            // the same scope as the surrounding pipeline.
            // Marriage enrichment runs ONCE per pipeline run (first iteration
            // where parents are proposed). Honours the same scope as the rest
            // of the pipeline — most users research in their home county where
            // their ancestors lived and married. Set scope=.national in the
            // UI if parents likely married elsewhere.
            if !state.marriageEnrichmentAttempted && !state.proposedRelatives.isEmpty {
                let beforeEnrich = state.proposedRelatives.count
                let (enriched, marriageRecords) = await enrichParentsWithMarriage(
                    state.proposedRelatives,
                    subject: state.subject,
                    scope: config.scope
                )
                state.proposedRelatives = enriched
                state.scoredRecords.append(contentsOf: marriageRecords)
                state.enrichmentRecordIDs.formUnion(marriageRecords.map(\.id))
                state.marriageEnrichmentAttempted = true
                logger.info("Marriage enrichment: \(beforeEnrich)→\(state.proposedRelatives.count) proposals, \(marriageRecords.count) marriage records captured")
            }

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
                logger.info("Stable point: iteration \(iteration) re-fetched \(records.count) records, none new — stopping")
                break
            }
        }

        logger.info("Pipeline complete: \(state.confirmedFacts.count) facts, \(state.leads.count) leads, \(state.rejectedRecords.count) rejected")

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

        // DETERMINISTIC: sibling discovery (T17). Gated on identity resolved
        // AND both parents linked — the engine returns [] otherwise but the
        // dispatch is wasted, so check upstream.
        let proposedSiblings = await findSiblings(state: state)

        return ResearchResult(
            confirmedFacts: state.confirmedFacts,
            leads: state.leads,
            allScoredRecords: state.scoredRecords,
            clusters: clusters,
            discrepancies: state.discrepancies,
            householdMembers: state.householdMembers,
            searchHistory: state.searchHistory,
            proposedRelatives: state.proposedRelatives,
            proposedSiblings: proposedSiblings
        )
    }

    // MARK: - Marriage Enrichment

    /// Fan out FreeBMD marriage queries for each (mother, father) pair the parent
    /// inference engine produced, then call MarriageEnrichmentEngine to match
    /// groom-side vs bride-side hits and fill in given names.
    ///
    /// Returns the (possibly mutated) proposals plus every marriage record found
    /// during the queries — caller appends those to state.scoredRecords so they
    /// get persisted as evidence rather than discarded.
    /// Pairs whose mother given name is already populated are skipped.
    func enrichParentsWithMarriage(
        _ proposals: [ProposedRelative],
        subject: ResearchSubject,
        scope: ResearchScope
    ) async -> (proposals: [ProposedRelative], marriageRecords: [ScoredRecord]) {
        guard let subjectBirthYear = subject.birthYearFrom ?? subject.birthYearTo else {
            return (proposals, [])
        }
        // Window: parents married between birth − 30 and birth + 1.
        let yearFrom = subjectBirthYear - 30
        let yearTo = subjectBirthYear + 1

        // ── Search-storm prevention (T29) ─────────────────────────────────
        // ParentInferenceEngine generates one mother proposal per distinct
        // `mothersMaidenName` across every candidate birth record the
        // dispatcher returns for the subject. For a non-specific subject
        // like "Jennifer Holmes 1948" that's dozens of MMNs (Brooks, Hicks,
        // Sambrook, Dabbs, …) — each spawning a two-sided marriage query
        // fanned out across every Derbyshire district. Most are noise.
        //
        // Gating policy:
        //   • If both parents are already linked → only enrich the pair
        //     whose surnames match (typically just one).
        //   • Else if SubjectIdentityResolver pins one birth record → only
        //     enrich proposals derived from THAT record's MMN.
        //   • Else → skip enrichment entirely. Without identity resolution
        //     or known parents, every pair is suspect.
        let knownFather = subject.profileID.flatMap { id in
            snapshot.parentsOf(id).first(where: { $0.gender == .male })
        }
        let knownMother = subject.profileID.flatMap { id in
            snapshot.parentsOf(id).first(where: { $0.gender == .female })
        }
        let knownFatherSurname = knownFather?.lastName?
            .trimmingCharacters(in: .whitespaces)
        let knownMotherSurname = knownMother?.lastName?
            .trimmingCharacters(in: .whitespaces)
        let bothParentsLinked = !(knownFatherSurname?.isEmpty ?? true)
            && !(knownMotherSurname?.isEmpty ?? true)

        // Identity resolution — pull all .fact birth records from the
        // proposal evidence (each proposal cites the record it was inferred
        // from). Deduped because father+mother proposals share evidence.
        let candidateBirthFacts: [ScoredRecord] = {
            var seen: Set<String> = []
            var result: [ScoredRecord] = []
            for proposal in proposals {
                for scored in proposal.evidence {
                    if case .birth = scored.record,
                       scored.verdict == .fact,
                       !seen.contains(scored.id) {
                        seen.insert(scored.id)
                        result.append(scored)
                    }
                }
            }
            return result
        }()
        let hypotheses: [GeographicHypothesis] = subject.profileID.map { id in
            GeographicHypothesisGenerator.inferDistricts(
                for: id,
                snapshot: snapshot,
                eventYear: subject.birthYearFrom
            )
        } ?? []
        let identity = SubjectIdentityResolver.resolve(
            candidateBirthFacts: candidateBirthFacts,
            hypotheses: hypotheses
        )
        let resolvedBirthRecordID: String? = {
            if case .resolved(let id, _) = identity { return id }
            return nil
        }()

        guard bothParentsLinked || resolvedBirthRecordID != nil else {
            logger.info("Marriage enrichment skipped: subject identity not resolved AND parents not linked — would dispatch one marriage query per candidate MMN (most wrong)")
            return (proposals, [])
        }

        // Pair mothers with fathers by shared parentOf(subjectID).
        var enriched = proposals
        var collectedMarriageRecords: [ScoredRecord] = []
        let fathers = enriched.enumerated().filter { $0.element.gender == .male }
        let mothers = enriched.enumerated().filter { $0.element.gender == .female }

        for (fIdx, father) in fathers {
            guard case .parentOf(let fatherSubjectID) = father.relationship else { continue }
            for (mIdx, mother) in mothers {
                guard case .parentOf(let motherSubjectID) = mother.relationship,
                      fatherSubjectID == motherSubjectID else { continue }
                // Already enriched — skip
                if mother.proposedGivenName != nil && father.proposedGivenName != nil { continue }
                guard let fatherSurname = father.proposedSurname, !fatherSurname.isEmpty,
                      let motherSurname = mother.proposedSurname, !motherSurname.isEmpty
                else { continue }

                // Per-pair scoping under the gating policy above.
                if bothParentsLinked {
                    let fMatches = fatherSurname.caseInsensitiveCompare(knownFatherSurname ?? "") == .orderedSame
                    let mMatches = motherSurname.caseInsensitiveCompare(knownMotherSurname ?? "") == .orderedSame
                    if !(fMatches && mMatches) {
                        logger.info("Skipping pair \(fatherSurname) × \(motherSurname): doesn't match linked parents \(knownFatherSurname ?? "?") × \(knownMotherSurname ?? "?")")
                        continue
                    }
                } else if let resolvedID = resolvedBirthRecordID {
                    let fFromResolved = father.evidence.contains { $0.id == resolvedID }
                    let mFromResolved = mother.evidence.contains { $0.id == resolvedID }
                    if !(fFromResolved || mFromResolved) {
                        logger.info("Skipping pair \(fatherSurname) × \(motherSurname): not derived from resolved subject birth record")
                        continue
                    }
                }

                logger.info("Marriage enrichment: \(fatherSurname) × \(motherSurname), \(yearFrom)–\(yearTo)")

                async let groomSide = dispatchMarriageQuery(
                    surname: fatherSurname,
                    spouseSurname: motherSurname,
                    yearFrom: yearFrom, yearTo: yearTo,
                    scope: scope
                )
                async let brideSide = dispatchMarriageQuery(
                    surname: motherSurname,
                    spouseSurname: fatherSurname,
                    yearFrom: yearFrom, yearTo: yearTo,
                    scope: scope
                )
                let groomScored = await groomSide
                let brideScored = await brideSide
                collectedMarriageRecords.append(contentsOf: groomScored)
                collectedMarriageRecords.append(contentsOf: brideScored)
                let grooms = MarriageEnrichmentEngine.entries(from: groomScored)
                let brides = MarriageEnrichmentEngine.entries(from: brideScored)

                let outcome = MarriageEnrichmentEngine.match(
                    grooms: grooms,
                    brides: brides,
                    yearWindow: yearFrom...yearTo,
                    expectedGroomSpouseSurname: motherSurname,
                    expectedBrideSpouseSurname: fatherSurname
                )
                switch outcome {
                case .unique(let fatherGiven, let motherGiven, let fatherEv, let motherEv):
                    // Either or both given names may be nil when FreeBMD
                    // returned the marriage on only one side of the index.
                    // Apply whatever we got; leave the missing side's given
                    // name as nil (proposal stays surname-only there).
                    let fLabel = fatherGiven ?? "?"
                    let mLabel = motherGiven ?? "?"
                    let sideTag: String
                    switch (fatherGiven, motherGiven) {
                    case (.some, .some): sideTag = "both sides"
                    case (.some, .none): sideTag = "groom-side only"
                    case (.none, .some): sideTag = "bride-side only"
                    case (.none, .none): sideTag = "neither side (refKey only)"
                    }
                    logger.info("Marriage match (\(sideTag)): \(fLabel) \(fatherSurname) × \(mLabel) \(motherSurname)")
                    if let g = fatherGiven { enriched[fIdx].proposedGivenName = g }
                    if let g = motherGiven { enriched[mIdx].proposedGivenName = g }
                    // The marriage record validates both surnames regardless of
                    // which side carried it (the missing side's surname appears
                    // in the other side's `Spouse` field). Attach the available
                    // record to BOTH proposals so the surname-only parent still
                    // shows a "Cross-validated by" entry — rather than a bare
                    // "1 source" card that misleadingly suggests no marriage
                    // was found.
                    let evForFather = fatherEv ?? motherEv
                    let evForMother = motherEv ?? fatherEv
                    if let ev = evForFather { enriched[fIdx].evidence.append(ev) }
                    if let ev = evForMother { enriched[mIdx].evidence.append(ev) }
                case .ambiguous(let candidates):
                    logger.info("Marriage enrichment ambiguous: \(candidates.count) candidates for \(fatherSurname) × \(motherSurname)")
                    enriched[fIdx].ambiguousMarriages = candidates
                    enriched[mIdx].ambiguousMarriages = candidates
                case .none:
                    logger.info("Marriage enrichment: no match for \(fatherSurname) × \(motherSurname)")
                }
            }
        }
        return (enriched, collectedMarriageRecords)
    }

    /// Build and dispatch a FreeBMD marriage query through the existing source.
    /// Honours scope by fanning out across the same district set as the main pipeline.
    private func dispatchMarriageQuery(
        surname: String,
        spouseSurname: String,
        yearFrom: Int,
        yearTo: Int,
        scope: ResearchScope
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
            let result = await freebmd.search(q)
            allRecords.append(contentsOf: result.records)
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

    // MARK: - Sibling Discovery

    /// Find candidate full siblings of the subject by querying FreeBMD for
    /// births sharing the subject's surname + registration district + a
    /// ±20-year window, then filtering via `SiblingInferenceEngine` on
    /// (surname, MMN, district). Returns [] unless the subject's identity
    /// is resolved to a unique birth record AND both parents are linked in
    /// the snapshot — those preconditions are what let the engine produce
    /// trustworthy peer matches and let the accept flow wire a ghost to
    /// both parents atomically.
    ///
    /// Dispatch is one focused query (single district, single surname) —
    /// narrower than the main pipeline's per-iteration fan-out, so safe to
    /// run unconditionally when the preconditions hold.
    func findSiblings(state: ResearchState) async -> [SiblingProposal] {
        let birthFacts = state.confirmedFacts.filter {
            if case .birth = $0.record { return true }
            return false
        }
        let hypotheses: [GeographicHypothesis] = state.subject.profileID.map { id in
            GeographicHypothesisGenerator.inferDistricts(
                for: id,
                snapshot: snapshot,
                eventYear: state.subject.birthYearFrom
            )
        } ?? []
        let identity = SubjectIdentityResolver.resolve(
            candidateBirthFacts: birthFacts,
            hypotheses: hypotheses
        )
        guard case .resolved(let resolvedID, _) = identity,
              let subjectBirth = birthFacts.first(where: { $0.id == resolvedID })
        else {
            return []
        }

        // Both parents must be linked — accept-flow writes two parent edges.
        guard let subjectProfileID = state.subject.profileID else { return [] }
        let parents = snapshot.parentsOf(subjectProfileID)
        guard let father = parents.first(where: { $0.gender == .male }),
              let mother = parents.first(where: { $0.gender == .female })
        else {
            return []
        }

        guard case .birth(let birth) = subjectBirth.record,
              let districtName = birth.district, !districtName.isEmpty,
              let subjectYear = birth.birthYear,
              let subjectSurname = birth.common.surname, !subjectSurname.isEmpty
        else {
            return []
        }
        guard let district = FreeBMDDistrictCatalogue.shared.district(named: districtName) else {
            logger.info("Sibling search skipped: district \"\(districtName)\" not in FreeBMD catalogue")
            return []
        }

        let yearFrom = subjectYear - SiblingInferenceEngine.maxSiblingAgeGap
        let yearTo = subjectYear + SiblingInferenceEngine.maxSiblingAgeGap

        let candidates = await dispatchSiblingQuery(
            surname: subjectSurname,
            districtCode: district.code,
            yearFrom: yearFrom, yearTo: yearTo
        )
        logger.info("Sibling search: \(candidates.count) candidate births in \(districtName) \(yearFrom)–\(yearTo)")

        return SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: subjectBirth,
            candidateRecords: candidates,
            knownFatherID: father.id,
            knownMotherID: mother.id,
            snapshot: snapshot
        )
    }

    /// Dispatch a focused FreeBMD birth query for sibling discovery.
    /// Surname-only, no given name, single district, full ±20-year window.
    /// Inference engine filters on MMN/district equality, so we deliberately
    /// don't run the records through RecordScorer — the verdict/gates are
    /// irrelevant to the sibling match rule.
    private func dispatchSiblingQuery(
        surname: String,
        districtCode: String,
        yearFrom: Int,
        yearTo: Int
    ) async -> [ScoredRecord] {
        guard let freebmd = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            return []
        }
        let query = RecordQuery(
            surname: surname,
            givenName: nil,
            recordType: .birth,
            yearFrom: yearFrom, yearTo: yearTo,
            gender: nil, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: districtCode,
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: nil
            ))
        )
        let result = await freebmd.search(query)
        return result.records.map { record in
            ScoredRecord(id: record.id, record: record, verdict: .lead, gates: [], summary: "")
        }
    }

    // MARK: - Parent Inference

    /// Wraps `ParentInferenceEngine.infer` with snapshot-derived `existingParents`.
    /// Pure logic lives in the engine; this method just supplies the snapshot context.
    func inferRelatives(
        from facts: [ScoredRecord],
        subject: ResearchSubject,
        existing: [ProposedRelative]
    ) -> [ProposedRelative] {
        let parents = subject.profileID.map { snapshot.parentsOf($0) } ?? []
        return ParentInferenceEngine.infer(
            from: facts,
            subject: subject,
            existingParents: parents,
            sourceInfoMap: sourceInfoMap,
            existing: existing
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

