import Foundation
import AncestorKit

/// Whether a source is broadly applicable or hyper-local.
///
/// - `general`: bundled with the core app, useful to any UK researcher.
///   Default-enabled. May expose a local/national scope axis.
/// - `localPlugin`: niche source covering a small geographic area or
///   narrow record type (e.g. Wirksworth Genealogy Project). Default-disabled.
///   Users opt in only when their tree intersects the source's area.
///   Always-local by definition — the scope axis does not apply.
///
/// Distinct from `SourceCategory` in `SourceTierRegistry.swift`, which
/// classifies citation provenance (official archive, volunteer transcription,
/// etc). This type classifies distribution model (bundled-general vs plugin).
nonisolated enum SourceKind: String, Codable, Sendable {
    case general
    case localPlugin
}

/// How a source responds to the user's Scope picker (SOURCE_WEIGHTING_SPEC
/// Change 1). Scope-ignoring must be DECLARED, never inherited: there is no
/// protocol default, so every source (and test double) chooses explicitly at
/// compile time — a new source cannot silently fall into the dispatcher's
/// generic branch the way FamilySearch did (SCOPE_AUDIT_2026-07 finding 5).
nonisolated enum ScopeHandling: Sendable, Equatable {
    /// Geographic fan-out follows the scope parameter — the dispatcher has
    /// a dedicated scope-aware branch for this source (FreeBMD/FreeCen/
    /// FreeREG). Landing in the generic branch while declaring `.scoped`
    /// is refused at query-build time.
    case scoped
    /// Reach is inherently national/global — scope cannot narrow it. The
    /// reason is honesty copy for docs and the searched-surface.
    case inherentlyNational(reason: String)
    /// Queries pin to the subject's anchor geography at EVERY scope level —
    /// neither scoped nor national (FindAGrave's county pin). Declared so
    /// the incoherence is visible until resolved.
    case anchorPinned(reason: String)
    /// Hyper-local corpus — always local by definition; the scope axis
    /// does not apply (SourceKind.localPlugin territory).
    case localCorpus
}

/// A search result paired with its honesty envelope (connector-audit
/// T1-01). The result carries the records; the outcome says whether an
/// empty result can be trusted as evidence of absence and whether a
/// non-empty one is complete.
nonisolated struct SourceSearchEnvelope: Sendable {
    let result: SourceQueryResult
    let outcome: SearchOutcome

    init(result: SourceQueryResult, outcome: SearchOutcome) {
        self.result = result
        self.outcome = outcome
    }

    /// Derive the outcome from the result's default mapping — for
    /// return sites that have nothing richer to say.
    init(_ result: SourceQueryResult) {
        self.init(result: result, outcome: result.outcome)
    }
}

/// The single protocol all sources conform to.
/// Not actor-bound — stateless sources are structs, stateful sources are actors.
/// Both are Sendable.
protocol RecordSource: Sendable {
    nonisolated var sourceID: String { get }
    nonisolated var displayName: String { get }
    nonisolated var recordTypes: Set<RecordType> { get }
    nonisolated var coverageYearRange: ClosedRange<Int>? { get }
    nonisolated var coverageRegions: Set<Region> { get }
    nonisolated var dataLineage: SourceLineage { get }
    nonisolated var trustTier: SourceTrustTier { get }
    nonisolated var evidenceDirectness: EvidenceDirectness { get }
    nonisolated var tosStatus: SourceToSStatus { get }
    nonisolated var kind: SourceKind { get }
    /// Scope-contract declaration (SOURCE_WEIGHTING Change 1). Deliberately
    /// has NO default — every conformance must declare.
    nonisolated var scopeHandling: ScopeHandling { get }
    /// Long-form "what is this source" name for Settings UI. The
    /// short canonical `displayName` is what citations and activity-feed
    /// summaries use; `descriptiveName` is for educating the user about
    /// what an acronym actually covers. Defaults to `displayName`.
    nonisolated var descriptiveName: String { get }

    /// This source's known daily request budget (ENGINE_FOUNDATION
    /// #Change5). Volunteer-run sources enforce a daily ceiling; when it's
    /// spent, the `SourceBudgetTracker` parks the source until the policy's
    /// reset (`.pausedUntilTomorrow`) instead of laddering the transient
    /// circuit breaker. Defaults to `.unlimited` — a source with no known
    /// ceiling is never budget-paused. Declarative and static: the live
    /// count-and-pause state lives in the tracker, not the source, so it
    /// persists across process restarts.
    nonisolated var budgetPolicy: SourceBudgetPolicy { get }

    func search(_ query: RecordQuery) async -> SourceQueryResult

    /// Envelope-aware search (connector-audit T1-01). A protocol
    /// requirement (not just an extension method) so calls through
    /// `any RecordSource` dispatch dynamically to connector overrides.
    /// The default derives the outcome from the plain `search` result;
    /// connectors that can parse hit counts, detect truncation, or
    /// classify block pages override to return a richer envelope.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope
}

extension RecordSource {
    /// Default envelope: whatever `search` said, mapped 1:1. Sources
    /// with no truncation/availability detection get this for free.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        SourceSearchEnvelope(await search(query))
    }

    /// Default kind — most sources are general-purpose. Local plugins override.
    nonisolated var kind: SourceKind { .general }

    /// Default descriptive name = canonical display name. Sources whose
    /// canonical name is an acronym (CWGC, FreeBMD, FreeCen, FreeREG)
    /// override to spell it out for the Settings list.
    nonisolated var descriptiveName: String { displayName }

    /// Default budget: no known daily ceiling. Volunteer-run sources
    /// override with their documented / observed daily limit
    /// (ENGINE_FOUNDATION #Change5).
    nonisolated var budgetPolicy: SourceBudgetPolicy { .unlimited }

    /// Whether the source is currently refusing requests due to its
    /// own rate-limit / circuit-breaker state. Default: false.
    /// FreeBMDSource (and any future source with a breaker) overrides.
    /// Surfaced into the eval envelope so harness parity comparisons
    /// can distinguish "inconclusive because source was throttled"
    /// from "inconclusive because there's no record."
    func isThrottled() async -> Bool { false }
}

/// Sources that can fetch full detail for a specific record.
protocol DetailFetchingSource: RecordSource {
    func fetchDetail(recordID: String) async -> SourceQueryResult
}

/// Sources that accept external credentials.
protocol AuthenticatingSource: RecordSource {
    nonisolated var credentialLabel: String { get }
    func setCredential(_ value: String) async
    func clearCredentials() async
}
