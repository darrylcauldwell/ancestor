import Foundation

/// Pure side-by-side comparison helper for the M19 Comparison view.
///
/// Two profile field values are considered "the same" when their stringified
/// representations match after trimming whitespace and case-folding. A nil
/// value is the same as another nil; nil vs any non-empty value differs;
/// nil vs an empty / whitespace-only string is treated as the same (an
/// empty string contributes no information).
nonisolated enum ProfileDiff {
    /// Returns the set of `ProfileField` cases whose values differ between
    /// the two profiles. Iterates over `ProfileField.allCases` so adding a
    /// new field to the enum picks up automatically.
    static func differingFields(left: Profile, right: Profile) -> Set<ProfileField> {
        var diffs: Set<ProfileField> = []
        for field in ProfileField.allCases {
            if !valuesMatch(
                normalise(value(of: field, in: left)),
                normalise(value(of: field, in: right))
            ) {
                diffs.insert(field)
            }
        }
        return diffs
    }

    /// Stringified representation of a single field's value on a profile.
    /// Returns nil when the field is unset. For dates we use the original
    /// (raw) string rather than `bestYear` so a year-only difference
    /// surfaces even when `bestYear` happens to coincide.
    static func value(of field: ProfileField, in profile: Profile) -> String? {
        switch field {
        case .firstName: return profile.firstName
        case .lastName: return profile.lastName
        case .gender: return profile.gender?.rawValue
        case .birthDate: return profile.birthDate?.original
        case .birthLocation: return profile.birthLocation
        case .deathDate: return profile.deathDate?.original
        case .deathLocation: return profile.deathLocation
        case .bio: return profile.bio
        }
    }

    /// Normalises a value for case-insensitive, whitespace-tolerant
    /// comparison. nil and "" / "   " collapse to nil so an unset field
    /// equals an empty-string field.
    private static func normalise(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.lowercased()
    }

    /// Two normalised values match when they're both nil or are equal
    /// strings. `nil == "x"` always counts as a difference.
    private static func valuesMatch(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }
}
