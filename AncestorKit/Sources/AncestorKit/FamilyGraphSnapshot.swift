import Foundation

/// Completeness breakdown — answers "why is this 5/7?"
public nonisolated struct ProfileCompleteness: Sendable {
    public let score: Int
    public let maximum: Int
    public let missing: [CompletenessCheck]
    public let potentiallyLiving: Bool

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(score: Int, maximum: Int, missing: [CompletenessCheck], potentiallyLiving: Bool) {
        self.score = score
        self.maximum = maximum
        self.missing = missing
        self.potentiallyLiving = potentiallyLiving
    }

}

public nonisolated enum CompletenessCheck: Hashable, Sendable {
    case field(ProfileField)
    case hasParents
}

/// Immutable snapshot of the family graph. Natively Sendable.
/// Views receive snapshots; mutations produce new snapshots via ProjectStore.
public nonisolated struct FamilyGraphSnapshot: Sendable {
    public let profiles: [String: Profile]
    public let relationships: [Relationship]

    // Pre-computed caches — built once at snapshot creation
    public let completenessCache: [String: ProfileCompleteness]
    public let siblingCache: [String: [String]]

    public init(profiles: [String: Profile], relationships: [Relationship]) {
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
    public static let empty = FamilyGraphSnapshot(profiles: [:], relationships: [])

    // MARK: - Traversal

    public func parentsOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .parent && $0.to == id }
            .compactMap { profiles[$0.from] }
    }

    public func childrenOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .parent && $0.from == id }
            .compactMap { profiles[$0.to] }
    }

    public func spousesOf(_ id: String) -> [Profile] {
        relationships
            .filter { $0.type == .spouse && ($0.from == id || $0.to == id) }
            .compactMap { rel in
                let otherID = rel.from == id ? rel.to : rel.from
                return profiles[otherID]
            }
    }

    /// Derived from shared parents — no sibling edges stored.
    public func siblingsOf(_ id: String) -> [Profile] {
        (siblingCache[id] ?? []).compactMap { profiles[$0] }
    }

    public func ancestorsOf(_ id: String, depth: Int = 10) -> [Profile] {
        guard depth > 0 else { return [] }
        let parents = parentsOf(id)
        return parents + parents.flatMap { ancestorsOf($0.id, depth: depth - 1) }
    }

    public func descendantsOf(_ id: String, depth: Int = 10) -> [Profile] {
        guard depth > 0 else { return [] }
        let children = childrenOf(id)
        return children + children.flatMap { descendantsOf($0.id, depth: depth - 1) }
    }

    public func completeness(for id: String) -> ProfileCompleteness {
        completenessCache[id] ?? ProfileCompleteness(score: 0, maximum: 7, missing: [], potentiallyLiving: false)
    }

    /// IDs of profiles in the focus set plus their immediate connections
    /// (parents, children, spouses). Used by the Tree's "Focus only" filter
    /// (DESIGN.md §7.7.2). Omits soft-deleted and non-existent IDs.
    public func focusFilteredIDs(focus profileIDs: [String]) -> Set<String> {
        var result: Set<String> = []
        for id in profileIDs where profiles[id] != nil {
            result.insert(id)
            for p in parentsOf(id) { result.insert(p.id) }
            for c in childrenOf(id) { result.insert(c.id) }
            for s in spousesOf(id) { result.insert(s.id) }
        }
        return result
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

            // Living heuristic: born more than 100 years ago with no death = almost certainly dead.
            // Uses relative threshold (adapts each year) rather than fixed cutoff.
            // 100 years balances privacy (don't flag the living) with research (don't miss the dead).
            let potentiallyLiving: Bool
            if profile.deathDate != nil {
                potentiallyLiving = false
            } else if let latestBirth = profile.birthDate?.latest {
                potentiallyLiving = latestBirth + 100 >= currentYear
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

// MARK: - Display labels (moved from AuditPlaceholderView — shared with viewers)

public nonisolated extension CompletenessCheck {
    var label: String {
        switch self {
        case .field(let field): "Missing \(field.rawValue)"
        case .hasParents: "No parents"
        }
    }

    var shortLabel: String {
        switch self {
        case .field(let field):
            switch field {
            case .firstName: "name"
            case .middleName: "middle"
            case .lastName: "surname"
            case .marriedSurname: "married"
            case .nickName: "nickname"
            case .mothersMaidenName: "mother's maiden"
            case .gender: "gender"
            case .birthDate: "birth"
            case .birthLocation: "b.loc"
            case .deathDate: "death"
            case .deathLocation: "d.loc"
            case .bio: "bio"
            }
        case .hasParents: "parents"
        }
    }
}
