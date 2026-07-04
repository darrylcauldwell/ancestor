import Foundation

/// Geographic region for source coverage and filtering.
public nonisolated enum Region: Hashable, Codable, Sendable {
    case englandAndWales
    case scotland
    case ireland
    case commonwealthMilitary
    case county(String)              // "Derbyshire"
    case parish(String, county: String)
}

extension Region {
    /// True if this region geographically overlaps `other` in a way that makes a
    /// source declared with `self` coverage relevant to a subject located at `other`.
    ///
    /// Used by the dispatcher's source filter. Enum equality alone isn't enough —
    /// `.englandAndWales` and `.county("Derbyshire")` are different enum cases
    /// but a source covering E&W is obviously relevant to a Derbyshire subject.
    /// Be permissive: false positives lead to empty queries (cheap); false
    /// negatives silently exclude entire sources (the bug we're fixing).
    public func overlaps(_ other: Region) -> Bool {
        if self == other { return true }
        switch (self, other) {
        // Broad UK regions match any specific place — let scoring downweight
        // results that are actually outside the broad area.
        case (.englandAndWales, .county), (.englandAndWales, .parish),
             (.scotland, .county),         (.scotland, .parish),
             (.ireland, .county),          (.ireland, .parish):
            return true
        case (.county, .englandAndWales), (.parish, .englandAndWales),
             (.county, .scotland),         (.parish, .scotland),
             (.county, .ireland),          (.parish, .ireland):
            return true
        // Military covers anyone potentially.
        case (.commonwealthMilitary, _), (_, .commonwealthMilitary):
            return true
        // Same county: county-county, parish-in-county, both directions.
        case (.county(let a), .county(let b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.county(let c), .parish(_, county: let pc)),
             (.parish(_, county: let pc), .county(let c)):
            return c.caseInsensitiveCompare(pc) == .orderedSame
        case (.parish(let pa, county: let ca), .parish(let pb, county: let cb)):
            return pa.caseInsensitiveCompare(pb) == .orderedSame
                && ca.caseInsensitiveCompare(cb) == .orderedSame
        default:
            return false
        }
    }
}
