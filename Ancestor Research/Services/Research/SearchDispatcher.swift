import Foundation

/// Dispatches searches across all applicable sources.
/// Knows source-specific patterns: multi-district for FreeBMD, per-census-year for FreeCen.
/// Sources are dumb pipes — the dispatcher builds the queries.
@MainActor
struct SearchDispatcher {
    let registry: SourceRegistry

    /// Dispatch searches across all enabled sources for the given record types.
    /// `scope` widens fan-out for scope-aware sources (FreeBMD; FreeCen/FreeREG later).
    /// Local plugins (Wirksworth) and inherently-national sources (CWGC, FindAGrave,
    /// Probate) ignore scope.
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
    func dispatchWithOutcomes(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>,
        scope: ResearchScope = .county,
        mode: ResearchMode = .extend,
        cache: QueryCache? = nil
    ) async -> (records: [SourceRecord], outcomes: [SearchOutcomeEntry]) {
        let ladder = Self.strictnessLadder(for: mode)

        // Enumerate (source, recordType) targets. Per-source coverage check
        // stays in this top loop — we don't dispatch tiers to sources that
        // can't cover the year window at all.
        var targets: [(any RecordSource, RecordType)] = []
        for recordType in recordTypes {
            let yearRange = subject.yearRange(for: recordType)
            for source in registry.enabledSources(for: recordType, region: subject.region) {
                guard sourceCovers(source, yearRange: yearRange) else { continue }
                targets.append((source, recordType))
            }
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
                        scope: scope,
                        ladder: ladder,
                        mode: mode,
                        cache: cache
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
    private func dispatchToSource(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        ladder: [SearchStrictness],
        mode: ResearchMode,
        cache: QueryCache?
    ) async -> (records: [SourceRecord], outcomes: [SearchOutcomeEntry]) {
        let baseQueries = buildQueries(source: source, subject: subject, recordType: recordType, scope: scope)
        guard !baseQueries.isEmpty else { return ([], []) }

        var accumulated: [SourceRecord] = []
        var outcomes: [SearchOutcomeEntry] = []
        for strictness in ladder {
            let tierQueries = Self.applyStrictness(baseQueries, strictness: strictness, source: source)
            guard !tierQueries.isEmpty else { continue }

            // Dedupe identical queries within the tier — variant fan-out can
            // produce duplicate (source, fields) tuples when a surname has no
            // variants and `.variant` collapses back to a single .strict query.
            let (tierRecords, tierOutcomes) = await withTaskGroup(
                of: (records: [SourceRecord], outcome: SearchOutcomeEntry).self,
                returning: ([SourceRecord], [SearchOutcomeEntry]).self
            ) { tierGroup in
                for query in tierQueries {
                    tierGroup.addTask { [source, query, cache] in
                        let (records, outcome) = await QueryCache.wrappedSearchWithOutcome(
                            source: source, query: query, cache: cache
                        )
                        let entry = SearchOutcomeEntry(
                            sourceID: source.sourceID,
                            recordType: query.recordType,
                            strictness: query.strictness,
                            queryKey: QueryCache.cacheKey(sourceID: source.sourceID, query: query),
                            outcome: outcome
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

            // Empty-then-broaden: stop at the first tier with results.
            if !tierRecords.isEmpty {
                break
            }
            // Empty tier — broaden only when the emptiness is conclusive.
            let tierConclusive = tierOutcomes.allSatisfy { $0.outcome.isConclusive }
            if !tierConclusive {
                break
            }
        }
        return (accumulated, outcomes)
    }

    /// Strictness ladder per mode — see RESEARCH_AXES_SPEC §3.1 / §5.2.
    /// The dispatcher walks this list for each source, stopping early on the
    /// first non-empty tier (except in `.all` mode, which runs the full list).
    static func strictnessLadder(for mode: ResearchMode) -> [SearchStrictness] {
        switch mode {
        case .verify:   return [.strict]
        case .extend:   return [.strict, .loose]
        case .discover: return [.loose, .variant]
        case .all:      return [.strict, .loose, .variant]
        }
    }

    // MARK: - Query Building

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
        return Self.applyStrictness(queries, strictness: strictness, source: source)
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
        countyQueriesEnabled: Bool
    ) -> [(districtCode: String?, countyCode: String?)] {
        switch scope {
        case .parish:
            return []
        case .district, .county, .adjacent:
            if countyQueriesEnabled {
                var counties = [homeChapmanCode]
                if scope == .adjacent {
                    counties += RegionConfig.adjacentCounties(homeChapmanCode)
                }
                return counties.compactMap { code in
                    RegionConfig.freeBMDCountyID(forChapmanCode: code)
                        .map { (districtCode: String?.none, countyCode: String?.some($0)) }
                }
            }
            return RegionConfig.districts(forChapmanCode: homeChapmanCode)
                .values.map { (districtCode: String?.some($0), countyCode: String?.none) }
        case .national:
            return [(districtCode: nil, countyCode: nil)]
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
    ///   soundex). Sources with no variant axis (Probate, Wirksworth, FindAGrave)
    ///   fall back to `.strict`. See RESEARCH_AXES_SPEC §7.
    static func applyStrictness(
        _ queries: [RecordQuery],
        strictness: SearchStrictness,
        source: any RecordSource
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
                return queries.flatMap { q -> [RecordQuery] in
                    let original = q.surname ?? ""
                    let variants = SurnameVariants.shared.variants(of: original)
                    let fannedSurnames = variants.isEmpty ? [original] : [original] + variants
                    // Each fanned-out query carries strictness=.variant so the
                    // dispatcher's tier-walk and activity-bus events reflect
                    // the intended tier — the source may still treat it as
                    // strict-on-the-wire (Phonetic=false), because the variant
                    // IS the exact surname for that probe.
                    return fannedSurnames.map { q.with(surname: $0).with(strictness: .variant) }
                }
            case "cwgc":
                // No useful variant axis distinct from server soundex per §7.
                return queries.map { $0.with(strictness: .loose) }
            default:
                // Strict-only sources (Probate, Wirksworth, FindAGrave).
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
            let geoAxes = Self.freeBMDGeoAxes(
                scope: scope,
                homeChapmanCode: subject.homeChapmanCode,
                countyQueriesEnabled: freeBMDCountyQueriesEnabled
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
            let censusYears = ScoringRules.censusYears.filter { year in
                let from = yearRange.from ?? 1841
                let to = yearRange.to ?? 1911
                return year >= from && year <= to
            }
            // Per RESEARCH_AXES_SPEC §5.3 — FreeCen is chapman-coded, not
            // district-coded, so .district widens to .county. Parish-level
            // restriction would happen via FreeCenParams.parish, which we
            // can't populate until prior spec Change 2 ships birthLocationCode.
            let cenChapmanCodes: [String]
            switch scope {
            case .parish, .district, .county:
                cenChapmanCodes = [subject.homeChapmanCode]
            case .adjacent:
                cenChapmanCodes = [subject.homeChapmanCode]
                    + RegionConfig.adjacentCounties(subject.homeChapmanCode)
            case .national:
                let entries: [UKChapmanCode] = UKChapmanCodes.shared.gbAndChannelIslands()
                cenChapmanCodes = entries.map { $0.code }
            }
            let birthRange = subject.birthYearFrom.flatMap { from in
                subject.birthYearTo.map { to in from...to }
            }
            let cenSurnames = subject.surnamesToProbe(for: .census)
            return cenSurnames.flatMap { surnameToTry in
                censusYears.flatMap { year in
                    cenChapmanCodes.map { code in
                        RecordQuery(
                            surname: surnameToTry,
                            givenName: subject.givenName,
                            recordType: .census,
                            yearFrom: year,
                            yearTo: year,
                            gender: subject.gender,
                            region: subject.region,
                            sourceParams: .freeCen(FreeCenParams(
                                chapmanCode: code,
                                censusYear: year,
                                birthYearRange: birthRange
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
                regChapmanCodes = [subject.homeChapmanCode]
                    + RegionConfig.adjacentCounties(subject.homeChapmanCode)
            case .national:
                let entries: [UKChapmanCode] = UKChapmanCodes.shared.englandAndWales()
                regChapmanCodes = entries.map { $0.code }
            }
            // FreeREG splits by register type; recordType drives this on the source side.
            let regSurnames = subject.surnamesToProbe(for: recordType)
            return regSurnames.flatMap { surnameToTry in
                regChapmanCodes.map { code in
                    RecordQuery(
                        surname: surnameToTry,
                        givenName: subject.givenName,
                        recordType: recordType,
                        yearFrom: yearRange.from,
                        yearTo: yearRange.to,
                        gender: subject.gender,
                        region: subject.region,
                        sourceParams: .freeREG(FreeREGParams(
                            registerType: nil,
                            parish: nil,
                            chapmanCode: code
                        ))
                    )
                }
            }

        case "cwgc":
            // Only for military-eligible males
            guard subject.gender == .male || subject.gender == nil else { return [] }
            if let birthYear = subject.birthYearFrom,
               !ScoringRules.militaryEligible(birthYear: birthYear, gender: .male).isEmpty {
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
                RecordQuery(
                    surname: surnameToTry,
                    givenName: subject.givenName,
                    recordType: recordType,
                    yearFrom: yearRange.from,
                    yearTo: yearRange.to,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .generic,
                    birthPlace: subject.region.flatMap { region in
                        if case .county(let name) = region { return name }
                        return nil
                    },
                    deathPlace: subject.deathLocation,
                    spouseSurname: context?.spouseSurname,
                    spouseGivenName: context?.spouseGivenName,
                    fatherSurname: context?.fatherSurname,
                    fatherGivenName: context?.fatherGivenName,
                    motherSurname: context?.motherSurname,
                    motherGivenName: context?.motherGivenName
                )
            }

        case "findagrave":
            // FAG's `location` query param filters memorials by burial
            // location free-text (state / town / cemetery). deathLocation
            // is the closest semantic match for where someone is buried;
            // fall back to region (county name from birthLocation) when
            // death location is unknown. Spec §23.
            let fagLocation: String? = {
                if let dl = subject.deathLocation, !dl.isEmpty { return dl }
                if case .county(let name) = subject.region { return name }
                return nil
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
            return fagSurnames.map { surnameToTry in
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

        default:
            // Generic single query for Probate, Wirksworth, and any
            // future sources without dispatcher-side custom axes.
            // Fan-out to married surname when applicable — critical
            // for Probate (UK Calendar files married women under married
            // surname).
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
