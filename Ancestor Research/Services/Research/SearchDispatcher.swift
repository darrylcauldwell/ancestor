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
        _ = mode  // Reserved for Change 6 — empty-then-broaden flow.
        let allQueries = buildAllQueries(subject: subject, recordTypes: recordTypes, scope: scope)

        return await withTaskGroup(of: [SourceRecord].self) { group in
            for (source, query) in allQueries {
                group.addTask { [source, query] in
                    await source.search(query).records
                }
            }
            var combined: [SourceRecord] = []
            for await batch in group {
                combined.append(contentsOf: batch)
            }
            return deduplicate(combined)
        }
    }

    // MARK: - Query Building

    private func buildAllQueries(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>,
        scope: ResearchScope
    ) -> [(any RecordSource, RecordQuery)] {
        var pairs: [(any RecordSource, RecordQuery)] = []

        for recordType in recordTypes {
            let yearRange = subject.yearRange(for: recordType)
            for source in registry.enabledSources(for: recordType, region: subject.region) {
                // Per-source coverage: skip sources whose declared year range can't
                // overlap the relevant event window. Sources with no declared range
                // (unbounded) always pass.
                guard sourceCovers(source, yearRange: yearRange) else { continue }
                let queries = buildQueries(source: source, subject: subject, recordType: recordType, scope: scope)
                pairs.append(contentsOf: queries.map { (source, $0) })
            }
        }
        return pairs
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
            return queries.map { $0.with(strictness: .loose) }
        case .variant:
            switch source.sourceID {
            case "freebmd", "freereg", "freecen":
                return queries.flatMap { q -> [RecordQuery] in
                    let original = q.surname ?? ""
                    let variants = SurnameVariants.shared.variants(of: original)
                    guard !variants.isEmpty else { return [q] }
                    // Original query + one per variant. Each fanned-out query
                    // is itself .strict (the variant IS the exact surname for
                    // that probe); the .variant tier is a fan-out construct.
                    let fannedSurnames = [original] + variants
                    return fannedSurnames.map { q.with(surname: $0) }
                }
            case "cwgc":
                // No useful variant axis distinct from server soundex.
                return queries.map { $0.with(strictness: .loose) }
            default:
                // Probate, Wirksworth, FindAGrave — strict-only.
                return queries
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
