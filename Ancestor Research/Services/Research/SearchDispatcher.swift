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
    func dispatch(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>,
        scope: ResearchScope = .local
    ) async -> [SourceRecord] {
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
            // .local → regionConfig.districts (home-county, ~12 entries).
            // .national → FreeBMDDistrictCatalogue, year-filtered to skip districts
            //             that weren't operating in the subject's window (~600 instead of 1125).
            guard subject.surname != nil else { return [] }
            let districtCodes: [String]
            switch scope {
            case .local:
                districtCodes = Array(regionConfig.districts.values)
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
            let cenChapmanCodes: [String]
            switch scope {
            case .local:
                cenChapmanCodes = [regionConfig.chapmanCode]
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
            guard subject.surname != nil else { return [] }
            let regChapmanCodes: [String]
            switch scope {
            case .local:
                regChapmanCodes = [regionConfig.chapmanCode]
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
