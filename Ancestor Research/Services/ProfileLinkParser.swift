import Foundation

/// Parses `[[Profile Name]]` intra-tree link markers in note content.
///
/// Per DESIGN.md §7.7.5: a `[[Thomas Land]]` marker becomes a clickable
/// reference to that profile. Ambiguous matches (multiple profiles sharing
/// the same display name) emit the link with a `nil` profileID so the
/// caller can present a disambiguation picker.
///
/// Pure logic, nonisolated — used by views and tested directly.
nonisolated enum ProfileLinkParser {
    /// One element of a parsed note: either plain text or a profile link.
    enum Token: Sendable, Hashable {
        case text(String)
        case link(displayName: String, profileID: String?)
    }

    /// Parse `[[Name]]` markers into a token stream.
    ///
    /// When the displayed name matches exactly one `Profile.displayName` in
    /// the snapshot (case-insensitive, trimmed), the resolved `profileID` is
    /// included; otherwise the link still emits but with `profileID: nil`
    /// (zero matches → no candidates; multiple → disambiguation needed).
    ///
    /// Fail-soft on malformed input: a single `[`, an unmatched `[[`, or
    /// an empty `[[]]` marker is treated as plain text.
    static func parse(_ text: String, snapshot: FamilyGraphSnapshot) -> [Token] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#) else {
            return [.text(text)]
        }

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(text)] }

        var tokens: [Token] = []
        var cursor = 0
        for match in matches {
            let full = match.range
            // Leading text before this match
            if full.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
                if !before.isEmpty {
                    tokens.append(.text(before))
                }
            }

            // Inside name (capture group 1)
            let nameRange = match.range(at: 1)
            let rawName = ns.substring(with: nameRange)
            let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

            if displayName.isEmpty {
                // Empty marker [[ ]] → emit as plain text rather than a broken link.
                tokens.append(.text(ns.substring(with: full)))
            } else {
                let matched = candidates(for: displayName, snapshot: snapshot)
                let resolvedID: String? = matched.count == 1 ? matched[0].id : nil
                tokens.append(.link(displayName: displayName, profileID: resolvedID))
            }

            cursor = full.location + full.length
        }

        // Trailing text after the last match
        if cursor < ns.length {
            let after = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !after.isEmpty {
                tokens.append(.text(after))
            }
        }

        return tokens
    }

    /// All profiles whose `displayName` matches `name` (case-insensitive,
    /// trimmed). Used by the caller to populate the disambiguation picker.
    /// Soft-deleted profiles are excluded.
    static func candidates(for name: String, snapshot: FamilyGraphSnapshot) -> [Profile] {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return snapshot.profiles.values
            .filter { !$0.isDeleted && $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
            .sorted { $0.id < $1.id }
    }
}
