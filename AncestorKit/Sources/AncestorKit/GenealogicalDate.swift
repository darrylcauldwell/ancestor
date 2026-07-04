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
public nonisolated struct GenealogicalDate: Codable, Hashable, Sendable {
    public let original: String
    public let earliest: Int?
    public let latest: Int?
    public let isApproximate: Bool
    public let qualifier: DateQualifier

    /// Best single-year estimate for display (midpoint, or whichever bound exists).
    public var bestYear: Int? {
        switch (earliest, latest) {
        case let (e?, l?): return (e + l) / 2
        case let (e?, nil): return e
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    /// Parse from a raw date string (GEDCOM or free text).
    /// Accepts GEDCOM qualifiers (ABT, BEF, AFT, BET...AND, EST, CAL)
    /// and natural language synonyms (circa, around, approximately, before, after).
    /// Also handles decade ranges ("1880s"), month names ("March 1887"),
    /// and "?" for explicitly unknown.
    /// Component init — reconstruction from database columns, CK records,
    /// or any caller that already holds parsed parts. Lives in the main
    /// body (alongside `init(parsing:)`) now that the type is public;
    /// it was historically parked in a ProjectDatabase extension.
    public init(original: String, earliest: Int?, latest: Int?,
                isApproximate: Bool, qualifier: DateQualifier) {
        self.original = original
        self.earliest = earliest
        self.latest = latest
        self.isApproximate = isApproximate
        self.qualifier = qualifier
    }

    public init(parsing raw: String) {
        self.original = raw
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()

        // "?" means explicitly unknown — caller should treat as nil
        // We still parse it to preserve the original string
        if trimmed == "?" {
            self.qualifier = .yearOnly
            self.isApproximate = false
            self.earliest = nil
            self.latest = nil
            return
        }

        // Decade ranges: "1880s" → BET 1880 AND 1889
        if let decadeMatch = Self.parseDecade(trimmed) {
            self.qualifier = .between
            self.isApproximate = true
            self.earliest = decadeMatch.0
            self.latest = decadeMatch.1
            return
        }

        // ABT / ABOUT / CIRCA / AROUND / APPROXIMATELY → about (±5)
        let aboutPrefixes = ["ABT ", "ABOUT ", "CIRCA ", "AROUND ", "APPROXIMATELY ", "APPROX "]
        if let rest = Self.matchPrefix(upper, prefixes: aboutPrefixes) {
            let year = Self.extractYear(from: rest)
            self.qualifier = .about
            self.isApproximate = true
            self.earliest = year.map { $0 - 5 }
            self.latest = year.map { $0 + 5 }
        }
        // EST / ESTIMATED → estimated (±10)
        else if let rest = Self.matchPrefix(upper, prefixes: ["EST ", "ESTIMATED "]) {
            let year = Self.extractYear(from: rest)
            self.qualifier = .estimated
            self.isApproximate = true
            self.earliest = year.map { $0 - 10 }
            self.latest = year.map { $0 + 10 }
        }
        // CAL / CALCULATED → calculated (±1)
        else if let rest = Self.matchPrefix(upper, prefixes: ["CAL ", "CALCULATED "]) {
            let year = Self.extractYear(from: rest)
            self.qualifier = .calculated
            self.isApproximate = true
            self.earliest = year.map { $0 - 1 }
            self.latest = year.map { $0 + 1 }
        }
        // BEF / BEFORE → before (nil, Y)
        else if let rest = Self.matchPrefix(upper, prefixes: ["BEF ", "BEFORE "]) {
            let year = Self.extractYear(from: rest)
            self.qualifier = .before
            self.isApproximate = true
            self.earliest = nil
            self.latest = year
        }
        // AFT / AFTER → after (Y, nil)
        else if let rest = Self.matchPrefix(upper, prefixes: ["AFT ", "AFTER "]) {
            let year = Self.extractYear(from: rest)
            self.qualifier = .after
            self.isApproximate = true
            self.earliest = year
            self.latest = nil
        }
        // BET ... AND ... / BETWEEN ... AND ... → between (A, B)
        else if upper.hasPrefix("BET ") && upper.contains(" AND "),
                let rest = Self.matchPrefix(upper, prefixes: ["BETWEEN ", "BET "]) {
            let parts = rest.components(separatedBy: " AND ")
            let year1 = parts.first.flatMap { Self.extractYear(from: $0) }
            let year2 = parts.last.flatMap { Self.extractYear(from: $0) }
            self.qualifier = .between
            self.isApproximate = true
            self.earliest = year1
            self.latest = year2
        }
        else if upper.hasPrefix("BETWEEN ") && upper.contains(" AND "),
                let rest = Self.matchPrefix(upper, prefixes: ["BETWEEN "]) {
            let parts = rest.components(separatedBy: " AND ")
            let year1 = parts.first.flatMap { Self.extractYear(from: $0) }
            let year2 = parts.last.flatMap { Self.extractYear(from: $0) }
            self.qualifier = .between
            self.isApproximate = true
            self.earliest = year1
            self.latest = year2
        }
        else {
            // Exact date or year-only
            let year = Self.extractYear(from: upper)
            if year != nil && upper.count <= 4 {
                // Pure year: "1887"
                self.qualifier = .yearOnly
            } else {
                // Full date: "1 JAN 1887", "JAN 1887", "March 1887", "3 March 1887"
                self.qualifier = .exact
            }
            self.isApproximate = false
            self.earliest = year
            self.latest = year
        }
    }

    /// Parse preview for live UI feedback — shows what the parser understood.
    public static func parsePreview(_ input: String) -> DateParseResult {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return DateParseResult(displayText: "", isValid: true, parsed: nil)
        }
        if trimmed == "?" {
            return DateParseResult(displayText: "Unknown (explicitly)", isValid: true, parsed: nil)
        }

        let date = GenealogicalDate(parsing: trimmed)

        // Check if we actually parsed a year
        guard date.earliest != nil || date.latest != nil else {
            return DateParseResult(
                displayText: "Could not parse \u{2014} try \"1887\" or \"about 1890\"",
                isValid: false,
                parsed: nil
            )
        }

        let display: String = switch date.qualifier {
        case .exact:
            date.original
        case .yearOnly:
            "\(date.earliest ?? 0)"
        case .about:
            "Approximately \(date.bestYear ?? 0) (range: \(date.earliest ?? 0)\u{2013}\(date.latest ?? 0))"
        case .estimated:
            "Estimated \(date.bestYear ?? 0) (range: \(date.earliest ?? 0)\u{2013}\(date.latest ?? 0))"
        case .calculated:
            "Calculated \(date.bestYear ?? 0) (\u{00B1}1 year)"
        case .before:
            "Before \(date.latest ?? 0)"
        case .after:
            "After \(date.earliest ?? 0)"
        case .between:
            "Between \(date.earliest ?? 0) and \(date.latest ?? 0)"
        }

        return DateParseResult(displayText: display, isValid: true, parsed: date)
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

    /// Match any prefix from a list, returning the remainder (uppercased).
    private static func matchPrefix(_ upper: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if upper.hasPrefix(prefix) {
                return String(upper.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Parse decade shorthand: "1880s" → (1880, 1889).
    private static func parseDecade(_ text: String) -> (Int, Int)? {
        let pattern = #"^(\d{3})0s$"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              range == text.startIndex..<text.endIndex,
              let prefix = Int(text.prefix(3)) else {
            return nil
        }
        let decadeStart = prefix * 10
        guard decadeStart >= 1000 && decadeStart <= 2090 else { return nil }
        return (decadeStart, decadeStart + 9)
    }
}

public nonisolated enum DateQualifier: String, Codable, Sendable {
    case exact
    case about
    case before
    case after
    case between
    case estimated
    case calculated
    case yearOnly
}
