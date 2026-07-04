import Foundation

/// How strictly a source should match the subject's name when querying.
///
/// Internal to the dispatcher — not exposed in `ResearchConfigSheet`.
/// Derived from `ResearchMode` at dispatch time per the §3 mapping:
///
///   - verify   → strict only, never broaden
///   - extend   → strict first, broaden once on empty
///   - discover → loose first, escalate to variant on empty
///   - all      → run every tier in parallel and dedupe
///
/// §7's per-source table is the authoritative spec for which sources support
/// which tiers. Sources without a meaningful broader mode treat any value as
/// `.strict`; the dispatcher's empty-then-broaden logic (Change 6) skips them
/// rather than issuing redundant identical queries.
///
/// Comparable so the dispatcher can say "treat anything ≥ .loose as broadening".
/// Order is widening: `strict < loose < variant`.
public nonisolated enum SearchStrictness: String, Comparable, Sendable, CaseIterable {
    /// Exact name match, the default for most sources. Server-supplied
    /// "exact-match" flags are used where available (CWGC `Tab=exact`, etc.).
    case strict
    /// Server-side fuzzy / phonetic match if supported. Falls back to `.strict`
    /// for sources without a phonetic mode.
    case loose
    /// Surname looked up in `surname-variants.json` and fanned out as multiple
    /// queries — one per variant. Falls back to `.loose` for CWGC (no useful
    /// distinct variant axis) and to `.strict` for sources with neither.
    case variant

    private var order: Int {
        switch self {
        case .strict:  return 0
        case .loose:   return 1
        case .variant: return 2
        }
    }

    public static func < (lhs: SearchStrictness, rhs: SearchStrictness) -> Bool {
        lhs.order < rhs.order
    }
}
