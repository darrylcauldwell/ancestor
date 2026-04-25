import Foundation

/// Completeness breakdown — answers "why is this 5/7?"
nonisolated struct ProfileCompleteness: Sendable {
    let score: Int
    let maximum: Int
    let missing: [CompletenessCheck]
    let potentiallyLiving: Bool
}

nonisolated enum CompletenessCheck: Hashable, Sendable {
    case field(ProfileField)
    case hasParents
}

/// Immutable snapshot of the family graph. Natively Sendable.
/// Views receive snapshots; mutations produce new snapshots via ProjectStore.
nonisolated struct FamilyGraphSnapshot: Sendable {
    let profiles: [String: Profile]
    let relationships: [Relationship]

    // Pre-computed caches — built once at snapshot creation
    let completenessCache: [String: ProfileCompleteness]
    let siblingCache: [String: [String]]

    init(profiles: [String: Profile], relationships: [Relationship]) {
        self.profiles = profiles
        self.relationships = relationships
        self.siblingCache = Self.buildSiblingCache(profiles: profiles, relationships: relationships)
        self.completenessCache = Self.buildCompletenessCache(
            profiles: profiles,
            relationships: relationships,
            siblingCache: self.siblingCache
        )
    }

    /// Empty snapshot for initial state.
    static let empty = FamilyGraphSnapshot(profiles: [:], relationships: [])

    // MARK: - Traversal

    func parentsOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .parent && $0.to == id }
            .compactMap { profiles[$0.from] }
    }

    func childrenOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .parent && $0.from == id }
            .compactMap { profiles[$0.to] }
    }

    func spousesOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .spouse && ($0.from == id || $0.to == id) }
            .compactMap { rel in
                let otherID = rel.from == id ? rel.to : rel.from
                return profiles[otherID]
            }
    }

    /// Derived from shared parents — no sibling edges stored.
    func siblingsOf(_ id: String) -> [Profile] {
        (siblingCache[id] ?? []).compactMap { profiles[$0] }
    }

    func ancestorsOf(_ id: String, depth: Int = 10) -> [Profile] {
        guard depth > 0 else { return [] }
        let parents = parentsOf(id)
        return parents + parents.flatMap { ancestorsOf($0.id, depth: depth - 1) }
    }

    func descendantsOf(_ id: String, depth: Int = 10) -> [Profile] {
        guard depth > 0 else { return [] }
        let children = childrenOf(id)
        return children + children.flatMap { descendantsOf($0.id, depth: depth - 1) }
    }

    func completeness(for id: String) -> ProfileCompleteness {
        completenessCache[id] ?? ProfileCompleteness(score: 0, maximum: 7, missing: [], potentiallyLiving: false)
    }

    // MARK: - Cache Builders

    private static func buildSiblingCache(
        profiles: [String: Profile],
        relationships: [Relationship]
    ) -> [String: [String]] {
        // Build parent → children map
        var parentToChildren: [String: Set<String>] = [:]
        for rel in relationships where rel.type == .parent {
            parentToChildren[rel.from, default: []].insert(rel.to)
        }

        // For each profile, find siblings via shared parents
        var cache: [String: [String]] = [:]
        for id in profiles.keys {
            let parents = relationships
                .filter { $0.type == .parent && $0.to == id }
                .map(\.from)

            var siblings: Set<String> = []
            for parentID in parents {
                if let children = parentToChildren[parentID] {
                    siblings.formUnion(children)
                }
            }
            siblings.remove(id)
            cache[id] = Array(siblings)
        }
        return cache
    }

    private static func buildCompletenessCache(
        profiles: [String: Profile],
        relationships: [Relationship],
        siblingCache: [String: [String]]
    ) -> [String: ProfileCompleteness] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let parentEdgeTargets = Set(relationships.filter { $0.type == .parent }.map(\.to))

        var cache: [String: ProfileCompleteness] = [:]
        for (id, profile) in profiles {
            var missing: [CompletenessCheck] = []

            if profile.firstName == nil { missing.append(.field(.firstName)) }
            if profile.birthDate == nil { missing.append(.field(.birthDate)) }
            if profile.birthLocation == nil { missing.append(.field(.birthLocation)) }
            if profile.deathLocation == nil { missing.append(.field(.deathLocation)) }
            if profile.bio == nil || (profile.bio?.isEmpty ?? true) { missing.append(.field(.bio)) }

            let hasParents = parentEdgeTargets.contains(id)
            if !hasParents { missing.append(.hasParents) }

            // Living heuristic: if latest possible birth + 110 >= current year, might be alive
            let potentiallyLiving: Bool
            if profile.deathDate != nil {
                potentiallyLiving = false
            } else if let latestBirth = profile.birthDate?.latest {
                potentiallyLiving = latestBirth + 110 >= currentYear
            } else {
                // Unbounded birth — can't rule out being alive if no death recorded
                potentiallyLiving = true
            }

            // Death date only counts against completeness for dead people
            if !potentiallyLiving && profile.deathDate == nil {
                missing.append(.field(.deathDate))
            }

            let maximum = potentiallyLiving ? 6 : 7
            let score = maximum - missing.count

            cache[id] = ProfileCompleteness(
                score: max(0, score),
                maximum: maximum,
                missing: missing,
                potentiallyLiving: potentiallyLiving
            )
        }
        return cache
    }
}
