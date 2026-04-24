import Foundation

/// Implements the data merge policy from DESIGN.md §5.7.
/// When a new source provides a value for a field that already has a value,
/// determines whether to auto-merge, create a dispute, or corroborate.
nonisolated struct MergeEngine {

    nonisolated enum MergeAction: Sendable {
        case corroborate                    // Identical — add source, no dispute
        case intersect(GenealogicalDate)    // Ranges overlap safely — narrow the range
        case dispute(DisputeReason)         // Sources disagree — needs user resolution
        case replace                        // First value for this field — just set it
    }

    /// Determine merge action for a date field.
    static func mergeDateAction(
        existing: GenealogicalDate?,
        incoming: GenealogicalDate
    ) -> MergeAction {
        guard let existing else { return .replace }

        // Rule 1: Identical normalised ranges → corroborate
        if existing.earliest == incoming.earliest && existing.latest == incoming.latest {
            return .corroborate
        }

        // Rule 2: Complementary unbounded — intersection produces new information
        // e.g. existing "AFT 1870" (1870, nil) + incoming "BEF 1890" (nil, 1890) → (1870, 1890)
        if isComplementary(existing, incoming) {
            let merged = intersectDates(existing, incoming)
            return .intersect(merged)
        }

        // Rule 3: At least one is exact/narrow (±0 or ±1) and ranges overlap
        let existingIsNarrow = isNarrow(existing)
        let incomingIsNarrow = isNarrow(incoming)
        if (existingIsNarrow || incomingIsNarrow) && rangesOverlap(existing, incoming) {
            let merged = intersectDates(existing, incoming)
            return .intersect(merged)
        }

        // Rule 4: Both approximate + partial overlap → dispute (false precision risk)
        if !existingIsNarrow && !incomingIsNarrow && rangesOverlap(existing, incoming) {
            return .dispute(.approximateOverlap)
        }

        // Rule 5: No overlap → dispute
        return .dispute(.noOverlap)
    }

    /// Determine merge action for a non-date string field.
    static func mergeStringAction(
        existing: String?,
        incoming: String
    ) -> MergeAction {
        guard let existing else { return .replace }

        // Normalise for comparison
        let normExisting = normalise(existing)
        let normIncoming = normalise(incoming)

        if normExisting == normIncoming {
            return .corroborate
        }

        return .dispute(.valueMismatch)
    }

    // MARK: - Date Helpers

    /// Check if a date is narrow (±0 or ±1 tolerance).
    private static func isNarrow(_ date: GenealogicalDate) -> Bool {
        switch date.qualifier {
        case .exact, .yearOnly, .calculated:
            return true
        default:
            return false
        }
    }

    /// Check if two dates are complementary — one bounds what the other leaves unbounded.
    private static func isComplementary(_ a: GenealogicalDate, _ b: GenealogicalDate) -> Bool {
        // a has earliest but no latest, b has latest but no earliest (or vice versa)
        let aUnboundedAbove = a.earliest != nil && a.latest == nil
        let bUnboundedBelow = b.earliest == nil && b.latest != nil
        let aUnboundedBelow = a.earliest == nil && a.latest != nil
        let bUnboundedAbove = b.earliest != nil && b.latest == nil

        if aUnboundedAbove && bUnboundedBelow {
            // Check they don't contradict: a.earliest <= b.latest
            return a.earliest! <= b.latest!
        }
        if aUnboundedBelow && bUnboundedAbove {
            return b.earliest! <= a.latest!
        }
        return false
    }

    /// Check if two date ranges overlap.
    private static func rangesOverlap(_ a: GenealogicalDate, _ b: GenealogicalDate) -> Bool {
        let aE = a.earliest ?? Int.min
        let aL = a.latest ?? Int.max
        let bE = b.earliest ?? Int.min
        let bL = b.latest ?? Int.max
        return aE <= bL && bE <= aL
    }

    /// Intersect two date ranges, producing the narrower range.
    private static func intersectDates(_ a: GenealogicalDate, _ b: GenealogicalDate) -> GenealogicalDate {
        let earliest: Int?
        if let ae = a.earliest, let be = b.earliest {
            earliest = max(ae, be)
        } else {
            earliest = a.earliest ?? b.earliest
        }

        let latest: Int?
        if let al = a.latest, let bl = b.latest {
            latest = min(al, bl)
        } else {
            latest = a.latest ?? b.latest
        }

        // Use the more specific qualifier
        let qualifier: DateQualifier = isNarrow(a) ? a.qualifier : (isNarrow(b) ? b.qualifier : .about)
        let isApproximate = qualifier != .exact && qualifier != .yearOnly

        // Build a descriptive original string
        let original: String
        if let e = earliest, let l = latest, e == l {
            original = "\(e)"
        } else if let e = earliest, let l = latest {
            original = "BET \(e) AND \(l)"
        } else if let e = earliest {
            original = "AFT \(e)"
        } else if let l = latest {
            original = "BEF \(l)"
        } else {
            original = a.original // Fallback
        }

        return GenealogicalDate(
            original: original, earliest: earliest, latest: latest,
            isApproximate: isApproximate, qualifier: qualifier
        )
    }

    // MARK: - String Helpers

    /// Normalise a string for comparison: trim, collapse whitespace, lowercase.
    private static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
