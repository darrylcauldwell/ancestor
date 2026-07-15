import Foundation

/// SOURCE_WEIGHTING_SPEC Change 5 — staged dispatch.
///
/// Replaces the flat all-sources fan-out with an escalation ladder:
/// local free sources first, geographic widening on miss, FamilySearch
/// last and only for record types the free tier left unanswered. The
/// user's Scope choice BOUNDS the ladder — stages that would exceed it
/// are never built — and the free-tier/FS split is derived from each
/// source's declared `ScopeHandling`, not a hardcoded list of names.
///
/// Stage progression is driven by the PIPELINE's iteration loop (the
/// only place verdicts exist for the miss test); the dispatcher's role
/// is to filter its fan-out to one stage's sources at that stage's
/// effective scope.
nonisolated enum DispatchStage: Int, Comparable, CaseIterable, Sendable {
    /// All free sources at the subject's local scope: the chapman trio
    /// bounded to county-or-narrower, plus the scope-invariant free
    /// specialists (CWGC, FindAGrave, Probate) whose reach cannot be
    /// narrowed and whose record-type specialisation keeps their noise
    /// low — delaying them buys nothing.
    case localFree = 0
    /// The chapman trio widened to adjacent counties, only for record
    /// types the previous stage left unanswered.
    case adjacentFree
    /// The chapman trio at national scope.
    case nationalFree
    /// FamilySearch — the breadth extender of last resort (owner
    /// decision: on-miss only). Its place axes are steered by the
    /// user's scope per Change 4 and narrowed by everything earlier
    /// stages established through subject refinement.
    case familySearch

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The stage ladder for a user-chosen scope. Scope BOUNDS the
    /// ladder: geographic stages that would exceed it are never built.
    /// FamilySearch is always the final stage (a national-scope run
    /// still stages free-before-FS; it does not skip FS).
    static func ladder(for scope: ResearchScope) -> [DispatchStage] {
        var stages: [DispatchStage] = [.localFree]
        if scope >= .adjacent { stages.append(.adjacentFree) }
        if scope == .national { stages.append(.nationalFree) }
        stages.append(.familySearch)
        return stages
    }

    /// The scope the dispatcher runs this stage at, bounded by the
    /// user's choice. `.localFree` never exceeds county (parish and
    /// district users get their narrower bound); the widening stages
    /// have fixed geography by definition; FS runs at the user's scope
    /// so Change 4's axis-level steering applies.
    func effectiveScope(userScope: ResearchScope) -> ResearchScope {
        switch self {
        case .localFree: min(userScope, .county)
        case .adjacentFree: .adjacent
        case .nationalFree: .national
        case .familySearch: userScope
        }
    }

    /// Whether a source participates in this stage — derived from its
    /// declared `ScopeHandling`, never a name list. The chapman trio
    /// (`.scoped`, non-FS) walks the geographic stages; the declared
    /// scope-invariant free sources fire once at `.localFree`; FS
    /// (`.scoped` with axis-level steering, sourceID "familysearch")
    /// fires only at its own stage.
    func includes(_ source: any RecordSource) -> Bool {
        let isFamilySearch = source.sourceID == "familysearch"
        switch self {
        case .localFree:
            return !isFamilySearch
        case .adjacentFree, .nationalFree:
            return !isFamilySearch && source.scopeHandling == .scoped
        case .familySearch:
            return isFamilySearch
        }
    }

    /// Human label for activity-feed stage announcements.
    var displayName: String {
        switch self {
        case .localFree: "local free sources"
        case .adjacentFree: "adjacent counties (free sources)"
        case .nationalFree: "national (free sources)"
        case .familySearch: "FamilySearch"
        }
    }
}
