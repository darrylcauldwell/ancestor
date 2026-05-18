import Foundation

/// Dispatches searches across all applicable sources.
/// Knows source-specific patterns: multi-district for FreeBMD, per-census-year for FreeCen.
/// Sources are dumb pipes — the dispatcher builds the queries.
@MainActor
struct SearchDispatcher {
    let registry: SourceRegistry
    let regionConfig: RegionConfig

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
        mode: ResearchMode = .extend
    ) async -> [SourceRecord] {
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

        return await withTaskGroup(of: [SourceRecord].self) { group in
            for (source, recordType) in targets {
                group.addTask { [source, recordType] in
                    await self.dispatchToSource(
                        source: source,
                        subject: subject,
                        recordType: recordType,
                        scope: scope,
                        ladder: ladder,
                        mode: mode
                    )
                }
            }
            var combined: [SourceRecord] = []
            for await batch in group {
                combined.append(contentsOf: batch)
            }
            return deduplicate(combined)
        }
    }

    /// Walk the strictness ladder for one source. For non-`.all` modes, stop
    /// at the first tier that returns non-empty results. For `.all`, run every
    /// tier and let the outer deduplication collapse overlap.
    private func dispatchToSource(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        ladder: [SearchStrictness],
        mode: ResearchMode
    ) async -> [SourceRecord] {
        let baseQueries = buildQueries(source: source, subject: subject, recordType: recordType, scope: scope)
        guard !baseQueries.isEmpty else { return [] }

        var accumulated: [SourceRecord] = []
        for strictness in ladder {
            let tierQueries = Self.applyStrictness(baseQueries, strictness: strictness, source: source)
            guard !tierQueries.isEmpty else { continue }

            // Dedupe identical queries within the tier — variant fan-out can
            // produce duplicate (source, fields) tuples when a surname has no
            // variants and `.variant` collapses back to a single .strict query.
            let batch = await withTaskGroup(of: [SourceRecord].self) { tierGroup in
                for query in tierQueries {
                    tierGroup.addTask { [source, query] in
                        await source.search(query).records
                    }
                }
                var collected: [SourceRecord] = []
                for await b in tierGroup {
                    collected.append(contentsOf: b)
                }
                return collected
            }
            accumulated.append(contentsOf: batch)

            // Empty-then-broaden: stop at the first tier with results unless
            // mode == .all (which always runs every tier).
            if mode != .all && !batch.isEmpty {
                break
            }
        }
        return accumulated
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
    func buildQueriesForTest(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType,
        scope: ResearchScope,
        strictness: SearchStrictness = .strict
    ) -> [RecordQuery] {
        let queries = buildQueries(source: source, subject: subject, recordType: recordType, scope: scope)
        return Self.applyStrictness(queries, strictness: strictness, source: source)
    }
    #endif

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
        scope: ResearchScope
    ) -> [RecordQuery] {
        let yearRange = subject.yearRange(for: recordType)

        switch source.sourceID {
        case "freebmd":
            // Multi-district: one query per configured district.
            // Nil-surname subjects (ghost mothers) skip FreeBMD.
            //
            // Per RESEARCH_AXES_SPEC §5.3 + §7:
            //   .parish    → zero queries (FreeBMD has no parish endpoint).
            //   .district  → transitional widen to .county (subject lacks
            //                structured location code until prior spec Change 2).
            //   .county    → RegionConfig.districts(forChapmanCode:) — formerly .local.
            //   .adjacent  → falls back to .county for FreeBMD: the catalogue
            //                lacks per-district Chapman affiliation, so we can't
            //                enumerate adjacent-county districts without that data.
            //                Honest degradation; logged via spec note.
            //   .national  → full catalogue, year-filtered.
            guard subject.surname != nil else { return [] }
            let districtCodes: [String]
            switch scope {
            case .parish:
                return []
            case .district, .county, .adjacent:
                districtCodes = Array(
                    RegionConfig.districts(forChapmanCode: subject.homeChapmanCode).values
                )
            case .national:
                let entries = FreeBMDDistrictCatalogue.shared.covering(
                    yearFrom: yearRange.from, yearTo: yearRange.to
                )
                districtCodes = entries.map(\.code)
            }
            return districtCodes.map { code in
                RecordQuery(
                    surname: subject.surname,
                    givenName: subject.givenName,
                    recordType: recordType,
                    yearFrom: yearRange.from,
                    yearTo: yearRange.to,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .freeBMD(FreeBMDParams(
                        districtCode: code,
                        wildcardSurname: false,
                        motherSurname: nil,
                        spouseSurname: nil
                    ))
                )
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
            return censusYears.flatMap { year in
                cenChapmanCodes.map { code in
                    RecordQuery(
                        surname: subject.surname,
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
            return regChapmanCodes.map { code in
                RecordQuery(
                    surname: subject.surname,
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

        default:
            // Generic single query for FindAGrave and others
            return [RecordQuery(
                surname: subject.surname,
                givenName: subject.givenName,
                recordType: recordType,
                yearFrom: yearRange.from,
                yearTo: yearRange.to,
                gender: subject.gender,
                region: subject.region,
                sourceParams: .generic
            )]
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
