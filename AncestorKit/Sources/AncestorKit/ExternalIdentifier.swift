import Foundation

/// How much permanence a foreign identifier carries, and whether it still
/// points at a live record. The three cases mirror the inbound counterpart of
/// the publisher's outbound `published_ids.superseded_by` mechanism
/// (MODEL_EVOLUTION_SPEC §Change1): we invented merge-forwarding for the
/// publish boundary and never applied it to identifiers we *receive*.
///
/// - `.primary`   — the current, canonical identifier for its system. Exactly
///                  one per system is the "winner" that the `externalIDs`
///                  projection surfaces. Legacy `[String: String]` rows all
///                  migrate to this case.
/// - `.persistent` — a stable-by-contract identifier that is not the primary
///                  we key lookups on but is guaranteed not to be reassigned
///                  (e.g. an ARK path segment). Kept distinct from `.primary`
///                  so a system can carry both a mutable working ID and a
///                  permanent one without the projection having to choose.
/// - `.deprecated` — this value was merged away; `supersededBy` names the
///                  survivor. FamilySearch returns HTTP 301 for any request on
///                  such an ID, so a cached deprecated PID must forward, never
///                  be trusted as current.
public enum IdentifierKind: String, Codable, Hashable, Sendable, CaseIterable {
    case primary
    case persistent
    case deprecated
}

/// A single typed external identifier with a deprecation lifecycle.
///
/// Replaces the untyped single-slot semantics of `Profile.externalIDs`
/// (`[String: String]`). A profile can now carry, for one system,
/// simultaneously: a primary ID, any number of deprecated IDs that forward to
/// it, and a persistent ID — none of which the old dict could express.
///
/// Storage rules (MODEL_EVOLUTION_SPEC §Change1 acceptance criteria):
/// - `value` is the **bare** identifier. FamilySearch ARKs store as the
///   `ark:/…` *path segment* only — never a full URL — because ARK permanence
///   covers the path segment, not the domain. `ExternalIdentifier.value` must
///   not be a full URL; callers validate with `isLikelyFullURL(_:)`.
/// - The supersession chain is append-only: a `.deprecated` record's
///   `supersededBy` names its successor's `value`; resolving follows the chain
///   to the current primary.
public struct ExternalIdentifier: Codable, Hashable, Sendable {
    /// Namespace of the identifier — "wikitree", "familysearch", "gedcom", …
    /// Free-form (ADR-004 keeps the *model-evolution list* closed, not the
    /// set of external systems); lowercased by convention at construction.
    public var system: String

    /// The bare identifier value. Never a full URL (see type doc). For FS this
    /// is the `ark:/…` path segment; for WikiTree the profile name
    /// ("Smith-123"); for GEDCOM the xref id.
    public var value: String

    /// Lifecycle state — primary / persistent / deprecated.
    public var kind: IdentifierKind

    /// When `kind == .deprecated`, the `value` of the successor this ID was
    /// merged into. `nil` for `.primary` and `.persistent`. A `.deprecated`
    /// record with a `nil` `supersededBy` is a dead end (merged away with an
    /// unknown survivor) — the lookup resolver treats it as unresolvable
    /// rather than crashing.
    public var supersededBy: String?

    /// When this record was first observed/recorded. Used only for audit and
    /// stable ordering; not part of identity.
    public var recordedAt: Date

    public init(
        system: String,
        value: String,
        kind: IdentifierKind = .primary,
        supersededBy: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.system = system
        self.value = value
        self.kind = kind
        self.supersededBy = supersededBy
        self.recordedAt = recordedAt
    }

    /// Heuristic guard against storing a full URL where a bare identifier
    /// belongs. Callers (ingest, manual entry) should reject or strip values
    /// for which this returns true. Deliberately conservative — matches an
    /// explicit scheme prefix or a bare `www.`/`familysearch.org/` host lead,
    /// so an `ark:/…` path segment (which begins `ark:`) is *not* flagged.
    public static func isLikelyFullURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        if lowered.hasPrefix("www.") { return true }
        if lowered.contains("familysearch.org/") { return true }
        return false
    }
}
