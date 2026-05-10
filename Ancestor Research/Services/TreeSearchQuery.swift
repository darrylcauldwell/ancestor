import Foundation

/// Structured search query parsed from a free-text input. Supports name,
/// location, and birth/death year ranges. ANDs across populated fields.
///
/// Grammar (recognised modifiers, all case-insensitive):
///   - `born YYYY`            → exact birth year
///   - `born YYYY-YYYY`       → birth year range
///   - `died YYYY`            → exact death year
///   - `died YYYY-YYYY`       → death year range
///   - `in <words…>`          → location substring (birth OR death)
///   - `born in <words…>`     → location substring (alternate phrasing)
///
/// Tokens before any modifier accumulate into `name` (case-insensitive
/// substring on `Profile.displayName`). Bare tokens trailing a year
/// modifier with no explicit `in` keyword become the location — this
/// handles inputs like "Land born 1830-1850 Derbyshire".
///
/// Malformed input falls through cleanly — bad tokens become part of the
/// name. No throws.
nonisolated struct TreeSearchQuery: Sendable {
    var name: String?
    var location: String?
    var bornAfter: Int?
    var bornBefore: Int?
    var diedAfter: Int?
    var diedBefore: Int?

    /// `true` when no field is populated — caller can short-circuit and
    /// return all profiles instead of running the predicate.
    var isEmpty: Bool {
        name == nil && location == nil &&
        bornAfter == nil && bornBefore == nil &&
        diedAfter == nil && diedBefore == nil
    }

    /// Apply this query as a predicate on a profile. AND across fields.
    func matches(_ profile: Profile) -> Bool {
        if let name {
            if !profile.displayName.lowercased().contains(name.lowercased()) {
                return false
            }
        }
        if let location {
            let needle = location.lowercased()
            let birthHit = profile.birthLocation?.lowercased().contains(needle) ?? false
            let deathHit = profile.deathLocation?.lowercased().contains(needle) ?? false
            if !birthHit && !deathHit { return false }
        }
        if bornAfter != nil || bornBefore != nil {
            guard let year = profile.birthDate?.bestYear else { return false }
            if let lo = bornAfter, year < lo { return false }
            if let hi = bornBefore, year > hi { return false }
        }
        if diedAfter != nil || diedBefore != nil {
            guard let year = profile.deathDate?.bestYear else { return false }
            if let lo = diedAfter, year < lo { return false }
            if let hi = diedBefore, year > hi { return false }
        }
        return true
    }

    /// Parse a free-text query into structured criteria. Empty / pure-
    /// whitespace input returns an empty query (matches everything).
    static func parse(_ raw: String) -> TreeSearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return TreeSearchQuery() }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var query = TreeSearchQuery()
        var nameTokens: [String] = []
        var locationTokens: [String] = []
        var anyYearModifierFired = false

        let modifierKeywords: Set<String> = ["born", "died", "in"]

        var i = 0
        while i < tokens.count {
            let lower = tokens[i].lowercased()

            // `born in <words…>` → location (alternate phrasing)
            if lower == "born", i + 1 < tokens.count, tokens[i + 1].lowercased() == "in" {
                let (words, next) = takeUntilModifier(tokens: tokens, from: i + 2, modifiers: modifierKeywords)
                if !words.isEmpty {
                    locationTokens.append(contentsOf: words)
                    i = next
                    continue
                }
                // "born in" with nothing after — treat as name fragments
                nameTokens.append(tokens[i])
                i += 1
                continue
            }

            // `born YYYY` or `born YYYY-YYYY`
            if lower == "born", i + 1 < tokens.count, let range = parseYearArg(tokens[i + 1]) {
                query.bornAfter = range.lower
                query.bornBefore = range.upper
                anyYearModifierFired = true
                i += 2
                continue
            }

            // `died YYYY` or `died YYYY-YYYY`
            if lower == "died", i + 1 < tokens.count, let range = parseYearArg(tokens[i + 1]) {
                query.diedAfter = range.lower
                query.diedBefore = range.upper
                anyYearModifierFired = true
                i += 2
                continue
            }

            // `in <words…>` → location, until next modifier or end
            if lower == "in" {
                let (words, next) = takeUntilModifier(tokens: tokens, from: i + 1, modifiers: modifierKeywords)
                if !words.isEmpty {
                    locationTokens.append(contentsOf: words)
                    i = next
                    continue
                }
                nameTokens.append(tokens[i])
                i += 1
                continue
            }

            // Bare token. After a year modifier has fired, trailing bare
            // tokens become location ("Land born 1830-1850 Derbyshire").
            // Before any modifier fires, bare tokens are name.
            if anyYearModifierFired {
                let (words, next) = takeUntilModifier(tokens: tokens, from: i, modifiers: modifierKeywords)
                locationTokens.append(contentsOf: words)
                i = next
                continue
            }

            nameTokens.append(tokens[i])
            i += 1
        }

        if !nameTokens.isEmpty {
            query.name = nameTokens.joined(separator: " ")
        }
        if !locationTokens.isEmpty {
            query.location = locationTokens.joined(separator: " ")
        }
        return query
    }

    /// Collect tokens starting at `from` until a modifier keyword or end of
    /// input is reached. Returns the collected words and the next index.
    private static func takeUntilModifier(
        tokens: [String],
        from start: Int,
        modifiers: Set<String>
    ) -> (words: [String], next: Int) {
        var words: [String] = []
        var j = start
        while j < tokens.count, !modifiers.contains(tokens[j].lowercased()) {
            words.append(tokens[j])
            j += 1
        }
        return (words, j)
    }

    /// Parse a year argument: `1834` or `1830-1850`. Returns nil for
    /// non-year input.
    private static func parseYearArg(_ token: String) -> (lower: Int, upper: Int)? {
        if token.contains("-") {
            let parts = token.split(separator: "-").map(String.init)
            guard parts.count == 2,
                  let lo = Int(parts[0]), let hi = Int(parts[1]),
                  isYear(lo), isYear(hi) else { return nil }
            return (min(lo, hi), max(lo, hi))
        }
        guard let y = Int(token), isYear(y) else { return nil }
        return (y, y)
    }

    private static func isYear(_ y: Int) -> Bool {
        y >= 1000 && y <= 2100
    }
}
