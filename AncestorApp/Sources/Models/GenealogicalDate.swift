import Foundation

/// Preserves the original date string while exposing a parsed year range.
/// Audit rules compare ranges, not points — fires only when violation
/// is certain across all plausible values.
///
/// Tolerances:
///   exact     = ±0       ("1 JAN 1887")
///   yearOnly  = ±0       ("1887" — year-bounded at year granularity)
///   about     = ±5       ("ABT 1887" — roughly this decade)
///   estimated = ±10      ("EST 1887" — really uncertain)
///   calculated = ±1      ("CAL 1887" — derived from arithmetic, typically precise)
///   before    = (nil, Y) ("BEF 1890" — unbounded below)
///   after     = (Y, nil) ("AFT 1880" — unbounded above)
///   between   = (A, B)   ("BET 1885 AND 1890" — explicit range)
struct GenealogicalDate: Codable, Hashable, Sendable {
    let original: String
    let earliest: Int?
    let latest: Int?
    let isApproximate: Bool
    let qualifier: DateQualifier

    /// Best single-year estimate for display (midpoint, or whichever bound exists).
    var bestYear: Int? {
        switch (earliest, latest) {
        case let (e?, l?): return (e + l) / 2
        case let (e?, nil): return e
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    /// Parse from a raw date string (GEDCOM or free text).
    init(parsing raw: String) {
        self.original = raw
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()

        if trimmed.hasPrefix("ABT ") || trimmed.hasPrefix("ABOUT ") {
            let yearStr = trimmed.replacingOccurrences(of: "ABT ", with: "")
                .replacingOccurrences(of: "ABOUT ", with: "")
            let year = Self.extractYear(from: yearStr)
            self.qualifier = .about
            self.isApproximate = true
            self.earliest = year.map { $0 - 5 }
            self.latest = year.map { $0 + 5 }
        } else if trimmed.hasPrefix("EST ") {
            let year = Self.extractYear(from: String(trimmed.dropFirst(4)))
            self.qualifier = .estimated
            self.isApproximate = true
            self.earliest = year.map { $0 - 10 }
            self.latest = year.map { $0 + 10 }
        } else if trimmed.hasPrefix("CAL ") {
            let year = Self.extractYear(from: String(trimmed.dropFirst(4)))
            self.qualifier = .calculated
            self.isApproximate = true
            self.earliest = year.map { $0 - 1 }
            self.latest = year.map { $0 + 1 }
        } else if trimmed.hasPrefix("BEF ") || trimmed.hasPrefix("BEFORE ") {
            let yearStr = trimmed.replacingOccurrences(of: "BEF ", with: "")
                .replacingOccurrences(of: "BEFORE ", with: "")
            let year = Self.extractYear(from: yearStr)
            self.qualifier = .before
            self.isApproximate = true
            self.earliest = nil
            self.latest = year
        } else if trimmed.hasPrefix("AFT ") || trimmed.hasPrefix("AFTER ") {
            let yearStr = trimmed.replacingOccurrences(of: "AFT ", with: "")
                .replacingOccurrences(of: "AFTER ", with: "")
            let year = Self.extractYear(from: yearStr)
            self.qualifier = .after
            self.isApproximate = true
            self.earliest = year
            self.latest = nil
        } else if trimmed.hasPrefix("BET ") && trimmed.contains(" AND ") {
            let parts = trimmed.replacingOccurrences(of: "BET ", with: "")
                .components(separatedBy: " AND ")
            let year1 = parts.first.flatMap { Self.extractYear(from: $0) }
            let year2 = parts.last.flatMap { Self.extractYear(from: $0) }
            self.qualifier = .between
            self.isApproximate = true
            self.earliest = year1
            self.latest = year2
        } else {
            // Exact date or year-only
            let year = Self.extractYear(from: trimmed)
            if year != nil && trimmed.count <= 4 {
                // Pure year: "1887"
                self.qualifier = .yearOnly
            } else {
                // Full date: "1 JAN 1887" or "JAN 1887"
                self.qualifier = .exact
            }
            self.isApproximate = false
            self.earliest = year
            self.latest = year
        }
    }

    /// Extract a four-digit year from a string that may contain day/month.
    private static func extractYear(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Try to find a 4-digit year anywhere in the string
        let pattern = #"\b(\d{4})\b"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression),
              let year = Int(trimmed[range]) else {
            return nil
        }
        // Sanity check: genealogical years are roughly 1000-2100
        guard year >= 1000 && year <= 2100 else { return nil }
        return year
    }
}

enum DateQualifier: String, Codable, Sendable {
    case exact
    case about
    case before
    case after
    case between
    case estimated
    case calculated
    case yearOnly
}
