import Foundation

/// Bounds Discovery expansion so the engine stops burning budget on
/// peripheral kin (5th cousins, sibling-of-sibling branches) while the
/// core tree still has gaps. ENGINE_FOUNDATION_SPEC §Change7.
///
/// A policy answers one question: *given a lead that would attach a new
/// node to an existing generator profile, is that generator close enough
/// to a proband/seed to be worth expanding from?* The check is a
/// deterministic gate on WHICH leads promote — never a verdict change.
/// The scorer/convergence sandwich is untouched: this bounds the walk,
/// it does not re-decide any record's fact/lead status.
///
/// Two configurable policies (a project picks one):
///  - `.collateralDepth(N)` — at most `N` collateral hops from any
///    proband. A collateral hop is a move that is *not* straight up or
///    straight down the direct line: a jump to a sibling, a cousin, an
///    aunt/uncle's branch. Direct ancestors and direct descendants of a
///    proband are always in bounds. Stops the walk wandering down
///    sibling-of-sibling branches. Default N = 2.
///  - `.generationalDistance(M)` — at most `M` generations from any
///    seed, counting every parent/child hop. Stops the walk extending
///    too deep at the periphery. Default M = 4.
///
/// Overridable per project (persisted on `Project`); the committed
/// `config.yaml` documents the shared defaults so co-region researchers
/// share a starting point.
public nonisolated enum ExpansionPolicy: Codable, Hashable, Sendable {
    /// At most `hops` collateral hops from any proband. Direct
    /// ancestors/descendants of a proband are always in bounds.
    case collateralDepth(hops: Int)

    /// At most `generations` parent/child hops from any seed.
    case generationalDistance(generations: Int)

    // MARK: - Defaults (mirrored in `config.yaml` `expansion:` block)

    public static let defaultCollateralHops = 2
    public static let defaultGenerations = 4

    /// The spec default when a project sets no explicit policy: bound by
    /// generational distance ≤ 4. (Generational distance is the more
    /// intuitive "how far out are we digging" measure; collateral depth
    /// is the opt-in for users who want to keep the walk on the direct
    /// line.)
    public static let `default` = ExpansionPolicy.generationalDistance(
        generations: defaultGenerations
    )

    /// Human-readable label for audit/log lines.
    public var label: String {
        switch self {
        case .collateralDepth(let hops):
            "collateral depth ≤ \(hops)"
        case .generationalDistance(let generations):
            "generational distance ≤ \(generations)"
        }
    }

    // MARK: - Wire value (compact string for SQLite + config.yaml)

    /// Compact, human-inspectable serialization stored in the
    /// `project_meta.expansion_policy` column (and matching the
    /// `config.yaml` `expansion:` shorthand). Examples:
    /// `"generational:4"`, `"collateral:2"`.
    public var wireValue: String {
        switch self {
        case .collateralDepth(let hops): "collateral:\(hops)"
        case .generationalDistance(let generations): "generational:\(generations)"
        }
    }

    /// Parse a wire value. Returns nil for unrecognised/blank strings so
    /// the caller can fall back to `.default`. Tolerant of surrounding
    /// whitespace and case.
    public init?(wireValue raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let n = Int(parts[1]), n >= 0 else { return nil }
        switch parts[0] {
        case "collateral": self = .collateralDepth(hops: n)
        case "generational": self = .generationalDistance(generations: n)
        default: return nil
        }
    }
}

// MARK: - Queryable bound reason

/// Why a lead did — or didn't — clear the expansion bound. The engine
/// records this so "why didn't this lead promote?" has a deterministic
/// answer. Both out-of-bound cases carry the measured distance and the
/// policy limit so the log line is self-explaining.
public nonisolated enum ExpansionBoundReason: Codable, Hashable, Sendable {
    /// The generator is within bounds — promotion may proceed.
    case withinBounds(policy: ExpansionPolicy, measuredDistance: Int)

    /// Outside the collateral-depth bound.
    case outsideCollateralBound(limit: Int, measuredDistance: Int)

    /// Outside the generational-distance bound.
    case outsideGenerationalBound(limit: Int, measuredDistance: Int)

    /// No proband/seed is configured (no home person, empty seed set), so
    /// there is no anchor to measure distance from. The bound is not
    /// applicable and promotion is allowed — bounding only kicks in once
    /// the tree has an anchor. This is fail-open by design: never block
    /// expansion just because the anchor is unset.
    case noSeedConfigured

    /// The generator profile isn't reachable from any seed in the current
    /// graph (disconnected component). Treated as out of bounds — an
    /// unreachable generator is by definition not near the core tree.
    case generatorUnreachable

    /// True when the lead is clear to promote.
    public var permitsPromotion: Bool {
        switch self {
        case .withinBounds, .noSeedConfigured:
            true
        case .outsideCollateralBound, .outsideGenerationalBound, .generatorUnreachable:
            false
        }
    }

    /// Short machine-readable code for the MCP `refuse` payload and audit
    /// rows. Mirrors the spec's queryable strings.
    public var code: String {
        switch self {
        case .withinBounds: "within_bounds"
        case .outsideCollateralBound: "outside_collateral_bound"
        case .outsideGenerationalBound: "outside_generational_bound"
        case .noSeedConfigured: "no_seed_configured"
        case .generatorUnreachable: "generator_unreachable"
        }
    }

    /// Human sentence for logs and the "why didn't this promote?" answer.
    public var detail: String {
        switch self {
        case .withinBounds(let policy, let measured):
            "Within bounds (\(policy.label); measured distance \(measured))."
        case .outsideCollateralBound(let limit, let measured):
            "Outside collateral bound: generator is \(measured) collateral hops from the nearest proband (limit \(limit))."
        case .outsideGenerationalBound(let limit, let measured):
            "Outside generational bound: generator is \(measured) generations from the nearest seed (limit \(limit))."
        case .noSeedConfigured:
            "No proband/seed configured — expansion bound not applied."
        case .generatorUnreachable:
            "Generator profile is not reachable from any seed — outside the core tree."
        }
    }
}
