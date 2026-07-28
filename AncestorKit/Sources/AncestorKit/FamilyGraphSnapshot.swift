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

/// An unordered pair of profile IDs, used to record a user's "these two are
/// NOT duplicates" decision so `DuplicateDetectionRule` stops re-surfacing the
/// pair on every re-audit. Canonicalised on construction (`a <= b`) so the two
/// orderings of the same pair hash and compare equal — the rule flags a pair
/// once (from the alphabetically-first profile) and the dismissal must match
/// regardless of which side asks.
public nonisolated struct DuplicatePairKey: Hashable, Sendable {
    public let a: String
    public let b: String

    public init(_ x: String, _ y: String) {
        if x <= y { a = x; b = y } else { a = y; b = x }
    }
}

/// Immutable snapshot of the family graph. Natively Sendable.
/// Views receive snapshots; mutations produce new snapshots via ProjectStore.
public nonisolated struct FamilyGraphSnapshot: Sendable {
    public let profiles: [String: Profile]
    public let relationships: [Relationship]

    // Pre-computed caches — built once at snapshot creation
    public let completenessCache: [String: ProfileCompleteness]
    public let siblingCache: [String: [String]]
    /// Life events grouped by profile ID. Optional payload (defaults to
    /// empty) so lightweight construction sites keep working; the project
    /// snapshot loader populates it so audit rules (RecordAfterDeathRule)
    /// and the conflict sweep read the SAME data (CL2 AC2).
    public let lifeEvents: [String: [LifeEvent]]

    /// Pairs the user has explicitly marked "not a duplicate". Carried on the
    /// snapshot (defaults empty) so `DuplicateDetectionRule` can suppress them
    /// on every re-audit from the same data every other rule reads. The project
    /// snapshot loader populates it from the `dismissed_duplicates` table;
    /// lightweight construction sites (tests, importers) leave it empty.
    public let dismissedDuplicatePairs: Set<DuplicatePairKey>

    public init(profiles: [String: Profile], relationships: [Relationship],
                lifeEvents: [String: [LifeEvent]] = [:],
                dismissedDuplicatePairs: Set<DuplicatePairKey> = []) {
        self.profiles = profiles
        self.relationships = relationships
        self.lifeEvents = lifeEvents
        self.dismissedDuplicatePairs = dismissedDuplicatePairs
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

    /// Spouses of `id` ordered by marriage date, earliest first — so a
    /// remarriage renders after the first marriage. Undated marriages sort
    /// last, then by id for stability (so ordering never flickers).
    public func spousesOrderedByMarriage(_ id: String) -> [Profile] {
        let dated: [(profile: Profile, year: Int)] = relationships
            .filter { $0.type == .spouse && ($0.from == id || $0.to == id) }
            .compactMap { rel in
                let otherID = rel.from == id ? rel.to : rel.from
                guard let profile = profiles[otherID] else { return nil }
                return (profile, rel.marriageDate?.bestYear ?? Int.max)
            }
        return dated
            .sorted { l, r in l.year != r.year ? l.year < r.year : l.profile.id < r.profile.id }
            .map(\.profile)
    }

    /// The single spouse to DISPLAY for `id` under the marriage-switcher:
    /// nobody with ≤1 spouse changes; a person with 2+ spouses shows the
    /// user-selected marriage (`activeSpouse[id]`) or, by default, their
    /// earliest. Nil when there is no spouse.
    public func displayedSpouse(of id: String, activeSpouse: [String: String]) -> Profile? {
        let ordered = spousesOrderedByMarriage(id)
        guard !ordered.isEmpty else { return nil }
        if ordered.count == 1 { return ordered[0] }
        if let activeID = activeSpouse[id], let sel = ordered.first(where: { $0.id == activeID }) {
            return sel
        }
        return ordered[0]
    }

    /// Children shared by the couple `a`+`b` (both listed as parents), sorted
    /// by birth year. Used to show only the ACTIVE marriage's children.
    public func childrenOfCouple(_ a: String, _ b: String) -> [Profile] {
        let aKids = Set(childrenOf(a).map(\.id))
        let bKids = Set(childrenOf(b).map(\.id))
        return aKids.intersection(bKids)
            .compactMap { profiles[$0] }
            .sorted { l, r in
                let ly = l.birthDate?.bestYear ?? Int.max
                let ry = r.birthDate?.bestYear ?? Int.max
                return ly != ry ? ly < ry : l.displayName < r.displayName
            }
    }

    /// Children to DISPLAY for `id` under the switcher: when `id` has 2+
    /// spouses, only the active marriage's children; otherwise all children.
    public func displayedChildren(of id: String, activeSpouse: [String: String]) -> [Profile] {
        if spousesOrderedByMarriage(id).count >= 2,
           let shown = displayedSpouse(of: id, activeSpouse: activeSpouse) {
            return childrenOfCouple(id, shown.id)
        }
        return childrenOf(id)
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
            case .nameForms: "variants"
            }
        case .hasParents: "parents"
        }
    }
}
