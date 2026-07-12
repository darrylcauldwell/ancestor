import Foundation

/// Deterministic gate that answers: *may Discovery promote this lead, or
/// is the generator it attaches to too far out on the periphery?*
/// ENGINE_FOUNDATION_SPEC §Change7.
///
/// This is a bound on WHICH leads promote — it sits before the INSERT on
/// the expansion path and never touches the scorer/convergence verdicts.
/// The deterministic sandwich is intact: rules still decide facts; this
/// only decides how far from the probands the engine is allowed to keep
/// digging.
///
/// All distances are measured from the *generator* — the existing profile
/// a new node attaches to (`Lead.profileID`). A newly-promoted node lives
/// one hop beyond its generator, so the check applies the policy to the
/// generator's distance directly: if the generator is already at the
/// limit, expanding one hop further is what we refuse.
public nonisolated struct ExpansionBounds: Sendable {
    let policy: ExpansionPolicy
    let snapshot: FamilyGraphSnapshot

    /// Proband/seed profile IDs to measure distance FROM. Typically the
    /// project's home person (plus any explicit research seeds). Empty =
    /// no anchor → `.noSeedConfigured` (fail-open).
    let seedIDs: [String]

    public init(policy: ExpansionPolicy, snapshot: FamilyGraphSnapshot, seedIDs: [String]) {
        self.policy = policy
        self.snapshot = snapshot
        // Keep only seeds that actually exist in the graph.
        self.seedIDs = seedIDs.filter { snapshot.profiles[$0] != nil }
    }

    /// Evaluate the bound for a lead attaching a new node to `generatorID`.
    ///
    /// Returns the queryable reason. When `generatorID` is empty (a
    /// freestanding lead with no generator) the bound cannot be measured
    /// and promotion is allowed (`.noSeedConfigured`-equivalent fail-open):
    /// a lead with no anchor into the tree isn't an expansion of the tree.
    public func evaluate(generatorID: String) -> ExpansionBoundReason {
        guard !seedIDs.isEmpty else { return .noSeedConfigured }
        guard !generatorID.isEmpty, snapshot.profiles[generatorID] != nil else {
            // No generator to anchor to — not a peripheral expansion; the
            // firewall/dedup guards handle these. Fail open.
            return .noSeedConfigured
        }

        // The promoted node lives ONE hop beyond its generator (it is a
        // new parent/child/spouse of the generator), so its distance is the
        // generator's distance + 1. We bound the promoted node, not the
        // generator — that is what makes "generational:4 halts at gen-4"
        // exact: a generator already at generation 4 would spawn a
        // generation-5 node, which is refused; a generator at generation 3
        // spawns a generation-4 node, which is allowed.
        switch policy {
        case .generationalDistance(let generations):
            guard let genDist = nearestGenerationalDistance(to: generatorID) else {
                return .generatorUnreachable
            }
            let promotedDist = genDist + 1
            return promotedDist <= generations
                ? .withinBounds(policy: policy, measuredDistance: promotedDist)
                : .outsideGenerationalBound(limit: generations, measuredDistance: promotedDist)

        case .collateralDepth(let hops):
            guard let genDepth = nearestCollateralDepth(to: generatorID) else {
                return .generatorUnreachable
            }
            let promotedDepth = genDepth + 1
            return promotedDepth <= hops
                ? .withinBounds(policy: policy, measuredDistance: promotedDepth)
                : .outsideCollateralBound(limit: hops, measuredDistance: promotedDepth)
        }
    }

    // MARK: - Generational distance

    /// Shortest number of parent/child hops from any seed to `target`.
    /// Spouse edges are traversed at zero cost so a spouse married into
    /// the tree shares their partner's generational distance (they sit in
    /// the same generation). `nil` when `target` is in a different
    /// connected component from every seed.
    public func nearestGenerationalDistance(to target: String) -> Int? {
        var best: Int?
        for seed in seedIDs {
            if let d = generationalDistance(from: seed, to: target) {
                best = best.map { min($0, d) } ?? d
            }
        }
        return best
    }

    private func generationalDistance(from seed: String, to target: String) -> Int? {
        // 0-1 BFS: spouse edges cost 0, parent/child edges cost 1.
        // Deterministic ordering: neighbours are sorted by id.
        var distance: [String: Int] = [seed: 0]
        // Simple Dijkstra with tiny integer weights; graph is small.
        var frontier: [(id: String, dist: Int)] = [(seed, 0)]
        while !frontier.isEmpty {
            // Pop the minimum-distance node deterministically.
            frontier.sort { $0.dist != $1.dist ? $0.dist < $1.dist : $0.id < $1.id }
            let current = frontier.removeFirst()
            if current.dist > (distance[current.id] ?? .max) { continue }
            if current.id == target { return current.dist }

            for (neighbourID, weight) in generationalNeighbours(of: current.id) {
                let nd = current.dist + weight
                if nd < (distance[neighbourID] ?? .max) {
                    distance[neighbourID] = nd
                    frontier.append((neighbourID, nd))
                }
            }
        }
        return distance[target]
    }

    /// Parent, child (weight 1) and spouse (weight 0) neighbours.
    private func generationalNeighbours(of id: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for p in snapshot.parentsOf(id) { out.append((p.id, 1)) }
        for c in snapshot.childrenOf(id) { out.append((c.id, 1)) }
        for s in snapshot.spousesOf(id) { out.append((s.id, 0)) }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - Collateral depth

    /// Shortest collateral depth from any proband to `target`. Direct
    /// ancestors and direct descendants of a proband have depth 0. Every
    /// time the walk "turns" — from going up to going down, or crosses a
    /// spouse edge — collateral depth increases by 1. So a sibling
    /// (up to a shared parent, then down) is depth 1; a first cousin
    /// (up, up, down, down) is still depth 1 (one turn); a
    /// sibling-of-sibling / niece-of-cousin style branch accrues more.
    /// `nil` when unreachable from every proband.
    public func nearestCollateralDepth(to target: String) -> Int? {
        var best: Int?
        for proband in seedIDs {
            if let d = collateralDepth(from: proband, to: target) {
                best = best.map { min($0, d) } ?? d
            }
        }
        return best
    }

    /// Direction state carried through the BFS. `.up` = we have only ever
    /// moved to parents so far (still on the direct-ancestor line);
    /// `.down` = we are now descending. A move to a parent while `.down`,
    /// or a spouse move, is a "turn" and costs one collateral hop.
    private enum WalkDirection: Hashable { case start, up, down }

    private struct State: Hashable { let id: String; let dir: WalkDirection }

    private func collateralDepth(from proband: String, to target: String) -> Int? {
        // State = (nodeID, direction). Cost = number of turns taken.
        // 0-1 BFS over the state graph, minimising turns.
        let startState = State(id: proband, dir: .start)
        var cost: [State: Int] = [startState: 0]
        var frontier: [(state: State, cost: Int)] = [(startState, 0)]
        var bestToTarget: Int?

        while !frontier.isEmpty {
            frontier.sort {
                $0.cost != $1.cost ? $0.cost < $1.cost
                    : ($0.state.id != $1.state.id ? $0.state.id < $1.state.id
                        : $0.state.dir.hashValue < $1.state.dir.hashValue)
            }
            let current = frontier.removeFirst()
            if current.cost > (cost[current.state] ?? .max) { continue }
            if current.state.id == target {
                bestToTarget = min(bestToTarget ?? .max, current.cost)
                // Don't break — a later state for the same node might be
                // cheaper only if reached differently, but since we pop in
                // cost order the first pop of `target` is already minimal.
                return current.cost
            }

            for (nextState, turnCost) in collateralNeighbours(of: current.state) {
                let nc = current.cost + turnCost
                if nc < (cost[nextState] ?? .max) {
                    cost[nextState] = nc
                    frontier.append((nextState, nc))
                }
            }
        }
        return bestToTarget
    }

    /// Neighbours in the direction-augmented state graph, each with the
    /// collateral cost of taking that move.
    ///
    /// - To a **parent**: stays on the ancestor line only if we were
    ///   `.start` or `.up`. If we were `.down` this is a turn (cost 1).
    ///   New direction is `.up`.
    /// - To a **child**: free if `.start` or `.down` (still descending the
    ///   direct line, or descending after climbing — but climbing-then-
    ///   descending IS the turn, charged on the first down-move after an
    ///   up-move). New direction is `.down`. The turn from up→down is
    ///   charged here.
    /// - To a **spouse**: always a turn (cost 1); direction unchanged in
    ///   spirit but recorded as `.down` (a spouse's descendants continue
    ///   the collateral branch).
    private func collateralNeighbours(of state: State) -> [(State, Int)] {
        var out: [(State, Int)] = []

        for p in snapshot.parentsOf(state.id).sorted(by: { $0.id < $1.id }) {
            let turn = (state.dir == .down) ? 1 : 0
            out.append((State(id: p.id, dir: .up), turn))
        }
        for c in snapshot.childrenOf(state.id).sorted(by: { $0.id < $1.id }) {
            // Turn happens when we start descending after having ascended.
            let turn = (state.dir == .up) ? 1 : 0
            out.append((State(id: c.id, dir: .down), turn))
        }
        for s in snapshot.spousesOf(state.id).sorted(by: { $0.id < $1.id }) {
            out.append((State(id: s.id, dir: .down), 1))
        }
        return out
    }
}
