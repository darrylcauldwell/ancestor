import Foundation

/// Soft-warning helper for unusually long person names (DESIGN.md §7.5.3).
///
/// Names of 100 characters or more are almost always a paste accident
/// (e.g. a pasted bio or address ending up in the name field). The hard
/// 500-character limit is enforced separately by `AutoSuggestService`'s
/// `normaliseName` / `nameHardLimitLength`; this helper only surfaces the
/// soft inline warning between 100 and 499 characters inclusive.
///
/// Pure, no I/O — used directly from views and unit-tested.
nonisolated enum NameLengthWarning {

    /// Threshold at which the soft warning starts (inclusive).
    static let softWarningLength = 100

    /// Hard reject threshold (exclusive — anything 500+ is rejected on save).
    static let hardLimitLength = 500

    /// Inline warning text for a name field, or nil when no warning applies.
    /// Returns the spec text for names with trimmed length in 100..<500 chars.
    /// At 500+ chars callers rely on the hard-limit save-blocker; we return
    /// nil here so the warning field doesn't fight with the disabled Save button.
    static func warningText(forName name: String?) -> String? {
        guard let name else { return nil }
        let count = name.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count >= softWarningLength, count < hardLimitLength else { return nil }
        return "Names this long are unusual — double-check for typos."
    }
}
