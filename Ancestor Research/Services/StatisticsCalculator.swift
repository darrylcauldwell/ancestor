import Foundation

/// Pure helper computing aggregate metrics across a `FamilyGraphSnapshot`
/// and the project's `ResearchSession` log. Drives the read-only
/// Statistics dashboard (DESIGN.md §13 platform extensions).
///
/// All operations are deterministic — ties on counts are broken
/// alphabetically so the dashboard renders identically across runs.
nonisolated enum StatisticsCalculator {

    nonisolated struct ProjectStatistics: Sendable {
        let profileCount: Int
        let livingPotentially: Int
        let averageLifespanYears: Double?
        let medianDeathYear: Int?
        let topSurnames: [SurnameCount]
        let topBirthLocations: [LocationCount]
        let topDeathLocations: [LocationCount]
        let sourceCoveragePercent: Int
        let sourcedFieldCount: Int
        let valuedFieldCount: Int
        let maxAncestorGenerations: Int
        let maxDescendantGenerations: Int
        let totalAncestorsFromHome: Int
        let totalDescendantsFromHome: Int
        let totalHoursInvested: Double
    }

    /// Counted bucket for the surnames histogram. Plain struct keeps the
    /// public surface Sendable without needing a labelled tuple.
    nonisolated struct SurnameCount: Sendable, Hashable {
        let surname: String
        let count: Int
    }

    nonisolated struct LocationCount: Sendable, Hashable {
        let location: String
        let count: Int
    }

    /// Tracked ProfileFields contributing to source-coverage. The 8 cells
    /// below cover everything a manual researcher would cite in a profile.
    private static let trackedFields: [ProfileField] = [
        .firstName, .lastName, .gender,
        .birthDate, .birthLocation,
        .deathDate, .deathLocation,
        .bio,
    ]

    static func compute(
        snapshot: FamilyGraphSnapshot,
        homePersonID: String?,
        sessions: [ResearchSession]
    ) -> ProjectStatistics {
        let livingProfiles = snapshot.profiles.values.filter { !$0.isDeleted }
        let profileCount = livingProfiles.count
        let livingPotentially = livingProfiles.filter { $0.deathDate == nil }.count

        let lifespan = computeAverageLifespan(profiles: livingProfiles)
        let medianDeathYear = computeMedianDeathYear(profiles: livingProfiles)
        let topSurnames = computeTopSurnames(profiles: livingProfiles, limit: 10)
        let topBirth = computeTopLocations(profiles: livingProfiles, keyPath: \.birthLocation, limit: 20)
        let topDeath = computeTopLocations(profiles: livingProfiles, keyPath: \.deathLocation, limit: 20)
        let coverage = computeSourceCoverage(profiles: livingProfiles)

        let (maxAncestor, maxDescendant, totalAncestors, totalDescendants) =
            computeGenerations(snapshot: snapshot, homePersonID: homePersonID)

        let totalHours = sessions.reduce(0.0) { acc, session in
            let end = session.endedAt ?? Date()
            let elapsed = end.timeIntervalSince(session.startedAt)
            return acc + max(0, elapsed)
        } / 3600.0

        return ProjectStatistics(
            profileCount: profileCount,
            livingPotentially: livingPotentially,
            averageLifespanYears: lifespan,
            medianDeathYear: medianDeathYear,
            topSurnames: topSurnames,
            topBirthLocations: topBirth,
            topDeathLocations: topDeath,
            sourceCoveragePercent: coverage.percent,
            sourcedFieldCount: coverage.sourced,
            valuedFieldCount: coverage.valued,
            maxAncestorGenerations: maxAncestor,
            maxDescendantGenerations: maxDescendant,
            totalAncestorsFromHome: totalAncestors,
            totalDescendantsFromHome: totalDescendants,
            totalHoursInvested: totalHours
        )
    }

    // MARK: - Lifespan

    private static func computeAverageLifespan(profiles: [Profile]) -> Double? {
        var spans: [Int] = []
        for profile in profiles {
            guard let birth = profile.birthDate?.bestYear,
                  let death = profile.deathDate?.bestYear else { continue }
            let span = death - birth
            // Skip negative spans defensively — caller's data is malformed but
            // we don't want to drag the average sub-zero.
            guard span >= 0 else { continue }
            spans.append(span)
        }
        guard !spans.isEmpty else { return nil }
        let total = spans.reduce(0, +)
        return Double(total) / Double(spans.count)
    }

    private static func computeMedianDeathYear(profiles: [Profile]) -> Int? {
        let years = profiles.compactMap { $0.deathDate?.bestYear }.sorted()
        guard !years.isEmpty else { return nil }
        let mid = years.count / 2
        if years.count % 2 == 1 {
            return years[mid]
        }
        // Even count → mean of the two middle values, integer-truncated.
        return (years[mid - 1] + years[mid]) / 2
    }

    // MARK: - Surnames & locations

    private static func computeTopSurnames(profiles: [Profile], limit: Int) -> [SurnameCount] {
        // Iterate in stable id order — `snapshot.profiles` is a dictionary and
        // its iteration is unspecified, so without sorting we'd get
        // non-deterministic display casings on tied counts.
        let ordered = profiles.sorted { $0.id < $1.id }
        var buckets: [String: (display: String, count: Int)] = [:]
        for profile in ordered {
            guard let raw = profile.lastName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if var existing = buckets[key] {
                existing.count += 1
                // Pick the display that sorts earliest among encountered casings
                // for deterministic output (e.g. prefer "Smith" over "SMITH").
                if raw.localizedCaseInsensitiveCompare(existing.display) == .orderedSame,
                   raw < existing.display {
                    existing.display = raw
                }
                buckets[key] = existing
            } else {
                buckets[key] = (display: raw, count: 1)
            }
        }
        return buckets.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.display.localizedCaseInsensitiveCompare(rhs.display) == .orderedAscending
            }
            .prefix(limit)
            .map { SurnameCount(surname: $0.display, count: $0.count) }
    }

    private static func computeTopLocations(
        profiles: [Profile],
        keyPath: KeyPath<Profile, String?>,
        limit: Int
    ) -> [LocationCount] {
        let ordered = profiles.sorted { $0.id < $1.id }
        var buckets: [String: (display: String, count: Int)] = [:]
        for profile in ordered {
            guard let raw = profile[keyPath: keyPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if var existing = buckets[key] {
                existing.count += 1
                if raw.localizedCaseInsensitiveCompare(existing.display) == .orderedSame,
                   raw < existing.display {
                    existing.display = raw
                }
                buckets[key] = existing
            } else {
                buckets[key] = (display: raw, count: 1)
            }
        }
        return buckets.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.display.localizedCaseInsensitiveCompare(rhs.display) == .orderedAscending
            }
            .prefix(limit)
            .map { LocationCount(location: $0.display, count: $0.count) }
    }

    // MARK: - Source coverage

    private struct CoverageResult {
        let sourced: Int
        let valued: Int
        var percent: Int {
            guard valued > 0 else { return 0 }
            return Int((Double(sourced) / Double(valued) * 100).rounded())
        }
    }

    private static func computeSourceCoverage(profiles: [Profile]) -> CoverageResult {
        var valued = 0
        var sourced = 0
        for profile in profiles {
            for field in trackedFields {
                guard hasValue(profile: profile, field: field) else { continue }
                valued += 1
                if !(profile.sources[field]?.isEmpty ?? true) {
                    sourced += 1
                }
            }
        }
        return CoverageResult(sourced: sourced, valued: valued)
    }

    private static func hasValue(profile: Profile, field: ProfileField) -> Bool {
        switch field {
        case .firstName: return !(profile.firstName?.isEmpty ?? true)
        case .lastName: return !(profile.lastName?.isEmpty ?? true)
        case .gender: return profile.gender != nil
        case .birthDate: return profile.birthDate != nil
        case .birthLocation: return !(profile.birthLocation?.isEmpty ?? true)
        case .deathDate: return profile.deathDate != nil
        case .deathLocation: return !(profile.deathLocation?.isEmpty ?? true)
        case .bio: return !(profile.bio?.isEmpty ?? true)
        }
    }

    // MARK: - Generations

    /// Returns (maxAncestorGenerations, maxDescendantGenerations,
    /// totalAncestorsFromHome, totalDescendantsFromHome).
    /// All four are zero when `homePersonID` is nil.
    private static func computeGenerations(
        snapshot: FamilyGraphSnapshot,
        homePersonID: String?
    ) -> (Int, Int, Int, Int) {
        guard let homeID = homePersonID, snapshot.profiles[homeID] != nil else {
            return (0, 0, 0, 0)
        }

        // Build adjacency once for BFS — repeated parentsOf/childrenOf scans
        // would be O(R) per node which gets pricey on big trees.
        var parentEdges: [String: [String]] = [:]
        var childEdges: [String: [String]] = [:]
        for rel in snapshot.relationships where rel.type == .parent {
            childEdges[rel.from, default: []].append(rel.to)
            parentEdges[rel.to, default: []].append(rel.from)
        }

        let (ancestorMax, ancestorTotal) = bfsDepth(
            startID: homeID,
            adjacency: parentEdges,
            profiles: snapshot.profiles
        )
        let (descendantMax, descendantTotal) = bfsDepth(
            startID: homeID,
            adjacency: childEdges,
            profiles: snapshot.profiles
        )

        return (ancestorMax, descendantMax, ancestorTotal, descendantTotal)
    }

    /// Standard BFS — returns (max generation reached, total nodes visited
    /// excluding start). A visited set guards against cycles in malformed
    /// graphs and shared-ancestor diamonds (we only count each ancestor once).
    private static func bfsDepth(
        startID: String,
        adjacency: [String: [String]],
        profiles: [String: Profile]
    ) -> (maxDepth: Int, total: Int) {
        var visited: Set<String> = [startID]
        var frontier: [String] = [startID]
        var depth = 0
        var total = 0

        while !frontier.isEmpty {
            var next: [String] = []
            for id in frontier {
                for neighbour in adjacency[id] ?? [] where !visited.contains(neighbour) {
                    guard profiles[neighbour] != nil else { continue }
                    visited.insert(neighbour)
                    next.append(neighbour)
                    total += 1
                }
            }
            if next.isEmpty { break }
            depth += 1
            frontier = next
        }
        return (depth, total)
    }
}
