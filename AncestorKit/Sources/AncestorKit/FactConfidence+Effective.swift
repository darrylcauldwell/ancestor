import Foundation

/// Derive the "effective" `FactConfidence` to surface for a field given its
/// list of `FieldSource` rows. Per DESIGN.md §5.14, only `.tentative` and
/// `.wellEvidenced` produce visual indicators — `.standard` is the default
/// and is shown unchanged.
///
/// Rules:
///   - If any source is `.wellEvidenced`, return `.wellEvidenced` (one strong
///     source wins — corroboration is good news).
///   - Else if every recorded confidence is `.tentative`, return `.tentative`
///     (no stronger source is acting as a counterweight).
///   - Otherwise return `nil` — render no indicator (standard / mixed /
///     unset all collapse to "no special signal").
///
/// Callers should hide the indicator entirely when this returns `nil` rather
/// than substituting a default — a missing badge is the visual default.
public nonisolated func effectiveConfidence(_ sources: [FieldSource]) -> FactConfidence? {
    guard !sources.isEmpty else { return nil }
    let confidences = sources.compactMap { $0.confidence }
    if confidences.contains(.wellEvidenced) { return .wellEvidenced }
    if !confidences.isEmpty && confidences.allSatisfy({ $0 == .tentative }) {
        return .tentative
    }
    return nil
}
