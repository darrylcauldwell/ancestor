import Foundation

/// CLEANSE_WIZARD_SPEC §3 — the five finding types the wizard surfaces.
///
/// Closed sum type rather than a protocol: findings are pure data, and the
/// UI and engine both need to switch over every case exhaustively. The
/// associated values carry everything the step view needs to render
/// without re-querying the database.
nonisolated enum CleanseFinding: Identifiable, Sendable {

    /// `birthLocation` matches >1 gazetteer entries — the user must pick.
    /// `candidates` is the full match set (typically 2–6 places).
    case ambiguousLocation(
        profileID: String,
        rawValue: String,
        candidates: [GazetteerEntry]
    )

    /// `birthLocation` is non-empty but matches no gazetteer entries.
    /// `fuzzyMatches` is the best-effort near-miss list shown alongside a
    /// free-form editor. May be empty when the text bears no resemblance to
    /// anything we ship.
    case unmatchedLocation(
        profileID: String,
        rawValue: String,
        fuzzyMatches: [GazetteerEntry]
    )

    /// `birthLocation` matches exactly one gazetteer entry but
    /// `birthLocationCode` is nil. One-tap confirmation closes the gap.
    case unconfirmedLocation(
        profileID: String,
        rawValue: String,
        match: GazetteerEntry
    )

    /// Confirmed birth record carries `mothersMaidenName` but no parents are
    /// linked. `proposals` is the same shape the research pipeline emits
    /// (mother + father), so the wizard can re-use the accept path that
    /// `ClusterReviewView` exposes.
    case missingParentFromBirthRecord(
        profileID: String,
        proposals: [ProposedRelative]
    )

    /// `birthDate` or `deathDate` is bare-year — no quarter / month / day.
    /// `availableQuarter` is populated when a confirmed BMD index row carries
    /// a quarter for the same year (one-tap apply); otherwise nil and the
    /// step view shows a manual Q1–Q4 picker.
    case bareYearDate(
        profileID: String,
        field: CleanseDateField,
        year: Int,
        availableQuarter: String?
    )

    // MARK: - Identity / keys

    /// Stable ID combining case kind + profile + field key. Used by SwiftUI
    /// `ForEach`, and matches the wizard's per-step navigation key.
    var id: String {
        "\(kind):\(profileID):\(fieldKey)"
    }

    var profileID: String {
        switch self {
        case .ambiguousLocation(let id, _, _),
             .unmatchedLocation(let id, _, _),
             .unconfirmedLocation(let id, _, _),
             .missingParentFromBirthRecord(let id, _),
             .bareYearDate(let id, _, _, _):
            return id
        }
    }

    /// Field key used as the second column in `cleanse_unresolvable_flags`.
    /// Stable across releases — the engine reads this when filtering findings.
    var fieldKey: String {
        switch self {
        case .ambiguousLocation, .unmatchedLocation, .unconfirmedLocation:
            return "birthLocation"
        case .missingParentFromBirthRecord:
            return "parents"
        case .bareYearDate(_, let field, _, _):
            return field.rawValue
        }
    }

    /// Short tag for diagnostics / wizard headers.
    var kind: String {
        switch self {
        case .ambiguousLocation:           return "ambiguousLocation"
        case .unmatchedLocation:           return "unmatchedLocation"
        case .unconfirmedLocation:         return "unconfirmedLocation"
        case .missingParentFromBirthRecord: return "missingParent"
        case .bareYearDate:                return "bareYearDate"
        }
    }

    // MARK: - Presentation strings

    var title: String {
        switch self {
        case .ambiguousLocation:           return "Ambiguous birth location"
        case .unmatchedLocation:           return "Unmatched birth location"
        case .unconfirmedLocation:         return "Confirm birth location"
        case .missingParentFromBirthRecord: return "Parents missing from birth record"
        case .bareYearDate(_, let field, _, _):
            return field == .birthDate ? "Bare-year birth date" : "Bare-year death date"
        }
    }

    var summary: String {
        switch self {
        case .ambiguousLocation(_, let raw, let candidates):
            return "\u{201C}\(raw)\u{201D} matches \(candidates.count) places. Pick one or mark unresolvable."
        case .unmatchedLocation(_, let raw, _):
            return "\u{201C}\(raw)\u{201D} doesn\u{2019}t match any place in the bundled gazetteer."
        case .unconfirmedLocation(_, let raw, let match):
            return "\u{201C}\(raw)\u{201D} matches \(match.displayName). Confirm to attach a structured code."
        case .missingParentFromBirthRecord(_, let proposals):
            return "Birth record names parents (\(proposals.count) proposals) but they aren\u{2019}t linked yet."
        case .bareYearDate(_, _, let year, _):
            return "Year \(year) is set, but no quarter or month. Add a quarter when known."
        }
    }
}

/// Which date field a bare-year finding is on. Maps to the underlying
/// `ProfileField` for write-back.
nonisolated enum CleanseDateField: String, Sendable {
    case birthDate
    case deathDate
}

/// CLEANSE_WIZARD_SPEC §3 — the user's choice for a single finding.
/// One enum carries every shape: applying a resolution (with case-specific
/// payload), skipping, or marking unresolvable.
nonisolated enum CleanseAction: Sendable {
    /// User picked one gazetteer entry from an ambiguous / fuzzy / single-match
    /// case. Engine sets birthLocation = displayName and birthLocationCode = id.
    case applyLocationMatch(GazetteerEntry)

    /// User edited the freeform text in an unmatched-location finding.
    /// Engine writes the new text to birthLocation and leaves the code nil.
    /// If the new text resolves to a single match the engine treats it as
    /// `applyLocationMatch` instead — caller doesn\u{2019}t have to know.
    case applyLocationFreeform(String)

    /// User accepted N of the proposed parents from a missing-parent finding.
    /// Empty array == no-op (engine treats as `.skip`).
    case applyProposedRelatives([ProposedRelative])

    /// User picked a quarter for a bare-year date. `quarter` is "Q1"\u{2013}"Q4".
    case applyBareYearQuarter(String)

    /// Leave the field unchanged; the finding may reappear next run.
    case skip

    /// Persist the unresolvable flag for (profileID, fieldKey). Finding will
    /// not reappear until Settings clears the flag.
    case markUnresolvable
}
