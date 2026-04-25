import Foundation

/// Dispatches searches across all applicable sources.
/// Knows source-specific patterns: multi-district for FreeBMD, per-census-year for FreeCen.
/// Sources are dumb pipes — the dispatcher builds the queries.
@MainActor
struct SearchDispatcher {
    let registry: SourceRegistry
    let regionConfig: RegionConfig

    /// Dispatch searches across all enabled sources for the given record types.
    func dispatch(
        subject: ResearchSubject,
        recordTypes: Set<RecordType>
    ) async -> [SourceRecord] {
        let allQueries = buildAllQueries(subject: subject, recordTypes: recordTypes)

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
        recordTypes: Set<RecordType>
    ) -> [(any RecordSource, RecordQuery)] {
        var pairs: [(any RecordSource, RecordQuery)] = []

        // Skip searches for unsearchable people (born after 1930)
        if let birthYear = subject.birthYearFrom, birthYear > 1930 {
            return []
        }

        for recordType in recordTypes {
            for source in registry.enabledSources(for: recordType, region: subject.region) {
                let queries = buildQueries(source: source, subject: subject, recordType: recordType)
                pairs.append(contentsOf: queries.map { (source, $0) })
            }
        }
        return pairs
    }

    private func buildQueries(
        source: any RecordSource,
        subject: ResearchSubject,
        recordType: RecordType
    ) -> [RecordQuery] {
        let yearRange = subject.yearRange(for: recordType)

        switch source.sourceID {
        case "freebmd":
            // Multi-district: one query per configured district
            // Nil-surname subjects (ghost mothers) skip FreeBMD
            guard subject.surname != nil else { return [] }
            return regionConfig.districts.map { (_, code) in
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
            // Per applicable census year
            let censusYears = ScoringRules.censusYears.filter { year in
                let from = yearRange.from ?? 1841
                let to = yearRange.to ?? 1911
                return year >= from && year <= to
            }
            return censusYears.map { year in
                RecordQuery(
                    surname: subject.surname,
                    givenName: subject.givenName,
                    recordType: .census,
                    yearFrom: year,
                    yearTo: year,
                    gender: subject.gender,
                    region: subject.region,
                    sourceParams: .freeCen(FreeCenParams(
                        chapmanCode: regionConfig.chapmanCode,
                        censusYear: year,
                        birthYearRange: subject.birthYearFrom.flatMap { from in
                            subject.birthYearTo.map { to in from...to }
                        }
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
