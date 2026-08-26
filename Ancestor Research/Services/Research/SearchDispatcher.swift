import Foundation
import os

/// Dispatches searches across all applicable sources.
/// Knows source-specific patterns: multi-district for FreeBMD, per-census-year for FreeCen.
/// Sources are dumb pipes — the dispatcher builds the queries.
@MainActor
struct SearchDispatcher {
    /// Why the strictness ladder stopped where it did. The dispatcher was
    /// previously silent on this, and a stopped ladder is indistinguishable
    /// from a ladder that ran and found nothing — four rounds of dogfood
    /// (2026-08-22, Harriet Holmes's missing census) were spent inferring it
    /// from the SHAPE of the outcome data instead of reading it.
    private static let ladderLog = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "Ladder")

    let registry: SourceRegistry

    /// Per-source daily-budget tracker (ENGINE_FOUNDATION #Change5). When
    /// present, budget-paused sources are dropped from the dispatch fan-out
    /// (the engine continues with the rest) and every query that fires counts
    /// one request against its source's daily quota. Nil in unit tests and
    /// any path that doesn't care about budgets — behaviour is then exactly
    /// as before this Change.
    var budgetTracker: SourceBudgetTracker? = nil

    /// Source-record IDs the human has already DISCARDED for this subject
    /// (`ProjectDatabase.loadRejections`). A discarded record is not a find —
    /// it is a recorded verdict that this is the wrong person — so it must not
    /// satisfy the ladder's stop condition.
    ///
    /// Owner dogfood 2026-08-22. Harriet Holmes is a Holmes who married a
    /// Holmes, so her `.strict` census probe is guaranteed to return namesakes.
    /// It returned one — a Derby foundry family — the ladder stopped there, and
    /// `.loose` (FreeCen's own server-side fuzzy) and `.variant` (the
    /// HARRIET→HARRIETT fan-out) never ran. Her actual 1891 census, which the
    /// app already held under her husband, stayed unreachable. Worse, she had
    /// DISCARDED the Derby record: she told the app it was the wrong woman and
    /// the app kept using it as the reason not to look further.
    ///
    /// With this set populated, reviewing becomes search input — every discard
    /// widens the next run instead of narrowing it. Empty by default, so every
    /// caller that doesn't supply it behaves exactly as before.
    var discardedSourceRecordIDs: Set<String> = []

    /// Surname equivalences THIS TREE has taught us, uppercased key → variants.
    ///
    /// The third layer of the variant story. Curated seeds cover irregulars,
    /// generated rules cover the productive patterns — and neither knows that
    /// in *this* family, a woman recorded as STEVENSON at her marriage was
    /// STEPHENSON at her baptism. Applying a record whose surname differs from
    /// the profile's is a human confirming exactly that, and it was being
    /// thrown away: `name_equivalences` has existed as a table, a save function
    /// and a load function since the schema was written, called by nothing.
    ///
    /// Injected rather than read from a static so multi-window projects stay
    /// isolated — the same reason `ScoringRules` keys its equivalences by
    /// project UUID.
    var learnedSurnameVariants: [String: [String]] = [:]

    /// Dispatch searches across all enabled sources for the given record types.
    /// `scope` widens fan-out for scope-aware sources (FreeBMD; FreeCen/FreeREG later).
    /// Sources declaring `.inherentlyNational` / `.anchorPinned` /
    /// `.localCorpus` scope handling ignore scope (CWGC, FindAGrave,
    /// Probate) — see `ScopeHandling`.
    ///
    /// `mode` is the wedge for the strictness ladder (RESEARCH_AXES_SPEC §3.1 /
    /// Change 6). This Change passes `.strict` to every source unconditionally;
    /// Change 6 wires the per-mode empty-then-broaden flow.
    func dispatch(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>,
        scope: ResearchScope = .county,
        mode: ResearchMode = .extend,
        cache: QueryCache? = nil
    ) async -> [SourceRecord] {
        await dispatchWithOutcomes(
            subject: subject, recordTypes: recordTypes,
            scope: scope, mode: mode, cache: cache
        ).records
    }

    /// Envelope-preserving dispatch (connector-audit T1-01). Same
    /// fan-out as `dispatch`, but also returns one `SearchOutcomeEntry`
    /// per (source, query) so the pipeline can record genuine negatives
    /// and GPS criterion-1 can exclude error/truncated searches.
    ///
    /// `negativeCache` (connector-audit T1-04) suppresses live dispatch
    /// of any query a prior run proved cleanly empty within its freshness
    /// window: the query is skipped, no HTTP request is made, and a
    /// `suppressed` clean-empty outcome is recorded in its place. Only the
    /// MAIN iteration-loop fan-out passes it — strategist/pivot flows
    /// (`dispatchOne`) never suppress, matching how they're excluded from
    /// negative-evidence recording. Defaults to `.disabled` so every
    /// non-main-loop caller behaves exactly as before T1-04.
    /// `stage` (SOURCE_WEIGHTING Change 5): when set, the fan-out is
    /// filtered to that stage's sources at the stage's effective scope
    /// (bounded by the caller's `scope`) — the stage ladder owns
    /// geographic widening. Nil = legacy flat fan-out (strategist/one-off
    /// paths dispatch at exactly the caller's scope; FT-04's
    /// county→national self-escalation was retired 2026-08-24, #34
    /// ruling b — the picked scope is the contract on every path).
    func dispatchWithOutcomes(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>,
        scope: ResearchScope = .county,
        mode: ResearchMode = .extend,
        cache: QueryCache? = nil,
        negativeCache: NegativeSearchCache = .disabled,
        stage: DispatchStage? = nil
    ) async -> (records: [SourceRecord], outcomes: [SearchOutcomeEntry]) {
        let ladder = Self.strictnessLadder(for: mode)
        let dispatchScope = stage.map { $0.effectiveScope(userScope: scope) } ?? scope

        // ENGINE_FOUNDATION #Change5 — set of sources whose daily budget is
        // spent. Computed ONCE up front so the whole fan-out sees a
        // consistent view, and so a source paused mid-enumeration is skipped
        // for every record type (not just the one that happened to notice).
        // Empty when no tracker is wired. Budget-paused ≠ throttled: we skip
        // the source entirely rather than laddering its circuit breaker.
        let pausedSourceIDs: Set<String>
        if let tracker = budgetTracker {
            var paused: Set<String> = []
            for source in registry.enabledSources() where await tracker.isPaused(source.sourceID) {
                paused.insert(source.sourceID)
                // Make the skip VISIBLE. A source paused *before* this run
                // began (budget spent on a prior run/day) never fires a
                // request, so `recordRequest`'s once-per-window
                // `.dailyBudgetExhausted` never emits for it — it would
                // otherwise vanish from the dispatch fan-out with no trace,
                // reading as an inexplicable coverage gap (e.g. FreeBMD, 200/
                // day, silently absent). Re-publish the event here so the drop
                // lands in the `_dispatch_log` (DispatchLogCollector logs it as
                // an error-kind entry carrying the resume time).
                let resumeAt = await tracker.resumeAt(for: source.sourceID) ?? Date()
                await ResearchActivityBus.shared.publish(
                    .dailyBudgetExhausted(sourceID: source.sourceID, resumeAt: resumeAt)
                )
            }
            pausedSourceIDs = paused
        } else {
            pausedSourceIDs = []
        }

        // Enumerate (source, recordType) targets. Per-source coverage check
        // stays in this top loop — we don't dispatch tiers to sources that
        // can't cover the year window at all. Budget-paused sources are
        // dropped here so the engine continues with the non-paused ones.
        var targets: [(any RecordSource, RecordType)] = []
        for recordType in recordTypes {
            let yearRange = subject.yearRange(for: recordType)
            for source in registry.enabledSources(for: recordType, region: subject.region) {
                guard sourceCovers(source, yearRange: yearRange) else { continue }
                guard !pausedSourceIDs.contains(source.sourceID) else { continue }
                if let stage, !stage.includes(source) { continue }
                targets.append((source, recordType))
            }
        }

        // Person-shaped collapse (owner decision 2026-07-30): FreeREG's
        // all-types umbrella (`.parish`) query is a strict SUPERSET of its
        // typed baptism/marriage/burial queries — one person-per-county
        // search returns every register entry for the name, and the
        // 4-gate scorer discriminates client-side (mirroring how a human
        // uses the site: one search, then read). When the umbrella target
        // is present, the typed FreeREG targets are pure duplicate
        // request-spend with an added narrow-window silent-miss failure
        // mode (live find: the 1896 KEYWORTH marriage), so they collapse
        // into it. A run without `.parish` (focused typed runs) keeps its
        // typed FreeREG query.
        if targets.contains(where: { $0.0.sourceID == "freereg" && $0.1 == .parish }) {
            targets.removeAll { $0.0.sourceID == "freereg" && $0.1 != .parish }
        }

        // T1-12 — collapse targets that would produce a wire-identical
        // query set. CWGC is the motivating case: its `.death` and
        // `.burial` record-type targets both build the same `.death` CWGC
        // query (buildQueries ignores the requested type for CWGC and the
        // two share a year window), so two byte-identical HTTP requests
        // raced past the per-run QueryCache on iteration 1 of every
        // military-eligible subject, then got discarded by dedupe(). We
        // fingerprint each target by its source plus the SORTED set of
        // cache keys its base queries would emit (strictness-independent —
        // the ladder walks the same tiers either way); a later target whose
        // fingerprint already appeared is dropped so the source is
        // dispatched once. General fix: any two targets that hit the wire
        // identically now dispatch once, regardless of a source's declared
        // `recordTypes`.
        targets = dedupeWireIdenticalTargets(targets) { source, recordType in
            self.buildQueries(source: source, subject: subject, recordType: recordType, scope: dispatchScope)
                .map { QueryCache.cacheKey(sourceID: source.sourceID, query: $0) }
        }

        return await withTaskGroup(
            of: (records: [SourceRecord], outcomes: [SearchOutcomeEntry]).self
        ) { group in
            for (source, recordType) in targets {
                group.addTask { [source, recordType] in
                    await self.dispatchToSource(
                        source: source,
                        subject: subject,
                        recordType: recordType,
                        scope: dispatchScope,
                        ladder: ladder,
                        mode: mode,
                        cache: cache,
                        negativeCache: negativeCache
                    )
                }
            }
            var combined: [SourceRecord] = []
            var outcomes: [SearchOutcomeEntry] = []
            for await batch in group {
                combined.append(contentsOf: batch.records)
                outcomes.append(contentsOf: batch.outcomes)
            }
            return (deduplicate(combined), outcomes)
        }
    }

    /// Slice 13a — dispatch a single `FocusedQuery` to one source.
    /// Used by the Level-2 query strategist (between-iteration MLX
    /// suggestion). Bypasses the strictness ladder and the multi-
    /// source fan-out — the strategist's responsibility is to be
    /// surgical, so we honour exactly what it asked for.
    ///
    /// Falls back gracefully:
    ///   • Returns `[]` when no source matches `focused.sourceID` in
    ///     the registry — the strategist may have proposed a source
    ///     that's not enabled, or its sourceID didn't parse cleanly
    ///     from the model output.
    ///   • Returns `[]` when the source can't cover the requested
    ///     year window (coverageYearRange check, same as `dispatch`).
    ///
    /// The dispatched query is logged into `searchHistory` by the
    /// pipeline so the audit trail includes both the focused query
    /// and the strategist's `rationale` string.
    func dispatchOne(focused: FocusedQuery, homeChapmanCode: String, cache: QueryCache? = nil) async -> [SourceRecord] {
        guard let source = registry.allSources().first(where: { $0.sourceID == focused.sourceID }) else {
            return []
        }
        let yearRange: (from: Int?, to: Int?) = (focused.yearFrom, focused.yearTo)
        guard sourceCovers(source, yearRange: yearRange) else { return [] }
        let query = focused.toRecordQuery(homeChapmanCode: homeChapmanCode)
        return await QueryCache.wrappedSearch(source: source, query: query, cache: cache)
    }

    /// Walk the strictness ladder for one source. For non-`.all` modes, stop
    /// at the first tier that returns non-empty results. For `.all`, run every
    /// tier and let the outer deduplication collapse overlap.
    ///
    /// T1-01 honesty rule: an empty tier only justifies broadening when
    /// its emptiness is PROVEN — every query in the tier answered
    /// cleanly (availability ok, not truncated) with zero records. When
    /// any query errored, was blocked/throttled, or came back truncated,
    /// the tier's emptiness is an artifact; walking looser tiers would
    /// hammer a failing source and launder the failure into "searched
    /// the whole ladder, found nothing". Stop instead. `.all` mode is
    /// unchanged — it runs every tier by contract, not as a reaction
    /// to emptiness.
    /// FT-04 (county→national self-escalation on a clean-empty FreeBMD
    /// result) lived here from connector-audit `50e3365` until 2026-08-24
    /// — retired under #34 ruling b: the picked scope is the contract on
    /// EVERY dispatch path, staged or not. A subject registered one county
    /// over (the Lydia Kenworthy case) is now reached by deliberately
    /// picking Adjacent/National, never by the dispatcher exceeding the
    /// picker behind the user's back.
    private func dispatchToSource(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        ladder: [SearchStrictness],
        mode: ResearchMode,
        cache: QueryCache?,
        negativeCache: NegativeSearchCache
    ) async -> (records: [SourceRecord], outcomes: [SearchOutcomeEntry]) {
        await walkLadder(
            source: source, subject: subject, recordType: recordType,
            scope: scope, ladder: ladder, mode: mode,
            cache: cache, negativeCache: negativeCache
        )
    }

    /// SOURCE_WEIGHTING Change 2 — why a `.scoped` source builds NO
    /// queries for this (subject, scope), when that is knowable up front.
    /// Nil means "build normally". Pure and static so the skip contract
    /// is testable without a live dispatcher.
    nonisolated static func scopeSkipReason(
        source: any RecordSource, subject: ResearchSubject, scope: ResearchScope
    ) -> String? {
        guard source.scopeHandling == .scoped else { return nil }
        // Only the chapman-code fan-out trio needs a home-county anchor.
        // FamilySearch is .scoped via place-axis LEVEL steering (Change 4)
        // and works anchor-less at every scope — its axes derive from
        // place strings with a country fallback.
        guard ["freebmd", "freecen", "freereg"].contains(source.sourceID) else { return nil }
        if source.sourceID == "freebmd" && scope == .parish {
            return "FreeBMD has no parish endpoint — parish scope deliberately searches nothing here"
        }
        if subject.homeChapmanCode.isEmpty && scope != .national {
            return "no home county (Chapman code) to anchor \(String(describing: scope)) scope — widen to National or set the subject's county"
        }
        return nil
    }

    /// EV7 — the uncited tree fact a (source, recordType) fan-out PUTS ON THE
    /// WIRE, or nil when the fan-out rests only on the subject's own identity.
    ///
    /// A premise counts only where the axis actually reaches the request: a
    /// spouse surname is sent on a marriage index query and nowhere else, and
    /// FreeBMD's mother's-maiden-name column does not exist before Sep 1911,
    /// so a Victorian birth cannot be resting on an MMN it never sent (see the
    /// matching gate in `buildQueries`). Anything looser would mark queries
    /// that never carried the fact, and a caveat attached to the wrong search
    /// teaches the user to ignore caveats.
    ///
    /// Pure and static so the premise contract is testable without a live
    /// dispatcher.
    nonisolated static func unverifiedPremise(
        subject: ResearchSubject, sourceID: String, recordType: RecordType
    ) -> String? {
        for premise in subject.unverifiedKinPremises {
            switch premise.axis {
            case .spouseSurname:
                guard recordType == .marriage,
                      sourceID == "freebmd" || sourceID == "familysearch" else { continue }
            case .motherSurname:
                guard recordType == .birth,
                      sourceID == "freebmd" || sourceID == "familysearch" else { continue }
                if sourceID == "freebmd",
                   (subject.yearRange(for: .birth).from ?? 0) < 1912 { continue }
            }
            return premise.phrase
        }
        return nil
    }

    /// EV19 (2026-08-26) — the sibling of `unverifiedPremise` for the axis
    /// nobody thought of as an assumption: the search REGION.
    ///
    /// William Gladwin (@I332233296774@) carries six FreeBMD *marriage*
    /// negative-searches. The owner found the marriage by hand in one search —
    /// Jun q 1858, GLADWIN, district CHESTERFIELD, 7b/741, GRO-scan verified.
    /// Every one of the six went to Nottinghamshire because his birthplace
    /// "Teversall, Nottinghamshire" selected the region, and that birthplace is
    /// under an OPEN dispute against Ashover, Bolsover and Nottinghamshire.
    ///
    /// Widening the region (see `ResearchSubject.supplementalRegionAxes`) is
    /// only half the repair. `negative_searches` suppresses a re-fire for ~90
    /// days, and a DISPUTED value does not change — the same losing value keeps
    /// winning region selection — so its stored keys keep matching and the
    /// widening looks like it did nothing. (A region that CHANGES self-
    /// invalidates: `districtCode`/`countyCode`/`chapmanCode`/`fagLocation` all
    /// reach `QueryCache.cacheKey`, so new region → new key → the query fires.
    /// Only the disputed-but-unchanged case needs this.) Returning non-nil
    /// disables cross-run suppression for the fan-out AND stops its empties
    /// being banked as durable negatives — exactly EV7's contract, for exactly
    /// EV7's reason: a search is evidence of absence only if its premises hold.
    ///
    /// Scoped per source because the premise is only real where the region
    /// actually reaches the request. Marking a genuinely region-free query
    /// premise-bearing would refuse to bank a conclusive negative, which is the
    /// same class of dishonesty pointed the other way.
    ///
    /// Pure and static so the contract is testable without a live dispatcher.
    nonisolated static func contestedRegionPremise(
        subject: ResearchSubject, sourceID: String, scope: ResearchScope
    ) -> String? {
        guard let phrase = subject.regionPremise else { return nil }
        switch sourceID {
        case "freebmd", "freereg":
            // Both sweep the whole catalogue from `.national` upward — FreeBMD
            // as one `districtid=""` query, FreeREG as the England & Wales
            // code list. No county reaches the wire there, so an empty answer
            // is conclusive whatever the birthplace dispute says.
            guard scope < .national else { return nil }
        case "freecen":
            // FreeCen never drops the county: bounded scopes send the
            // residence chapman, `.adjacent`/`.national` send the BIRTH
            // chapman — which IS the disputed value. The one region-free
            // FreeCen query is the anchor-less national ~90-code sweep.
            guard !(scope >= .national && subject.homeChapmanCode.isEmpty) else { return nil }
        case "familysearch":
            // SOURCE_WEIGHTING Change 4 drops the county-level place axes at
            // `.national`; only `anyPlace` (country) survives, and no county
            // dispute moves a country.
            guard scope < .national else { return nil }
        case "findagrave":
            // FAG pins on the burial place, else the death place, else the
            // birth county — so it rests on a contested birthplace only when
            // nothing better was recorded. `.international` drops the pin.
            guard scope != .international else { return nil }
            let pinnedByEvent = !(subject.burialPlace ?? "").isEmpty
                || !(subject.deathLocation ?? "").isEmpty
            if pinnedByEvent && !subject.contestedRegionFields.contains(.deathLocation) {
                return nil
            }
        default:
            // CWGC, Probate and the local corpora take no region at all —
            // their emptiness is untouched by which county we think this is.
            return nil
        }
        return phrase
    }

    /// Walk the strictness ladder for one source at ONE scope. For
    /// non-`.all` modes, stops at the first tier that returns non-empty
    /// results; broadens past an empty tier only when its emptiness is
    /// conclusive (T1-01). For `.all`, runs every tier by contract.
    /// (Historically split out so FT-04 could re-walk it at `.national`;
    /// FT-04 is retired, the split just keeps the tier-walk readable.)
    private func walkLadder(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        ladder: [SearchStrictness],
        mode: ResearchMode,
        cache: QueryCache?,
        negativeCache: NegativeSearchCache
    ) async -> (records: [SourceRecord], outcomes: [SearchOutcomeEntry]) {
        let ladder = Self.effectiveLadder(ladder, source: source, mode: mode)
        let baseQueries = buildQueries(source: source, subject: subject, recordType: recordType, scope: scope)
        guard !baseQueries.isEmpty else {
            // SOURCE_WEIGHTING Change 2 — a scoped source that builds zero
            // queries is a SKIP, not silence. Record one synthetic outcome
            // (and a feed event) so the searched-surface distinguishes
            // "skipped: reason" from "never searched" and "searched,
            // empty". Non-scoped sources with no queries (e.g. CWGC
            // ineligible subject) stay silent as before — their emptiness
            // is an eligibility rule, not a scope decision.
            if let reason = Self.scopeSkipReason(source: source, subject: subject, scope: scope) {
                await ResearchActivityBus.shared.publish(
                    .sourceSkipped(sourceID: source.sourceID, reason: reason)
                )
                return ([], [SearchOutcomeEntry(
                    sourceID: source.sourceID,
                    recordType: recordType,
                    strictness: ladder.first ?? .strict,
                    queryKey: "scope-skip|\(source.sourceID)|\(recordType.rawValue)|\(String(describing: scope))",
                    outcome: .scopeSkip(reason: reason)
                )])
            }
            return ([], [])
        }

        // EV7 — a tree fact this whole (source, recordType) fan-out rests on
        // that the tree cannot cite. Non-nil disables cross-run suppression
        // for the fan-out and stamps every outcome, so the empties it
        // produces are never banked as durable negatives. Computed once: the
        // premise is a property of the AXES a record type uses, not of the
        // individual wire query.
        // EV19 (2026-08-26) — the region is an axis too, and a region derived
        // from a field still under dispute is exactly the same kind of
        // unproven premise as an uncited spouse surname. Checked second so an
        // uncited kin fact keeps naming itself in the caveat when both apply.
        let premise = Self.unverifiedPremise(
            subject: subject, sourceID: source.sourceID, recordType: recordType)
            ?? Self.contestedRegionPremise(
                subject: subject, sourceID: source.sourceID, scope: scope)
        if let premise {
            await ResearchActivityBus.shared.publish(.pipelineStage(
                message: "\(source.sourceID) \(recordType.rawValue): searched, but the query assumed \(premise), which is unverified — an empty result proves nothing here"
            ))
        }

        var accumulated: [SourceRecord] = []
        var outcomes: [SearchOutcomeEntry] = []
        for strictness in ladder {
            let tierQueries = Self.applyStrictness(
                baseQueries, strictness: strictness, source: source,
                learnedSurnameVariants: learnedSurnameVariants,
                dropOriginalVariantCombination: strictness == .variant
                    && mode == .all && source.sourceID == "freebmd")
            guard !tierQueries.isEmpty else { continue }

            // Dedupe identical queries within the tier — variant fan-out can
            // produce duplicate (source, fields) tuples when a surname has no
            // variants and `.variant` collapses back to a single .strict query.
            let budgetTracker = self.budgetTracker
            let (tierRecords, tierOutcomes) = await withTaskGroup(
                of: (records: [SourceRecord], outcome: SearchOutcomeEntry).self,
                returning: ([SourceRecord], [SearchOutcomeEntry]).self
            ) { tierGroup in
                for query in tierQueries {
                    tierGroup.addTask { [source, query, cache, negativeCache, budgetTracker, premise] in
                        let queryKey = QueryCache.cacheKey(sourceID: source.sourceID, query: query)
                        // T1-04 — cross-run suppression. If a prior run
                        // proved this exact wire query cleanly empty and
                        // it's still fresh, skip the live request and
                        // synthesise the known-empty outcome. No HTTP
                        // request, no QueryCache write; the ladder still
                        // sees a conclusive empty and broadens on merit.
                        // A suppressed query makes NO request, so it is not
                        // counted against the source's daily budget (#Change5).
                        // EV7 — but a stored negative may only silence a
                        // question we asked correctly. Rows written before
                        // this guard existed (the two Gladwin marriage
                        // searches of 21 and 27 Jul 2026 are still inside
                        // their 90-day window) would otherwise keep
                        // suppressing the corrected search for another month.
                        if premise == nil,
                           let suppressed = negativeCache.suppression(forQueryKey: queryKey) {
                            let entry = SearchOutcomeEntry(
                                sourceID: source.sourceID,
                                recordType: query.recordType,
                                strictness: query.strictness,
                                queryKey: queryKey,
                                outcome: suppressed
                            )
                            return ([], entry)
                        }
                        // Count one request against the source's daily budget
                        // only when a WIRE fetch actually happens (#Change5,
                        // corrected 2026-08-23): a per-run cache hit makes no
                        // request the volunteer host could ever see, yet was
                        // being charged — ~4 phantom budget units per profile
                        // per dispatch, dozens across a whole-tree run. The
                        // closure fires inside the cache-miss path; the
                        // tracker persists the count so it survives a restart
                        // mid-run.
                        let (records, outcome) = await QueryCache.wrappedSearchWithOutcome(
                            source: source, query: query, cache: cache,
                            onWireFetch: { await budgetTracker?.recordRequest(source.sourceID) }
                        )
                        let entry = SearchOutcomeEntry(
                            sourceID: source.sourceID,
                            recordType: query.recordType,
                            strictness: query.strictness,
                            queryKey: queryKey,
                            outcome: outcome,
                            unverifiedPremise: premise
                        )
                        return (records, entry)
                    }
                }
                var collected: [SourceRecord] = []
                var collectedOutcomes: [SearchOutcomeEntry] = []
                for await b in tierGroup {
                    collected.append(contentsOf: b.records)
                    collectedOutcomes.append(b.outcome)
                }
                return (collected, collectedOutcomes)
            }
            accumulated.append(contentsOf: tierRecords)
            outcomes.append(contentsOf: tierOutcomes)

            guard mode != .all else { continue }

            // Empty-then-broaden: stop at the first tier that returns a
            // PLAUSIBLE find — not merely at the first tier that returns rows.
            //
            // Rows the human has already discarded are not a find. Counting
            // them made the reviewer's own work narrow the search: reject the
            // wrong candidate, and the wrong candidate goes on suppressing the
            // looser tiers for ever. For a common name in a big county the
            // strict tier will nearly always return SOMETHING, so the profiles
            // that most need broadening were exactly the ones that never did.
            //
            // Note the honesty envelope below already refuses to treat an
            // ERROR as an empty; this is the mirror it was missing — refusing
            // to treat a rejected hit as a find.
            // …and neither is a row the SCORER rules out. The argument above is
            // made for human rejections and left unmade for machine ones, but a
            // woman who died in 1825 when the subject is enumerated alive in
            // 1861 is not a find by anybody's reckoning. Counting her stops the
            // ladder just as surely as a discarded row does — and for a common
            // name in a big county the strict tier will nearly always return
            // some impossible namesake, so this closed the looser tiers off
            // permanently for exactly the profiles that needed them.
            //
            // Owner dogfood 2026-08-23: Mary Stevenson's strict parish tier
            // returned three rows — one discarded by hand, one burial the
            // scorer marked impossible, one marriage at "max age ~0". Two
            // impossibles counted as finds, the ladder stopped, and the
            // `.variant` tier that would have probed the STEPHENSON spelling
            // never ran. Her baptism — the record naming both her parents — was
            // unreachable from inside the app and had to be found by hand.
            //
            // `RecordScorer.classify` is pure over (record, subject, type) and
            // the tier walk holds all three, so this is the SAME classifier the
            // pipeline will apply later, not a second copy of its judgement.
            // …and only a FACT-GRADE find stops the ladder. A lead is a
            // namesake needing review, not an answer — and once the parish
            // window widened to a whole life (b9df57e), every common-surname
            // strict tier returns SOME plausible namesake lead, which under
            // the old `!= .impossible` test suppressed the variant tier
            // permanently: Mary Stephenson's baptism would have been blocked
            // a fourth time, by the interaction of two fixes (confirmed major,
            // 2026-08-23 adversarial sweep — "86674fd defeats 5ab7b2a").
            //
            // The load trade-off is real (leads no longer stop the walk, so
            // more tiers run) and decided deliberately, per the owner's
            // 2026-08-22 ruling: "if 'increases request volume against
            // volunteer-run sources' is blocking a user from gathering actual
            // evidence which is in the source, the self-restriction is
            // failing." Negative caches keep repeat runs cheap, and a
            // gate-clean fact still stops the ladder on the spot.
            let plausible = tierRecords.filter { rec in
                guard !discardedSourceRecordIDs.contains(rec.id) else { return false }
                return RecordScorer.classify(
                    record: rec, subject: subject, searchType: recordType
                ).verdict == .fact
            }
            Self.ladderLog.info("""
                \(source.sourceID, privacy: .public)/\(recordType.rawValue, privacy: .public) \
                tier=\(String(describing: strictness), privacy: .public) \
                queries=\(tierQueries.count, privacy: .public) \
                records=\(tierRecords.count, privacy: .public) \
                plausible=\(plausible.count, privacy: .public) \
                discardedKnown=\(self.discardedSourceRecordIDs.count, privacy: .public) \
                → \(plausible.isEmpty ? "broaden" : "STOP", privacy: .public)
                """)
            if !plausible.isEmpty {
                break
            }
            // Nothing plausible: either genuinely empty, or every row was
            // already rejected. Broaden only when the tier answered cleanly —
            // an errored/throttled/truncated tier is an artifact, and walking
            // on would hammer a failing source and launder the failure into
            // "searched the whole ladder, found nothing".
            //
            // SKIPPED queries are excluded from that judgement. A deliberate
            // non-search carries no information, so it must not veto
            // broadening on behalf of the queries that DID answer. The
            // dispatcher fans census years from `ScoringRules.censusYears`
            // (…1911, 1921) while FreeCen holds only 1841–1911, so every
            // subject whose window reached 1921 carried one skipped query —
            // and one skipped query made the whole tier read as inconclusive,
            // stopping FreeCen at `.strict` for anyone born after ~1850
            // without a death date. If EVERY outcome was skipped then nothing
            // was searched at all and there is nothing to broaden into (the
            // Probate 1922–1995 case), so that still stops.
            let answered = tierOutcomes.filter { !$0.outcome.wasSkipped }
            let tierConclusive = !answered.isEmpty
                && answered.allSatisfy { $0.outcome.isConclusive }
            if !tierConclusive {
                Self.ladderLog.info("""
                    \(source.sourceID, privacy: .public)/\(recordType.rawValue, privacy: .public) \
                    tier=\(String(describing: strictness), privacy: .public) \
                    STOP — tier not conclusive \
                    (answered=\(answered.count, privacy: .public) \
                    skipped=\(tierOutcomes.count - answered.count, privacy: .public))
                    """)
                break
            }
        }
        return (accumulated, outcomes)
    }

    /// Per-source refinement of the mode ladder, applied at the top of
    /// `walkLadder`. FreeBMD's `.loose` is the SAME wire query with the
    /// Phonetic (soundex) flag on — a strict superset of `.strict`'s rows.
    /// In adaptive modes the strict tier pays for itself through early-stop
    /// economy (a strict FACT ends the walk before loose ever fires), but
    /// `.all` runs every tier by contract, so its strict requests are pure
    /// coverage subsets of the loose pass that follows — ~4 requests per
    /// profile whose rows come straight back again (2026-08-23 efficiency
    /// audit). Skip them: same result set, fewer requests against the
    /// touchiest volunteer host.
    nonisolated static func effectiveLadder(
        _ ladder: [SearchStrictness], source: any RecordSource, mode: ResearchMode
    ) -> [SearchStrictness] {
        guard mode == .all, source.sourceID == "freebmd" else { return ladder }
        let trimmed = ladder.filter { $0 != .strict }
        return trimmed.isEmpty ? ladder : trimmed
    }

    /// Strictness ladder per mode — see RESEARCH_AXES_SPEC §3.1 / §5.2.
    /// The dispatcher walks this list for each source, stopping early on the
    /// first non-empty tier (except in `.all` mode, which runs the full list).
    static func strictnessLadder(for mode: ResearchMode) -> [SearchStrictness] {
        switch mode {
        case .verify:   return [.strict]
        case .extend:   return [.strict, .loose]
        case .discover: return [.loose, .variant]
        case .adaptive: return [.strict, .loose, .variant]
        case .all:      return [.strict, .loose, .variant]
        }
    }

    /// T1-12 — drop `(source, recordType)` targets whose base-query set is
    /// wire-identical to an earlier kept target's. `keyProvider` returns the
    /// cache keys a target's base queries would emit; two targets with the
    /// same source and the same SORTED key multiset are the same wire work.
    /// Targets that build ZERO queries are always kept (they are cheap
    /// no-ops in `dispatchToSource` and must never collapse a distinct
    /// empty target). Order-preserving so the first requester of a given
    /// wire query wins and the fan-out stays deterministic.
    private func dedupeWireIdenticalTargets(
        _ targets: [(any RecordSource, RecordType)],
        keyProvider: ((any RecordSource), RecordType) -> [String]
    ) -> [(any RecordSource, RecordType)] {
        var seenFingerprints: Set<String> = []
        var out: [(any RecordSource, RecordType)] = []
        for (source, recordType) in targets {
            let keys = keyProvider(source, recordType)
            guard !keys.isEmpty else {
                out.append((source, recordType))
                continue
            }
            let fingerprint = source.sourceID + "\u{1F}" + keys.sorted().joined(separator: "\u{1E}")
            if seenFingerprints.insert(fingerprint).inserted {
                out.append((source, recordType))
            }
        }
        return out
    }

    // MARK: - Query Building

    /// Derive a soft home-country string for FS's `q.anyPlace` from the
    /// subject's tree region — the country tail of a place string
    /// ("Loscoe, Derbyshire, England" → "England"), or the explicit
    /// UK-nation region. nil when no country is derivable (never hardcoded).
    nonisolated static func homeCountry(from region: Region?) -> String? {
        switch region {
        case .englandAndWales: return "England"
        case .scotland: return "Scotland"
        case .ireland: return "Ireland"
        case .county(let name), .parish(_, county: let name):
            let tail = name.split(separator: ",").last
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return (tail?.isEmpty == false) ? tail : nil
        case .commonwealthMilitary, nil:
            return nil
        }
    }

    /// The home NATION for a Chapman county code, from `RegionConfig` (never a
    /// hardcoded region). This is the fallback soft-country axis for
    /// FamilySearch when the subject's own region carries no country — e.g. a
    /// subject with no tree place data (William Holmes, whose region was nil and
    /// so pulled worldwide same-surname namesakes from FS's global records API).
    /// Biasing to the project's home nation thins that foreign tail; it stays a
    /// re-rank (`q.anyPlace`), never a hard filter, so it can't drop a true record.
    nonisolated static func homeCountry(fromChapmanCode code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let country = RegionConfig.config(forChapmanCode: trimmed)?.country
            .trimmingCharacters(in: .whitespaces)
        return (country?.isEmpty == false) ? country : nil
    }

    /// Compose a jurisdiction string (e.g., "Derbyshire, England") for FamilySearch's
    /// place-axis parameters. FS's documented default behavior is to restrict records
    /// to "within three jurisdiction levels", so "Derbyshire, England" triggers that
    /// bound and excludes USA records. Returns the county if country is nil/empty.
    /// No-op if county is nil/empty.
    nonisolated static func jurisdictionString(
        county: String?,
        region: Region?,
        homeChapmanCode: String
    ) -> String? {
        guard let county, !county.isEmpty else { return nil }
        let country = homeCountry(from: region)
            ?? homeCountry(fromChapmanCode: homeChapmanCode)
        return country.map { "\(county), \($0)" } ?? county
    }

    private func sourceCovers(_ source: any RecordSource, yearRange: (from: Int?, to: Int?)) -> Bool {
        guard let coverage = source.coverageYearRange else { return true }
        let from = yearRange.from ?? Int.min
        let to = yearRange.to ?? Int.max
        return from <= coverage.upperBound && to >= coverage.lowerBound
    }

    #if DEBUG
    /// Test seam for `RESEARCH_AXES_SPEC` Change 3+5 acceptance tests. Lets a test
    /// inspect the per-source query fan-out for a given scope (and optional
    /// strictness) without going through the async network path.
    /// `freeBMDCountyQueriesEnabled` overrides the FT-01 gate so both the
    /// gated county-level emission and the default district loop are testable
    /// without mutating global state.
    func buildQueriesForTest(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        strictness: SearchStrictness = .strict,
        freeBMDCountyQueriesEnabled: Bool = FreeBMDParams.countyQueryEnabled
    ) -> [RecordQuery] {
        let queries = buildQueries(
            source: source, subject: subject, recordType: recordType, scope: scope,
            freeBMDCountyQueriesEnabled: freeBMDCountyQueriesEnabled
        )
        return Self.applyStrictness(
            queries, strictness: strictness, source: source,
            learnedSurnameVariants: learnedSurnameVariants)
    }
    #endif

    // MARK: - FreeBMD geographic fan-out (FT-01 / FT-02)

    /// The geographic axes for FreeBMD queries at a given scope. Each
    /// element becomes one `RecordQuery`; exactly one of the two fields
    /// is non-nil per element (or both nil for a national query):
    ///
    ///   - `.parish`    → zero axes (FreeBMD has no parish endpoint).
    ///   - `.district`/`.county`/`.adjacent`, gate OFF (default) →
    ///     the pre-FT-01 per-district loop over the home county
    ///     (`RegionConfig.districts(forChapmanCode:)` — 12 for DBY).
    ///     `.adjacent` keeps its honest degradation to home-county-only.
    ///   - `.district`/`.county`/`.adjacent`, gate ON → one county-level
    ///     axis per county via the `countyid` form value (FT-01); for
    ///     `.adjacent` that is home + `RegionConfig.adjacentCounties`,
    ///     lifting the old degradation. Counties with no known districts
    ///     resolve to nil and are dropped (parity with the loop's
    ///     zero-query behaviour).
    ///   - `.national` → ONE axis with both fields nil — FreeBMDSource
    ///     emits `districtid=""`, which Python proved is a single
    ///     all-districts query (FT-02; sources/freebmd.py:152-153).
    ///     NOT gated: the wire behaviour is proven, and the overflow
    ///     interstitial on wide result sets is handled by the source's
    ///     adaptive year-split + truncation envelope (FT-05/FT-23).
    ///
    /// Shared by `buildQueries` and `ResearchPipeline.dispatchMarriageQuery`
    /// so the marriage-enrichment flow's fan-out cannot drift from the
    /// main pipeline's (its doc comment promises it mirrors us).
    nonisolated static func freeBMDGeoAxes(
        scope: ResearchScope,
        homeChapmanCode: String,
        countyQueriesEnabled: Bool,
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        surname: String? = nil,
        extraCounties: [String] = [],
        subjectCounties: [String] = []
    ) -> [(districtCode: String?, countyCode: String?)] {
        switch scope {
        case .parish:
            return []
        case .district, .county, .adjacent:
            var counties = [homeChapmanCode]
            if scope == .adjacent {
                counties += RegionConfig.adjacentCounties(homeChapmanCode)
            }
            // EV19 (2026-08-26) — counties the tree evidences about THIS
            // SUBJECT: a rival value of a disputed birthplace, or a place they
            // are attested to have lived (`supplementalRegionAxes`).
            //
            // Deliberately NOT under the `scope >= .adjacent` ceiling that
            // `extraCounties` sits under, and the distinction is the whole
            // fix. The 2026-08-23 ruling governs reaching a county that is
            // admittedly NOT the subject's — a neighbour, a relative's. These
            // are the counties that might BE the subject's, or that the
            // subject demonstrably lived in. When the field that names the
            // home county is under open dispute the home county is not one
            // value, it is a set, and searching the set is what "search his
            // county" MEANS for him; picking one member of it silently is how
            // William Gladwin's marriage went unfound six times in
            // Nottinghamshire while it sat in Chesterfield RD (7b/741).
            for county in subjectCounties
            where !county.isEmpty && !counties.contains(county) {
                counties.append(county)
            }
            // ADDITIVE — the scope's own county is never dropped. FreeCen
            // already merges residence counties and FreeREG already appends a
            // burial county, each for the same reason: the events that matter
            // most are the ones that happened away from where a person was
            // born. FreeBMD never grew that arm, and it is the source where the
            // consequence bites hardest — a death registered in Staffordshire
            // for a Derbyshire-born subject was simply unreachable at county
            // scope. Costs at most one extra county query, and only for
            // subjects who actually moved.
            // …but ONLY from `.adjacent` upward. The scope picker is the
            // contract: a user who chose County asked for their county, and a
            // search that reaches Staffordshire has broken that promise however
            // good its reason. Owner 2026-08-23: "what is visible from the
            // outside is a picker district/county/adjacent — if the inside does
            // not perform like the outside describes, that is the issue."
            //
            // The capability is not lost, it is relocated to the setting that
            // honestly describes it. A death registered a county away is
            // exactly what Adjacent is for.
            if scope >= .adjacent {
                for extra in extraCounties where !extra.isEmpty && !counties.contains(extra) {
                    counties.append(extra)
                }
            }
            let axes: [(districtCode: String?, countyCode: String?)]
            if countyQueriesEnabled {
                // FT-09 — expand umbrella codes (YKS → WRY/NRY/ERY) so a
                // subject anchored on an umbrella county resolves to real
                // county axes instead of silently zero. Dedupe by countyid:
                // .adjacent lists can name both an umbrella (YKS) and one of
                // its constituents (WRY), which would otherwise emit WRY
                // twice.
                var seenCountyIDs: Set<String> = []
                axes = counties.flatMap { code in
                    RegionConfig.freeBMDCountyIDs(forChapmanCode: code)
                }.compactMap { countyID -> (districtCode: String?, countyCode: String?)? in
                    guard seenCountyIDs.insert(countyID).inserted else { return nil }
                    return (districtCode: nil, countyCode: countyID)
                }
            } else {
                // FT-09 — era-filter the per-district loop: a district
                // whose validity window (from the bundled catalogue) does
                // not overlap the search window cannot hold a matching
                // record, so a post-1974 composite (High Peak, Amber
                // Valley, …) is dropped for an 1850s subject instead of
                // burning a guaranteed-empty request. `districts(forChapman
                // Code:)` also expands umbrella codes now (union of the
                // ridings' districts).
                // EV19 (2026-08-26) — home PLUS the subject-evidenced counties,
                // where this branch previously read `homeChapmanCode` alone and
                // silently discarded everything `counties` had accumulated.
                // The FT-01 gate is ON in production so no shipped search was
                // affected, but leaving it would mean the EV19 repair
                // evaporates the moment the gate is flipped back — the exact
                // shape of the 86674fd failure, where the fix and the code the
                // pipeline actually runs were different code.
                //
                // NARROWED, not opened: the adjacency list and `extraCounties`
                // are deliberately NOT here, so the documented gate-off
                // degradation ".adjacent == .county == home-county district
                // loop" still holds for every subject that has no contested
                // birthplace and no attested residence
                // (`geoAxesAdjacentGateOffKeepsHomeCountyDistrictLoop`).
                // Deduped because two counties can share a district code;
                // era-filtered once, over the union.
                var seenDistrictCodes: Set<String> = []
                let codes = ([homeChapmanCode] + subjectCounties)
                    .filter { !$0.isEmpty }
                    .flatMap { RegionConfig.districts(forChapmanCode: $0).values }
                    .filter { seenDistrictCodes.insert($0).inserted }
                let validCodes = Self.eraFilterDistrictCodes(
                    Array(codes), yearFrom: yearFrom, yearTo: yearTo
                )
                axes = validCodes.map { (districtCode: String?.some($0), countyCode: String?.none) }
            }
            // FT-09 — fail loudly (log) when a non-empty chapman resolves to
            // zero axes. An umbrella code we haven't aliased, a county with
            // no catalogue districts, or an era filter that removed every
            // candidate all land here; silent zero was the bug.
            if axes.isEmpty && !homeChapmanCode.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.geoLogger.warning("FreeBMD \(String(describing: scope), privacy: .public) scope resolved chapman '\(homeChapmanCode, privacy: .public)' to ZERO geographic axes (gate=\(countyQueriesEnabled), years=\(yearFrom.map(String.init) ?? "?", privacy: .public)-\(yearTo.map(String.init) ?? "?", privacy: .public)) — no FreeBMD queries will run for this subject")
            }
            return axes
        case .national, .international:
            // Never emit a national `districtid=""` FreeBMD query for a COMMON
            // surname — it returns a massive set whose year-splitter fans out
            // enough requests to throttle the volunteer source (owner report
            // 2026-08-05: national Thompson marriages hammered FreeBMD). This is
            // the single choke point every national FreeBMD query flows through
            // (main sweep and the marriage pivot), so the
            // common-surname block holds regardless of which path reached here.
            // Common names still get county/adjacent coverage; national reach for
            // them isn't worth the hammer.
            if let surname, SurnameRarityRegistry.rarity(of: surname) == .common {
                return []
            }
            return [(districtCode: nil, countyCode: nil)]
        }
    }

    private nonisolated static let geoLogger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "SearchDispatcher.freeBMDGeoAxes"
    )

    /// EV19 (2026-08-26) — how many supplemental places may join Find a
    /// Grave's `location` fan-out. Two.
    ///
    /// FAG takes one location per request and is a scraped PAGE, not an API,
    /// so every extra pin is an extra fetch. Two carries a family that moved
    /// once, or a disputed birthplace with one serious rival, and refuses to
    /// turn a contested profile into a crawl. Lower than
    /// `ResearchSubject.maxSupplementalRegionCounties` on purpose: the
    /// chapman-coded sources batch their codes into one request, FAG cannot.
    nonisolated static let maxFindAGraveExtraPins = 2

    /// FT-09 — keep only district codes whose catalogue validity window
    /// overlaps the search window. When the window is open (both bounds
    /// nil) every code is kept (no basis to filter). A code with no
    /// catalogue entry is kept (unknown validity — we can't prove it
    /// can't match, and the hand-curated DBY map has codes the era filter
    /// shouldn't silently drop). Order-preserving so the wire fan-out is
    /// deterministic.
    nonisolated static func eraFilterDistrictCodes(
        _ codes: [String],
        yearFrom: Int?,
        yearTo: Int?
    ) -> [String] {
        guard yearFrom != nil || yearTo != nil else { return codes }
        let lower = yearFrom ?? Int.min
        let upper = yearTo ?? Int.max
        guard lower <= upper else { return codes }
        let range = lower...upper
        let catalogue = FreeBMDDistrictCatalogue.shared.all()
        // A code can appear on multiple catalogue rows (successor renames);
        // keep it if ANY row with that code overlaps the window. Codes with
        // no catalogue row are kept (unknown validity).
        return codes.filter { code in
            let rows = catalogue.filter { $0.code == code }
            guard !rows.isEmpty else { return true }
            return rows.contains { $0.overlaps(years: range) }
        }
    }

    /// FT-25 / FT-28 — group a broad-scope FreeCen RESIDENCE fan-out into
    /// batched requests. Blank codes (an empty home) are dropped first so a
    /// batch never carries an empty repeated key. When the batching gate is
    /// OFF (the safe default until the repeated-key idiom is probed against
    /// FreeCen's live form — CONNECTOR_AUDIT FT-27), every code is its own
    /// single-element group → one code per request, the proven pre-FT-25
    /// wire shape. When ON, codes chunk into `FreeCenParams.batchGroupSize`
    /// groups. nonisolated + static so ResearchScopeHierarchyTests can pin
    /// the emitted group shape without a live dispatcher.
    nonisolated static func freeCenResidenceGroups(
        _ codes: [String],
        batchingEnabled: Bool = FreeCenParams.multiCodeBatchEnabled,
        groupSize: Int = FreeCenParams.batchGroupSize
    ) -> [[String]] {
        chapmanGroups(codes, batchingEnabled: batchingEnabled, groupSize: groupSize)
    }

    /// FT-25 / FT-28 — group a FreeREG chapman fan-out into batched
    /// requests. Same gate + grouping mechanics as FreeCen (the two Rails
    /// forms share the `chapman_codes[]` idiom); default OFF until probed.
    nonisolated static func freeREGChapmanGroups(
        _ codes: [String],
        batchingEnabled: Bool = FreeREGParams.multiCodeBatchEnabled,
        groupSize: Int = FreeREGParams.batchGroupSize
    ) -> [[String]] {
        chapmanGroups(codes, batchingEnabled: batchingEnabled, groupSize: groupSize)
    }

    /// Shared chunking for the two chapman-batching helpers. Drops blanks,
    /// then: gate off → one code per group; gate on → chunks of `groupSize`
    /// (>=1 clamped). Preserves input order so the wire shape and cache key
    /// are deterministic.
    private nonisolated static func chapmanGroups(
        _ codes: [String],
        batchingEnabled: Bool,
        groupSize: Int
    ) -> [[String]] {
        let cleaned = codes.filter { !$0.isEmpty }
        guard batchingEnabled else { return cleaned.map { [$0] } }
        let size = max(1, groupSize)
        guard cleaned.count > size else { return cleaned.isEmpty ? [] : [cleaned] }
        return stride(from: 0, to: cleaned.count, by: size).map {
            Array(cleaned[$0..<min($0 + size, cleaned.count)])
        }
    }

    /// Apply a non-strict strictness value to a freshly built set of queries.
    ///
    /// - `.strict`: queries are passed through unchanged.
    /// - `.loose`: each query's `strictness` field is set to `.loose` so the
    ///   source can adjust its outbound request (e.g. FreeBMD's Phonetic flag,
    ///   CWGC's Tab=exact omission).
    /// - `.variant`: for variant-supporting sources (FreeBMD, FreeREG, FreeCen),
    ///   each query is fanned out to N+1 queries — the original plus one per
    ///   surname variant from `SurnameVariants.shared`. CWGC falls back to
    ///   `.loose` (it has no useful variant axis distinct from server-side
    ///   soundex). Sources with no variant axis (Probate, FindAGrave)
    ///   fall back to `.strict`. See RESEARCH_AXES_SPEC §7.
    static func applyStrictness(
        _ queries: [RecordQuery],
        strictness: SearchStrictness,
        source: any RecordSource,
        /// Equivalences this tree has confirmed — passed in rather than read
        /// from a static so multi-window projects stay isolated. Defaults empty
        /// so every existing caller and test is unaffected.
        learnedSurnameVariants: [String: [String]] = [:],
        /// `.all`-mode FreeBMD only (set by `walkLadder`): the variant tier
        /// re-emits the original surname × original given as its first
        /// combination — wire-identical to the strict tier's query. With
        /// strict trimmed from the `.all` ladder (see `effectiveLadder`)
        /// that combination would become a live fetch whose rows the loose
        /// pass already returned (soundex ⊇ exact); drop it. Adaptive modes
        /// keep it: there it is a per-run cache hit against the strict tier,
        /// costing nothing.
        dropOriginalVariantCombination: Bool = false
    ) -> [RecordQuery] {
        switch strictness {
        case .strict:
            return queries
        case .loose:
            // Phonetic surname-only search is unbounded — FreeBMD's soundex
            // for a common name like "Wheeldon" matches Wheldon, Weldon,
            // Walden, Welton, … across every Derbyshire district × every
            // record type. With no given-name filter the result set easily
            // crosses 1000+ per source per run (observed: 6,306 hits in
            // ~30min on a surname-only Wheeldon ghost). Downgrade to strict
            // when the query has no given name to keep the query bounded;
            // marriage-enrichment queries (which pass givenName=nil) get
            // the same protection. Caller's ladder still falls through to
            // the variant tier if strict comes back empty.
            return queries.map { q in
                if (q.givenName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    return q.with(strictness: .strict)
                }
                return q.with(strictness: .loose)
            }
        case .variant:
            switch source.sourceID {
            case "freebmd", "freereg", "freecen":
                // Storm guard (Wheeldon/Holmes case): surname-only variant
                // fan-out across a wide year window probes every Welton /
                // Walden / Hulme born in 30+ years × 4 record types ×
                // every district — thousands of unrelated records. Skip
                // the tier when ALL queries are surname-only AND span >5
                // years. Narrow-window probes (e.g. known 1880 birth)
                // stay bounded and useful for spelling variants.
                let allSurnameOnly = queries.allSatisfy {
                    ($0.givenName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                }
                if allSurnameOnly {
                    let widestWindow: Int = queries.map { q -> Int in
                        guard let from = q.yearFrom, let to = q.yearTo else { return .max }
                        return to - from
                    }.max() ?? .max
                    if widestWindow > 5 {
                        return []
                    }
                }
                // MULTIPLICATION GUARD. Spelling breadth and geographic breadth
                // are alternative hypotheses — "recorded under another
                // spelling" or "registered in another county" — and running
                // both at once multiplies rather than adds. Owner dogfood
                // 2026-08-23, watching one profile: `FreeBMD STS county deaths:
                // JACK tomson 1816–1906 (variant)`. That single line is three
                // widenings compounded — a neighbouring county, a surname
                // variant and a nickname — and "Jack Tomson of Staffordshire"
                // is a person who never existed, costing a volunteer's server
                // a request to prove it.
                //
                // Breadth means DISTINCT PLACES, not query count. The first cut
                // used `queries.count` and immediately broke Harriett Holmes's
                // census: FreeCen emits one query per census YEAR, so six years
                // in one county read as six counties, the nickname axis was
                // dropped, and the HARRIETT spelling that found her own census
                // (fix 5c6091c) vanished. Six probes of one place is not a wide
                // search.
                let geoBreadth = Set(queries.map { q -> String in
                    switch q.sourceParams {
                    case .freeBMD(let p):
                        return (p.countyCode ?? p.districtCode ?? "").uppercased()
                    case .freeREG(let p):
                        // FreeREG BATCHES its chapman codes into one request
                        // (repeated `chapman_codes[]` keys on a single POST),
                        // so a code-group is honestly ONE unit of request
                        // breadth however many counties it names — spelling ×
                        // geography multiplication is about REQUEST count, and
                        // a batched query is one request. When the codes ride
                        // outside the params (the default single-county path,
                        // where this is nil), the empty string counts once,
                        // which is likewise correct. (2026-08-23 sweep flagged
                        // the nil; this is the analysis that resolves it.)
                        return (p.chapmanCodes ?? []).sorted().joined(separator: ",").uppercased()
                    case .freeCen(let p):
                        return (p.chapmanCode ?? "").uppercased()
                    default:
                        return ""
                    }
                }).count
                let surnameCap = geoBreadth > 3 ? 2 : Int.max
                let allowGivenFanOut = geoBreadth <= 3
                return queries.flatMap { q -> [RecordQuery] in
                    let original = q.surname ?? ""
                    // Curated seeds UNION generated rules. The JSON holds ~30
                    // hand-picked surnames, so a name outside it was searched
                    // one spelling only — Stevenson was, until its ph-spelling
                    // hid Mary Stephenson's baptism. The rules cover every
                    // surname; the list keeps the irregulars no rule reaches
                    // (Holmes/Hulme, Lee/Leigh).
                    var seenSurnames = Set<String>([original.uppercased()])
                    var variants: [String] = []
                    // LEARNED FIRST. A spelling this tree has already confirmed
                    // outranks a curated seed or a generated guess, and the cap
                    // keeps the head of the list.
                    for v in (learnedSurnameVariants[original.uppercased()] ?? [])
                        + SurnameVariants.shared.variants(of: original)
                        + ScoringRules.orthographicSurnameVariants(of: original)
                    where seenSurnames.insert(v.uppercased()).inserted {
                        variants.append(v)
                    }
                    let fannedSurnames = variants.isEmpty
                        ? [original]
                        : [original] + variants.prefix(surnameCap)

                    // Given-name fan-out (query-side nickname variants): a
                    // person registered under a formal/sibling name — Harry as
                    // HENRY, Elsie as ELIZABETH/BETTY — is otherwise invisible
                    // to every source (the nickname table only scored RETURNED
                    // records). Fan the given name across its equivalence
                    // cluster. Only when a given name is present: surname-only
                    // queries stay on the surname-fan path above and keep the
                    // storm guard. Bounded (clusters are tiny) and the tier's
                    // dedup collapses any collisions.
                    // The cluster covers NICKNAMES (Harry↔Henry). It says nothing
                    // about the same name SPELLED two ways, so a record filed
                    // under HARRIETT was unreachable for a tree holding HARRIET
                    // (owner dogfood 2026-08-22 — her own census was invisible to
                    // every probe). Union the orthographic variants in.
                    let givenName = (q.givenName ?? "").trimmingCharacters(in: .whitespaces)
                    let fannedGivens: [String?]
                    if givenName.isEmpty || !allowGivenFanOut {
                        // Wide geography already: the nickname axis is the
                        // first to drop. A person recorded under a formal name
                        // AND in a county they were never born in AND spelled
                        // differently is a hypothesis too far to spend a
                        // volunteer's bandwidth on.
                        fannedGivens = [q.givenName]
                    } else {
                        var seen = Set<String>([givenName.uppercased()])
                        var extras: [String] = []
                        for v in ScoringRules.givenNameVariants(of: givenName)
                            + ScoringRules.orthographicGivenNameVariants(of: givenName)
                        where seen.insert(v.uppercased()).inserted {
                            extras.append(v)
                        }
                        fannedGivens = [q.givenName] + extras
                    }

                    // Each fanned-out query carries strictness=.variant so the
                    // dispatcher's tier-walk and activity-bus events reflect
                    // the intended tier — the source may still treat it as
                    // strict-on-the-wire (Phonetic=false), because the variant
                    // IS the exact surname/given name for that probe.
                    return fannedSurnames.flatMap { s in
                        fannedGivens.compactMap { g -> RecordQuery? in
                            if dropOriginalVariantCombination,
                               s.uppercased() == original.uppercased(),
                               (g ?? "").uppercased() == (q.givenName ?? "").uppercased() {
                                return nil
                            }
                            return q.with(surname: s).with(givenName: g).with(strictness: .variant)
                        }
                    }
                }
            case "cwgc":
                // No useful variant axis distinct from server soundex per §7.
                return queries.map { $0.with(strictness: .loose) }
            default:
                // Strict-only sources (Probate, FindAGrave).
                // Stamp the requested tier so activity-bus events reflect
                // dispatcher intent; the source's wire behaviour is unchanged
                // regardless of strictness because they don't branch on it.
                return queries.map { $0.with(strictness: .variant) }
            }
        }
    }

    private func buildQueries(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        freeBMDCountyQueriesEnabled: Bool = FreeBMDParams.countyQueryEnabled
    ) -> [RecordQuery] {
        let yearRange = subject.yearRange(for: recordType)

        switch source.sourceID {
        case "freebmd":
            // Geographic fan-out per scope — see `freeBMDGeoAxes` (FT-01 /
            // FT-02). Nil-surname subjects (ghost mothers) skip FreeBMD.
            //
            // Per RESEARCH_AXES_SPEC §5.3 + §7:
            //   .parish    → zero queries (FreeBMD has no parish endpoint).
            //   .district  → transitional widen to .county (subject lacks
            //                structured location code until prior spec Change 2).
            //   .county    → per-district loop (FT-01 gate off) or one
            //                county-level `countyid` query (gate on).
            //   .adjacent  → same, plus adjacent counties when gate on.
            //   .national  → ONE `districtid=""` query (FT-02) — replaces
            //                the old 632–996-request year-filtered catalogue
            //                fan-out. Overflow is recovered by the source's
            //                adaptive year-split; unrecoverable overflow
            //                surfaces as a truncated envelope, never as a
            //                silent empty.
            guard subject.surname != nil else { return [] }
            // A death or burial is registered where the person DIED, which for
            // anyone who moved is not their birth county. Death-shaped record
            // types therefore also probe the subject's own death and burial
            // counties. Birth and marriage are unchanged: a birth belongs to the
            // birth county by definition, and a marriage is registered in the
            // bride's district, which we do not hold.
            var deathShapedCounties: [String] = []
            if recordType == .death || recordType == .burial {
                if let deathCounty = subject.deathLocation
                    .flatMap({ ResearchSubject.chapmanCode(forPlaceText: $0) }) {
                    deathShapedCounties.append(deathCounty)
                }
                if let burialCounty = subject.burialChapmanCode {
                    deathShapedCounties.append(burialCounty)
                }
            }
            // Counties the tree evidences the FAMILY in, one edge away — a
            // spouse's or child's birthplace, a child's census page (EV8).
            // They sit in the SAME `extraCounties` arm as the death/burial
            // counties beside them, and so under the same `.adjacent`
            // ceiling: the 2026-08-23 ruling is that a County search reaches
            // exactly the county the picker names, whatever the reason, and a
            // county inferred from a relative is a weaker reason than the
            // subject's own recorded death place, not a stronger one.
            let kinCounties = subject.kinResidenceAxes.map(\.chapmanCode)
            let geoAxes = Self.freeBMDGeoAxes(
                scope: scope,
                homeChapmanCode: subject.homeChapmanCode,
                countyQueriesEnabled: freeBMDCountyQueriesEnabled,
                yearFrom: yearRange.from,
                yearTo: yearRange.to,
                surname: subject.surname,
                extraCounties: (deathShapedCounties + kinCounties).flatMap {
                    RegionConfig.expandUmbrellaChapmanCode($0)
                },
                // EV19 (2026-08-26) — counties evidenced about the SUBJECT
                // (contested birthplace rivals, own residences/censuses).
                // Already umbrella-expanded and capped at derivation; unlike
                // `extraCounties` they apply at every bounded scope, for the
                // reason `freeBMDGeoAxes` states.
                subjectCounties: subject.supplementalRegionCodes
            )
            // FreeBMD's s_surname field is overloaded per record type
            // (see FreeBMDSource): spouse surname for marriages,
            // mother's maiden name for births, unused for deaths.
            // Dispatcher fills the correct axis from FamilyContext.
            //
            // MMN gating: GRO birth indexes only carry mother's maiden
            // name from Sep 1911. Filtering pre-Sep-1911 births by MMN
            // returns zero hits because the column is empty for that
            // era. Gate on yearFrom >= 1912 so we only attach MMN when
            // the entire year window is in the MMN era (1911 itself is
            // ambiguous — Q1–Q2 lacks MMN, Q3–Q4 has it). Spec §23.
            // For `.marriage`, fan out across the wife's recorded surname
            // AND her maiden surname when the import inverted the wikitree
            // convention. `spouseFatherSurname` holds the maiden form (the
            // wife's father's `lastName` on the tree). Symmetric to the
            // female-side `surnamesToProbe` widening, but operating across
            // the profile boundary because the maiden axis lives on the
            // SPOUSE'S parent, not the subject's. Models the Ernest
            // Cauldwell case: wife Sarah Cauldwell is recorded under her
            // married surname (`lastName = "Cauldwell"`), but her real
            // maiden surname "Ward" is recoverable via her father Joseph
            // Ward. Without this widening every FreeBMD marriage probe
            // fires as `Cauldwell × Cauldwell` and misses the canonical
            // `Cauldwell × Ward` index entry.
            //
            // Nil for non-marriage queries (FreeBMD's s_surname overload
            // means we never want a spouse surname on births/deaths).
            // Returns `[nil]` when no spouse is on the context — the
            // existing single-pass behaviour for unmarried subjects.
            let spouseSurnamesForBMD: [String?] = {
                guard recordType == .marriage else { return [nil] }
                let recorded = subject.familyContext?.spouseSurname
                let maiden = subject.familyContext?.spouseFatherSurname
                var out: [String?] = [recorded]
                if let maiden,
                   !maiden.isEmpty,
                   maiden.caseInsensitiveCompare(recorded ?? "") != .orderedSame {
                    out.append(maiden)
                }
                return out
            }()
            let spouseGivenForBMD: String? = (recordType == .marriage) ? subject.familyContext?.spouseGivenName : nil
            let motherSurnameForBMD: String? = {
                guard recordType == .birth else { return nil }
                guard let yf = yearRange.from, yf >= 1912 else { return nil }
                return subject.familyContext?.motherSurname
            }()
            // Surname fan-out: death-shape and post-marriage census record
            // types probe both maiden and married surnames for women whose
            // tree-stored `surname` is the maiden name. See
            // `ResearchSubject.surnamesToProbe`.
            let surnamesToTry = subject.surnamesToProbe(for: recordType)
            return surnamesToTry.flatMap { surnameToTry in
                spouseSurnamesForBMD.flatMap { spouseSurnameForBMD in
                    geoAxes.map { geo in
                        RecordQuery(
                            surname: surnameToTry,
                            givenName: subject.givenName,
                            recordType: recordType,
                            yearFrom: yearRange.from,
                            yearTo: yearRange.to,
                            gender: subject.gender,
                            region: subject.region,
                            sourceParams: .freeBMD(FreeBMDParams(
                                districtCode: geo.districtCode,
                                countyCode: geo.countyCode,
                                wildcardSurname: false,
                                motherSurname: motherSurnameForBMD,
                                spouseSurname: spouseSurnameForBMD
                            )),
                            spouseGivenName: spouseGivenForBMD
                        )
                    }
                }
            }

        case "freecen":
            // Per applicable census year × Chapman codes (1 for .local, ~90 for .national).
            // Intersect the subject's window with the years FreeCen actually
            // HOLDS. `ScoringRules.censusYears` runs to 1921; FreeCen stops at
            // 1911, so an unfiltered fan-out spent one request per subject on
            // a year the source rejects out of hand — and, until the skipped-
            // outcome fix above, that single rejection stopped the whole
            // strictness ladder (owner dogfood 2026-08-22).
            let censusYears = ScoringRules.censusYears.filter { year in
                let from = yearRange.from ?? 1841
                let to = yearRange.to ?? 1911
                return year >= from && year <= to && FreeCenSource.validYears.contains(year)
            }
            // Per RESEARCH_AXES_SPEC §5.3 — FreeCen is chapman-coded, not
            // district-coded, so .parish/.district widen to .county.
            // (FT-13: parish/place scoping via `freecen2_place_ids[]` is a
            // deferred capability — `FreeCenParams` has no parish field;
            // the previous comment here pointed at a seam that was never
            // built.)
            //
            // FT-11 — geographic axis by scope:
            // - `.county` (and narrower): RESIDENCE county
            //   (`chapman_codes[]`) — the historical behaviour.
            // - `.adjacent`/`.national`: BIRTH county
            //   (`birth_chapman_codes[]`) as the primary axis — ONE query
            //   with no residence filter reaches subjects wherever they
            //   lived at census time (migrants included), on exactly the
            //   field the scorer trusts most, instead of ~7 (adjacent) or
            //   ~90 (national) residence-county queries per census year.
            //   With no derivable home chapman code (empty = no anchor):
            //   at `.national` the fallback residence sweep is real (~90
            //   GB codes); at `.adjacent` (and narrower scopes) the
            //   "fallback" degenerates to a single empty-code query that
            //   FreeCenSource's guard rejects as `.outsideCoverage` — the
            //   contract-correct outcome (an anchor-less subject cannot
            //   honour a bounded scope; widening would exceed the user's
            //   bound). Change 2 short-circuits it in this branch: zero
            //   axes, and walkLadder records the visible scope-skip.
            let home = subject.homeChapmanCode
            // Exactly one axis per query. residenceCodes carries a BATCH
            // (FT-25/FT-28) — a single code stays a one-element array, so
            // the source emits a byte-identical single-key request. The
            // birth axis is always a single code (broad census sweeps scope
            // by birth county as ONE code — no fan-out to batch there).
            // EV19 (2026-08-26) — the `.adjacent`/`.national` axis on the wire
            // is `birth_chapman_codes[]`, a BIRTH axis built from the very
            // field that may be under dispute. When it is, every rival value's
            // county earns its own birth axis: one of them is his birthplace
            // and we do not know which. Only `.contestedField` codes for
            // `.birthLocation` qualify — a county the subject merely LIVED in
            // is not a birth county, and putting it here would be a wrong
            // axis rather than a wider one. Empty list → byte-identical
            // behaviour to before for every undisputed subject.
            func birthAxes(_ homeCode: String) -> [(residenceCodes: [String], birth: String?)] {
                var out: [(residenceCodes: [String], birth: String?)] = [
                    (residenceCodes: [], birth: homeCode),
                ]
                for code in subject.contestedBirthRegionCodes
                where !code.isEmpty && code != homeCode {
                    out.append((residenceCodes: [], birth: code))
                }
                return out
            }
            let cenGeoAxes: [(residenceCodes: [String], birth: String?)]
            switch scope {
            case .parish, .district, .county:
                // Change 2 — an anchor-less subject has no residence code
                // to scope by: build nothing; walkLadder records the
                // visible scope-skip.
                cenGeoAxes = home.isEmpty ? [] : [([home], nil)]
            case .adjacent:
                if home.isEmpty {
                    // Change 2 — the old "fallback residence fan-out" here
                    // built [""] + neighbours("") = one dead empty-code
                    // query the source refused as outsideCoverage.
                    // Adjacent-of-nothing is unanswerable: build nothing;
                    // walkLadder records the visible scope-skip.
                    cenGeoAxes = []
                } else {
                    cenGeoAxes = birthAxes(home)
                }
            case .national, .international:
                if home.isEmpty {
                    let entries: [UKChapmanCode] = UKChapmanCodes.shared.gbAndChannelIslands()
                    // FT-28 — batch the ~90-code national residence sweep.
                    cenGeoAxes = Self.freeCenResidenceGroups(entries.map { $0.code }).map { ($0, nil) }
                } else {
                    cenGeoAxes = birthAxes(home)
                }
            }
            let birthRange = subject.birthYearFrom.flatMap { from in
                subject.birthYearTo.map { to in from...to }
            }
            let cenSurnames = subject.surnamesToProbe(for: .census)
            // Stage 2 (life events feed research axes) — a Residence
            // LifeEvent whose year window covers a census year contributes
            // its COUNTY chapman to that year's probe set. ADDITIVE soft
            // targeting: the home county's own query is never dropped or
            // reshaped — the merged code list is routed back through
            // `freeCenResidenceGroups`, so with the FT-27 batching gate
            // OFF (the repeated `chapman_codes[]` wire idiom is unverified)
            // each code stays its own proven single-code query, and with
            // the gate ON they batch as FT-25/FT-28 intend. Umbrella codes
            // expand (YKS → WRY/NRY/ERY) — FreeCEN's form doesn't tag the
            // umbrella itself. BOUNDED SCOPES ONLY: the .adjacent/.national
            // birth-axis and anchor-less ~90-code sweeps already reach
            // residents in every county.
            //
            // Owner 2026-08-24 (#34 ruling c): BLESSED at bounded scopes.
            // This arm is deliberately EXEMPT from the 2026-08-23 "scope
            // picker is the contract" gating applied to the FreeBMD and
            // FreeREG arms: residence axes are the user's own attested
            // Residence LifeEvents (R3 data), so a County search reaching a
            // residence county is the tree's stated knowledge, not
            // speculative widening — additive, census-year-bounded, home
            // county never dropped. The blessing covers exactly this
            // behaviour; it does not cover the anchor-less-subject skip
            // (SUBJECT_PLACE_MODEL Slice 5) or the FT-27 batching gate.
            //
            // Kin-derived counties (`subject.kinResidenceAxes`) ride the same
            // arm on the same terms. A subject whose ONLY place fact is a
            // birthplace has no residence events to contribute, and that is
            // precisely the person the census sweep fails on: William Gladwin,
            // born Teversall NTT, had every one of his eight census-year
            // probes sent to Nottinghamshire while he lived his adult life in
            // Derbyshire and the West Riding (owner dogfood 2026-08-25). The
            // counties that would have found him were on the tree the whole
            // time, one edge away, on his wife and his daughter.
            let residenceCodesApply: Bool
            switch scope {
            case .parish, .district, .county: residenceCodesApply = true
            case .adjacent, .national, .international: residenceCodesApply = false
            }
            func residenceCodes(coveringCensusYear year: Int) -> [String] {
                subject.residenceAxes
                    .filter { $0.covers(year) }
                    .compactMap { $0.chapmanCode }
                    .flatMap { RegionConfig.expandUmbrellaChapmanCode($0) }
                    // Kin-derived counties carry no window. The evidence
                    // behind them — a wife's birthplace, a child's census
                    // page — says WHERE the family was, not for which years,
                    // and a year window invented to bound them would be a
                    // fact we do not have. They join every census year the
                    // subject is probed for; already umbrella-expanded at
                    // derivation, and capped at two.
                    + subject.kinResidenceAxes.map(\.chapmanCode)
                    // EV19 (2026-08-26) — and the counties evidenced about the
                    // SUBJECT: rival values of a disputed birthplace, plus
                    // their own residence AND census places. Census places are
                    // new here: `residenceAxes` reads only `.residence` events,
                    // so a household enumerated together — the strongest
                    // statement of where a family lived that the tree holds —
                    // fed no search axis at all before this. Windowless for the
                    // same reason the kin axes are: the evidence says WHERE,
                    // not for which years, and a window invented to bound it
                    // would be a fact we do not have.
                    + subject.supplementalRegionCodes
            }
            return cenSurnames.flatMap { surnameToTry in
                censusYears.flatMap { year in
                    cenGeoAxes.flatMap { geo -> [(residenceCodes: [String], birth: String?)] in
                        guard residenceCodesApply, !geo.residenceCodes.isEmpty else {
                            return [geo]
                        }
                        var merged = geo.residenceCodes
                        var seen = Set(merged)
                        for code in residenceCodes(coveringCensusYear: year)
                        where seen.insert(code).inserted {
                            merged.append(code)
                        }
                        return Self.freeCenResidenceGroups(merged).map { ($0, geo.birth) }
                    }.map { geo in
                        let residenceCodes = geo.residenceCodes
                        // A single-element residence group is passed as the
                        // scalar `chapmanCode` (byte-identical wire + cache
                        // key to the pre-FT-25 shape); a multi-element group
                        // becomes the `chapmanCodes` batch.
                        let single = residenceCodes.count == 1 ? residenceCodes[0] : nil
                        let batch = residenceCodes.count > 1 ? residenceCodes : nil
                        return RecordQuery(
                            surname: surnameToTry,
                            givenName: subject.givenName,
                            recordType: .census,
                            yearFrom: year,
                            yearTo: year,
                            gender: subject.gender,
                            region: subject.region,
                            sourceParams: .freeCen(FreeCenParams(
                                chapmanCode: single,
                                chapmanCodes: batch,
                                censusYear: year,
                                birthYearRange: birthRange,
                                birthChapmanCode: geo.birth
                            ))
                        )
                    }
                }
            }

        case "freereg":
            // Per Chapman code × applicable register types.
            // Local = 1 Chapman code; National = ~70 (England & Wales) covering FreeREG's reach.
            // Per RESEARCH_AXES_SPEC §5.3 — FreeREG is chapman-coded.
            // Same widening pattern as FreeCen.
            guard subject.surname != nil else { return [] }
            let regChapmanCodes: [String]
            switch scope {
            case .parish, .district, .county:
                regChapmanCodes = [subject.homeChapmanCode]
            case .adjacent:
                // Change 3 — expand umbrella codes (YKS → WRY/NRY/ERY)
                // exactly as FreeBMD does, then dedupe preserving order:
                // the adjacency list can name both YKS and WRY, and an
                // unexpanded umbrella is a code FreeREG's form doesn't
                // tag (SCOPE_AUDIT finding 7).
                var seenReg: Set<String> = []
                regChapmanCodes = ([subject.homeChapmanCode]
                    + RegionConfig.adjacentCounties(subject.homeChapmanCode))
                    .flatMap { RegionConfig.expandUmbrellaChapmanCode($0) }
                    .filter { seenReg.insert($0).inserted }
            case .national, .international:
                let entries: [UKChapmanCode] = UKChapmanCodes.shared.englandAndWales()
                regChapmanCodes = entries.map { $0.code }
            }
            // FT-28 — batch the ~7 (adjacent) / ~70 (national) code fan-out
            // into conservative groups when enabled; otherwise one code per
            // query. A single-code group is passed as the scalar
            // `chapmanCode` (byte-identical wire + cache key to pre-FT-25);
            // a multi-code group becomes the `chapmanCodes` batch.
            // Stage 2 (life events feed research axes) — a Burial
            // LifeEvent's county joins the burial probe. ADDITIVE (the
            // scope's own codes are never dropped), so a burial recorded
            // outside the home county is still reachable at bounded
            // scopes. Umbrella codes expand (YKS → WRY/NRY/ERY) exactly as
            // the .adjacent arm does — FreeREG's form doesn't tag the
            // umbrella itself, so an unexpanded append would be a dead
            // probe. At .national the E&W sweep already includes the
            // constituents and the per-constituent check dedups.
            var regCodesWithBurial = regChapmanCodes
            // EV19 (2026-08-26) — counties evidenced about the SUBJECT: a
            // rival value of a disputed birthplace, or a place they are
            // attested to have lived. Applied at EVERY scope, ahead of the
            // `.adjacent` ceiling below, and the difference is the fix.
            //
            // FreeREG is the parish half of EV19 and the more visible one:
            // `get_scored_records` on William Gladwin returned 84 rows, 42 of
            // them FreeREG parish records and almost entirely Nottinghamshire
            // namesake noise (GOULDING, GOLDING, GILDING, GOULTON, GLEADEN at
            // Gringley on the Hill, Walkeringham, Misterton, Ordsall,
            // Babworth, Mattersey, Carlton in Lindrick, Worksop, Mansfield,
            // Edwinstowe, Nottingham). That is the radius his disputed
            // Teversall birthplace bought; Dronfield, Unstone, Whittington and
            // Brampton were never swept.
            for code in subject.supplementalRegionCodes
            where !code.isEmpty && !regCodesWithBurial.contains(code) {
                regCodesWithBurial.append(code)
            }
            // …but only from `.adjacent` upward, matching the FreeBMD arm
            // (cd3aa8b): the scope picker is the contract, and a County search
            // must never reach another county however good the reason. The
            // capability moves to the setting that honestly describes it
            // (2026-08-23 sweep residual, same defect class).
            if scope >= .adjacent {
                if recordType == .burial, let burialCode = subject.burialChapmanCode {
                    for code in RegionConfig.expandUmbrellaChapmanCode(burialCode)
                    where !regCodesWithBurial.contains(code) {
                        regCodesWithBurial.append(code)
                    }
                }
                // Counties the tree evidences the FAMILY in, one edge away
                // (EV8). Unlike the burial county this is not tied to a
                // register type: a family that moved was baptising, marrying
                // and burying wherever it was living, so every FreeREG
                // register type reaches them. Same `.adjacent` ceiling and the
                // same additive rule — the scope's own codes are never
                // dropped, and the list is already umbrella-expanded and
                // capped at two.
                for code in subject.kinResidenceAxes.map(\.chapmanCode)
                where !regCodesWithBurial.contains(code) {
                    regCodesWithBurial.append(code)
                }
            }
            // Change 2 — drop empty codes (anchor-less subject): a [""]
            // axis was a dead query the source refused as outsideCoverage.
            // Zero usable codes → zero queries → walkLadder records the
            // visible scope-skip.
            let usableRegCodes = regCodesWithBurial.filter { !$0.isEmpty }
            let regCodeGroups = Self.freeREGChapmanGroups(usableRegCodes)
            // FreeREG splits by register type; recordType drives this on the source side.
            let regSurnames = subject.surnamesToProbe(for: recordType)
            return regSurnames.flatMap { surnameToTry in
                regCodeGroups.map { group in
                    let single = group.count == 1 ? group[0] : nil
                    let batch = group.count > 1 ? group : nil
                    return RecordQuery(
                        surname: surnameToTry,
                        givenName: subject.givenName,
                        recordType: recordType,
                        yearFrom: yearRange.from,
                        yearTo: yearRange.to,
                        gender: subject.gender,
                        region: subject.region,
                        sourceParams: .freeREG(FreeREGParams(
                            chapmanCode: single,
                            chapmanCodes: batch
                        ))
                    )
                }
            }

        case "wishful-thinking-mi":
            // TEMPLATED_NARRATIVE_SOURCE_SPEC Stage 2 — an MI is a burial-shaped
            // record. Fill the URL template from the county Chapman code + the
            // parish where the subject would be memorialised: their burial or death
            // place, else a HOME/RESIDENCE parish from the census. Residences are
            // filtered to the subject's own county (chapman match, or unknown) so
            // the parish always pairs with `homeChapmanCode` — never
            // /home-county/other-county-parish/. First candidate that resolves to
            // an England & Wales parish wins. No county anchor or no parish → no
            // query. One templated page per lookup, never a guessed URL or a crawl.
            guard !subject.homeChapmanCode.isEmpty,
                  let parish = MemorialInscriptionRecordSource.homeParish(
                    burialPlace: subject.burialPlace,
                    deathLocation: subject.deathLocation,
                    residences: subject.residenceAxes.map { ($0.place, $0.chapmanCode) },
                    homeChapman: subject.homeChapmanCode)
            else { return [] }
            return [RecordQuery(
                surname: subject.surname, givenName: subject.givenName,
                recordType: recordType, yearFrom: yearRange.from, yearTo: yearRange.to,
                gender: subject.gender, region: subject.region,
                sourceParams: .memorialInscription(MemorialInscriptionParams(
                    chapmanCode: subject.homeChapmanCode, parish: parish)))]

        case "cwgc":
            // Interval eligibility (T1-08, wired 2026-07-30 — the predicate
            // was built and tested but the dispatcher still ran the old
            // single-point birth-year test, so males with approximate
            // birth WINDOWS straddling the ranges, or a war-years death
            // and no birth year at all, were never searched).
            if CWGCSource.isMilitaryEligible(
                gender: subject.gender,
                birthYearFrom: subject.birthYearFrom,
                birthYearTo: subject.birthYearTo,
                deathYearFrom: subject.deathYearFrom,
                deathYearTo: subject.deathYearTo
            ) {
                return [RecordQuery(
                    surname: subject.surname,
                    givenName: subject.givenName,
                    recordType: .death,
                    yearFrom: yearRange.from,
                    yearTo: yearRange.to,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .cwgc(CWGCParams(conflict: nil))
                )]
            }
            return []

        case "familysearch":
            // FamilySearch accepts a wide axis set — surname/given plus
            // birth/death place, spouse surname+given, and father/mother
            // surname+given. Each axis tightens the search. Subject-side
            // values come from Profile + linked-relative profiles via
            // FamilyContext; nil-defaults safely skip parameters we
            // can't fill. Spec §23.
            let context = subject.familyContext
            let fsSurnames = subject.surnamesToProbe(for: recordType)
            return fsSurnames.map { surnameToTry in
                // Match each place axis to the record type it belongs to.
                // Sending every place axis on every query biases FamilySearch's
                // relevance ranking toward the WRONG record kind: a death search
                // that also carries q.birthLikePlace + q.residenceLikePlace ranks
                // CENSUS personas (which have birth places and residences) above
                // the real death record (a funeral notice / obituary has
                // neither), burying it off the single fetched page. So gate:
                //   • birthPlace     → birth-shape axes only
                //   • deathPlace     → death-shape axes only (fall back to the
                //     home region when the death place is unknown — people
                //     usually die near home; a soft `q.deathLikePlace` re-rank,
                //     never a hard filter, so it can't drop a non-local death)
                //   • residencePlace → census only
                //   • marriagePlace  → marriage only
                // `anyPlace` (soft country) still applies across axes. All
                // tree-derived — the no-hardcoded-regions invariant holds.
                // (#Change6 residence scoping is preserved, now correctly
                // census-only.)
                //
                // FAMILY axes are gated by the same principle: an axis rides
                // only the record kinds that CARRY it. UK civil death / burial /
                // probate records are parent-less (the GRO death index has
                // name, age, district — no parents), so father/mother axes on
                // a death-shape query boost parent-carrying personas
                // (christenings, censuses) and bury the actual death
                // registration below the single fetched page. Proven live on
                // George Eric Vaughn Cauldwell's 1986 DeathRegistration: an
                // axis-isolation probe ranked it #1 without parent axes and
                // ABSENT from the top-100 with them. Post-1837 civil marriage
                // indexes are parent-less too. So:
                //   • parents (father/mother) → birth-shape, parish
                //     (christenings name parents) and census (household)
                //   • spouse → marriage, census, and death-shape (funeral
                //     notices, probate widows, FAG memorials genuinely carry
                //     spouses — Kenneth's confirmed 2007 funeral notice
                //     surfaced WITH the spouse axis on); never birth-shape /
                //     parish (a christening persona has no spouse)
                // This mirrors the FreeBMD dispatcher rules ("death queries
                // carry no mother/spouse surname"), which encode the same
                // record-content reality for the same underlying GRO indexes.
                let homeCounty: String? = subject.region.flatMap { region in
                    if case .county(let name) = region { return name }
                    return nil
                }
                // SOURCE_WEIGHTING Change 4 — scope steers the axis LEVEL.
                // FS place params are single-value fuzzy matches (documented:
                // "records within three jurisdiction levels"), so adjacency
                // cannot fan the axis; the honest mapping is county-level
                // axes at bounded scopes and NO county axis at .national —
                // a county soft-axis at national scope re-ranks remote true
                // records below the single fetched page, a de-facto filter
                // the user's scope choice rejected (SCOPE_AUDIT finding 1).
                // `anyPlace` (country) still applies at every scope; known
                // event places (deathLocation, marriageLocation) are real
                // evidence and ride at every scope too.
                let scopedCounty: String? = scope == .national ? nil : homeCounty
                let fsBirthPlace: String?
                switch recordType {
                case .birth, .baptism, .christening: fsBirthPlace = Self.jurisdictionString(
                    county: scopedCounty, region: subject.region, homeChapmanCode: subject.homeChapmanCode
                )
                default: fsBirthPlace = nil
                }
                let fsDeathPlace: String?
                switch recordType {
                case .death, .burial:
                    // Stage 2 (life events feed research axes) — for BURIAL
                    // queries a Burial LifeEvent's place is the best axis:
                    // it says where they were buried, which deathLocation
                    // only approximates. Death queries keep deathLocation
                    // (where they died ≠ where they're buried). Soft
                    // re-rank axis either way (q.deathLikePlace).
                    if recordType == .burial,
                       let bp = subject.burialPlace, !bp.isEmpty {
                        fsDeathPlace = bp
                    } else if let dl = subject.deathLocation, !dl.isEmpty {
                        fsDeathPlace = dl
                    } else {
                        fsDeathPlace = Self.jurisdictionString(
                            county: scopedCounty, region: subject.region, homeChapmanCode: subject.homeChapmanCode
                        )
                    }
                default:
                    fsDeathPlace = nil
                }
                // Stage 2 — a Residence LifeEvent supplies the census
                // residence place: the user's attested knowledge beats the
                // scoped-county guess. Selection is by REAL census-year
                // coverage (the axis must cover at least one census year
                // inside the subject's window — a mere lifespan overlap is
                // near-always true and would gate nothing), preferring the
                // axis covering the most census years; deterministic
                // tie-break by window start then place. The chosen place is
                // COMPOSED with its county name ("Youlgreave, Derbyshire")
                // so the soft axis never loses county context — a bare
                // village string could fuzzy-match the wrong county's
                // namesake and re-rank the true record away. Census-only,
                // soft re-rank (q.residenceLikePlace) — the record-type
                // gating discipline of this branch is unchanged.
                let fsResidencePlace: String?
                if recordType == .census {
                    let windowCensusYears = ScoringRules.censusYears.filter { year in
                        year >= (yearRange.from ?? 1841) && year <= (yearRange.to ?? 1911)
                    }
                    let best = subject.residenceAxes
                        .map { axis in
                            (axis: axis, coverage: windowCensusYears.filter(axis.covers).count)
                        }
                        .filter { $0.coverage > 0 }
                        .sorted { a, b in
                            if a.coverage != b.coverage { return a.coverage > b.coverage }
                            if (a.axis.yearFrom ?? Int.min) != (b.axis.yearFrom ?? Int.min) {
                                return (a.axis.yearFrom ?? Int.min) < (b.axis.yearFrom ?? Int.min)
                            }
                            return a.axis.place < b.axis.place
                        }
                        .first?.axis
                    if let axis = best {
                        let countyName = axis.chapmanCode
                            .map { RecordScorer.countyName(forChapman: $0) }
                            .flatMap { $0.isEmpty ? nil : $0 }
                            ?? scopedCounty
                        if let county = countyName,
                           !axis.place.lowercased().contains(county.lowercased()) {
                            fsResidencePlace = "\(axis.place), \(county)"
                        } else {
                            fsResidencePlace = axis.place
                        }
                    } else {
                        fsResidencePlace = Self.jurisdictionString(
                            county: scopedCounty, region: subject.region, homeChapmanCode: subject.homeChapmanCode
                        )
                    }
                } else {
                    fsResidencePlace = nil
                }
                let fsMarriagePlace: String? = (recordType == .marriage) ? context?.marriageLocation : nil
                let parentAxesApply: Bool
                switch recordType {
                case .birth, .baptism, .christening, .parish, .census: parentAxesApply = true
                default: parentAxesApply = false
                }
                let spouseAxesApply: Bool
                switch recordType {
                case .marriage, .census, .death, .burial, .probate: spouseAxesApply = true
                default: spouseAxesApply = false
                }
                return RecordQuery(
                    surname: surnameToTry,
                    givenName: subject.givenName,
                    recordType: recordType,
                    yearFrom: yearRange.from,
                    yearTo: yearRange.to,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .generic,
                    birthPlace: fsBirthPlace,
                    deathPlace: fsDeathPlace,
                    residencePlace: fsResidencePlace,
                    marriagePlace: fsMarriagePlace,
                    // Soft country axis to thin the tail of same-surname
                    // records from other countries — derived from the
                    // subject's tree place data (the country tail of the
                    // home place string, or the explicit UK-nation region),
                    // never a hardcoded region. Falls back to the project's
                    // home-region nation when the subject itself carries no
                    // region, so FamilySearch's GLOBAL records API is still
                    // biased to the home nation (records-source live finding
                    // 2026-07-21: region-less subjects pulled worldwide
                    // namesakes) — config-derived, still no hardcoded region.
                    anyPlace: Self.homeCountry(from: subject.region)
                        ?? Self.homeCountry(fromChapmanCode: subject.homeChapmanCode),
                    spouseSurname: spouseAxesApply ? context?.spouseSurname : nil,
                    spouseGivenName: spouseAxesApply ? context?.spouseGivenName : nil,
                    fatherSurname: parentAxesApply ? context?.fatherSurname : nil,
                    fatherGivenName: parentAxesApply ? context?.fatherGivenName : nil,
                    motherSurname: parentAxesApply ? context?.motherSurname : nil,
                    motherGivenName: parentAxesApply ? context?.motherGivenName : nil
                )
            }

        case "findagrave":
            // FAG's `location` query param filters memorials by burial
            // location free-text (state / town / cemetery). deathLocation
            // is the closest semantic match for where someone is buried;
            // fall back to region (county name from birthLocation) when
            // death location is unknown. Spec §23.
            // EV19 (2026-08-26) — FAG takes ONE `location` per request, so a
            // subject whose pin can only come from the birth county gets one
            // pin per candidate place instead of one guess.
            //
            // Only the weakest rung fans out. A recorded burial place, or a
            // death place, is a fact about where this person ended up and
            // needs no help; the birth-county fallback is the rung that is a
            // guess, and when the birthplace is disputed it is a guess about a
            // guess. The supplemental places lead with residences, which is
            // the right prior for a grave anyway — people are buried where
            // they lived, not where they were born.
            let fagLocations: [String?] = {
                // DS-11/DS-19: at International scope, drop the location pin so
                // Find a Grave searches worldwide by name — the whole point is
                // to surface an emigrant's overseas grave, which a UK-county
                // pin would exclude.
                if scope == .international { return [nil] }
                // Stage 2 (life events feed research axes) — a Burial
                // LifeEvent's place IS the burial location FAG filters on;
                // it beats the deathLocation approximation, which beats the
                // birth-county guess.
                if let bp = subject.burialPlace, !bp.isEmpty { return [bp] }
                if let dl = subject.deathLocation, !dl.isEmpty { return [dl] }
                var out: [String?] = []
                if case .county(let name) = subject.region { out.append(name) }
                // Capped hard: FAG is a scraped page, not an API, and one
                // extra pin is one extra fetch. Two is enough to carry a
                // family that moved once, or a birthplace with one serious
                // rival, and refuses to turn a disputed profile into a crawl.
                for place in subject.supplementalRegionPlaces
                    .prefix(Self.maxFindAGraveExtraPins)
                where !out.contains(where: {
                    ($0 ?? "").caseInsensitiveCompare(place) == .orderedSame
                }) {
                    out.append(place)
                }
                // Unchanged for a subject with nothing to pin on: one query,
                // no location filter.
                return out.isEmpty ? [nil] : out
            }()
            // T1-16 (fetch half) — subject-side year axes. FAG's
            // birthyear/deathyear are SEPARATE person-fact axes, so they
            // are populated from the subject's own birth/death windows,
            // never from the record-type search window (`yearRange` /
            // query.yearFrom/To): for `.burial` that window is
            // death-year ± 2 — or, when death is unknown, the
            // birth+15..birth+95 guess — and the pre-removal code that
            // mapped its bounds onto birthyear/deathyear asked FAG for a
            // birthyear=2015/deathyear=2019 child when the subject
            // actually DIED ~2017. A burial search keys on the death
            // year when one is known; the birth year rides along as an
            // independent narrowing when known. No real death window →
            // no death filter (the fallback guess is unrepresentable
            // inside FAG's ±25 max tolerance and would manufacture
            // false negatives — FindAGraveSource.yearAxis drops any
            // window that wide anyway).
            let fagBirthRange: ClosedRange<Int>? = subject.birthYearFrom.map { bf in
                bf...max(subject.birthYearTo ?? bf, bf)
            }
            let fagDeathRange: ClosedRange<Int>? = subject.deathYearFrom.map { df in
                df...max(subject.deathYearTo ?? df, df)
            }
            let fagSurnames = subject.surnamesToProbe(for: recordType)
            return fagSurnames.flatMap { surnameToTry in
                fagLocations.map { fagLocation in
                    RecordQuery(
                        surname: surnameToTry,
                        givenName: subject.givenName,
                        recordType: recordType,
                        yearFrom: yearRange.from,
                        yearTo: yearRange.to,
                        gender: subject.gender,
                        region: subject.region,
                        sourceParams: .findAGrave(FindAGraveParams(
                            yearRangeWidth: 5,
                            location: fagLocation,
                            birthYearRange: fagBirthRange,
                            deathYearRange: fagDeathRange,
                            // `limit` stays at the wire default (20) for
                            // first-pass probes; a truncated-page raise is a
                            // caller decision via this dispatcher-settable
                            // param — no automatic skip-loops (T1-16).
                            //
                            // T1-23 — female subjects: also match `lastname`
                            // against the memorial's maiden-name field.
                            // Mirrors the maiden-axis gating in
                            // `surnamesToProbe` (gender == .female is the
                            // trigger): the wikitree convention stores women
                            // under maiden surname while inverted imports
                            // carry the married form, and the flag makes
                            // either probe find a memorial filed the other
                            // way round. Broadening-only, so no era/record-
                            // type gate is needed.
                            includeMaidenName: subject.gender == .female
                        ))
                    )
                }
            }

        default:
            // SOURCE_WEIGHTING Change 1 — a source declaring `.scoped`
            // must have a dedicated scope-aware branch above; landing
            // here means that branch is missing and generic queries would
            // silently ignore the user's scope bound (SCOPE_AUDIT finding
            // 5). Refuse loudly instead of building unscoped queries.
            if source.scopeHandling == .scoped {
                Self.geoLogger.error("Source \(source.sourceID, privacy: .public) declares .scoped but has no scope-aware buildQueries branch — refusing to build unscoped queries")
                return []
            }
            // Generic single query for declared inherently-national /
            // anchor-pinned / local-corpus sources (Probate, and future
            // DECLARED sources). Fan-out to married surname when
            // applicable — critical for Probate (UK Calendar files
            // married women under married surname).
            let genericSurnames = subject.surnamesToProbe(for: recordType)
            return genericSurnames.map { surnameToTry in
                RecordQuery(
                    surname: surnameToTry,
                    givenName: subject.givenName,
                    recordType: recordType,
                    yearFrom: yearRange.from,
                    yearTo: yearRange.to,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .generic
                )
            }
        }
    }

    // MARK: - Deduplication

    private func deduplicate(_ records: [SourceRecord]) -> [SourceRecord] {
        var seen: Set<String> = []
        return records.filter { record in
            let key = "\(record.common.sourceID):\(record.common.id)"
            return seen.insert(key).inserted
        }
    }
}
