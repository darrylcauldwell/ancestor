import Foundation

/// Context-aware suggestions for surnames and locations during manual entry.
/// Pure functions — no I/O, no side effects.
nonisolated enum AutoSuggestService {

    /// The relationship of a person being added relative to a context profile.
    /// Determines whether surname suggestions make sense.
    enum RelationContext: Equatable {
        case child       // Add child of context — likely shares context's surname
        case sibling     // Add sibling — shares parent's surname
        case parent      // Add parent — often shares child's surname (paternal line)
        case spouse      // Add spouse — different family, do not suggest
        case none        // No context — fall back to most-common surnames in tree
    }

    /// Suggest surnames for a new profile, ranked by likelihood.
    /// - Parameter contextID: The existing profile we're relating the new person to (e.g. "add child of John").
    /// - Parameter relation: How the new person relates to contextID.
    /// - Parameter snapshot: Current family graph.
    /// - Returns: Up to 5 suggested surnames, most likely first. Empty array if no useful suggestion.
    static func surnames(
        contextID: String?,
        relation: RelationContext,
        snapshot: FamilyGraphSnapshot
    ) -> [String] {
        switch relation {
        case .spouse:
            // Spouse comes from a different family — don't suggest the partner's surname.
            return []

        case .child, .sibling, .parent:
            guard let contextID, let contextProfile = snapshot.profiles[contextID] else {
                return mostCommonSurnames(snapshot)
            }
            // Sibling shares parents → use sibling's existing surname directly
            if relation == .sibling, let surname = contextProfile.lastName {
                return [surname]
            }
            // Child of context → context's surname (typically paternal)
            // Parent of context → context's surname (paternal grandparent line)
            if let surname = contextProfile.lastName {
                return [surname]
            }
            return mostCommonSurnames(snapshot)

        case .none:
            return mostCommonSurnames(snapshot)
        }
    }

    /// Suggest surnames likely to be maiden names. Per DESIGN.md §7.5.8 the
    /// wizard's maternal-grandmother slot benefits from this — `Profile.lastName`
    /// is "last name at birth", so a married woman's stored surname is her
    /// maiden name. Heuristic: surnames of female profiles, ranked by frequency.
    static func maidenSurnames(snapshot: FamilyGraphSnapshot) -> [String] {
        var counts: [String: Int] = [:]
        for profile in snapshot.profiles.values where profile.gender == .female {
            if let surname = profile.lastName, !surname.isEmpty {
                counts[surname, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
    }

    /// Suggest locations seen elsewhere in the tree, ranked by frequency.
    static func locations(snapshot: FamilyGraphSnapshot) -> [String] {
        var counts: [String: Int] = [:]
        for profile in snapshot.profiles.values {
            if let loc = profile.birthLocation, !loc.isEmpty {
                counts[loc, default: 0] += 1
            }
            if let loc = profile.deathLocation, !loc.isEmpty {
                counts[loc, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map(\.key)
    }

    /// Soft-warning threshold (per DESIGN.md §7.5.3) — names beyond this are
    /// likely a paste accident or pasted bio. Save still proceeds.
    static let nameSoftWarningLength = 100
    /// Hard limit — anything beyond this is rejected on save.
    static let nameHardLimitLength = 500

    /// Normalise a person name on save — trim whitespace, collapse internal spaces.
    /// Does NOT change capitalisation: "de la Cruz" must round-trip unchanged.
    /// Returns nil for empty input or for names exceeding `nameHardLimitLength`
    /// (callers treat that as "reject — refuse to save").
    static func normaliseName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count <= nameHardLimitLength else { return nil }
        return collapsed
    }

    /// Inline warning text for a name field, or nil when no warning applies.
    /// Used by AddPersonView/EditPersonView to surface "this is unusually long".
    static func nameWarning(_ raw: String) -> String? {
        let count = raw.trimmingCharacters(in: .whitespacesAndNewlines).count
        if count > nameHardLimitLength {
            return "Too long — maximum \(nameHardLimitLength) characters."
        }
        if count > nameSoftWarningLength {
            return "Unusually long (\(count) characters). Did you paste extra text?"
        }
        return nil
    }

    /// Validate that a profile has at least one identifying field.
    /// Used by AddPersonView to enable/disable Save.
    static func hasMinimumData(firstName: String?, lastName: String?, birthYear: Int?) -> Bool {
        let hasName = (firstName?.isEmpty == false) || (lastName?.isEmpty == false)
        return hasName || birthYear != nil
    }

    // MARK: - Private

    private static func mostCommonSurnames(_ snapshot: FamilyGraphSnapshot) -> [String] {
        var counts: [String: Int] = [:]
        for profile in snapshot.profiles.values {
            if let surname = profile.lastName, !surname.isEmpty {
                counts[surname, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
    }
}
