import Foundation

/// Audit-time field accessors that respect disputes (M16.3). When a field is
/// disputed, audit rules use the union range across all competing sources —
/// `min(earliest)` to `max(latest)`. This is the conservative-bound promise
/// from DESIGN.md §5.7: false positives are worse than missed positives.
nonisolated extension Profile {

    /// Effective date for an audit rule. Returns the stored field value when
    /// no dispute exists; returns the union range across competing sources
    /// when there is one.
    ///
    /// Only date-typed fields are meaningful here. For non-date fields the
    /// stored value is returned unchanged (a future iteration could surface
    /// a `effectiveValue` for string fields too).
    public func effectiveDate(_ field: ProfileField) -> GenealogicalDate? {
        let stored: GenealogicalDate?
        switch field {
        case .birthDate: stored = birthDate
        case .deathDate: stored = deathDate
        default:         return nil  // Non-date fields use stored value via direct access
        }

        guard let dispute = disputes[field],
              !dispute.competingSources.isEmpty else {
            return stored
        }

        // Parse each competing source's raw string and union the ranges.
        var earliest: Int? = stored?.earliest
        var latest: Int? = stored?.latest
        var anyOriginal = stored?.original

        for src in dispute.competingSources {
            let parsed = GenealogicalDate(parsing: src.raw)
            if let e = parsed.earliest {
                earliest = earliest.map { min($0, e) } ?? e
            }
            if let l = parsed.latest {
                latest = latest.map { max($0, l) } ?? l
            }
            anyOriginal = anyOriginal ?? parsed.original
        }

        guard earliest != nil || latest != nil else { return stored }
        return GenealogicalDate(
            original: anyOriginal ?? stored?.original ?? "",
            earliest: earliest,
            latest: latest,
            isApproximate: true,             // union range is by definition approximate
            qualifier: .between
        )
    }
}
