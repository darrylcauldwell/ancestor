import Foundation
import AncestorKit

/// One human answer to "what place does this text name" — the unit of the
/// user-built layer over the bundled gazetteer (Location model Part III).
///
/// A decision is not a guess the app made and not evidence a record supplied. It
/// is a person's judgement, recorded with their reason so a later session can
/// check it rather than re-litigate it.
nonisolated struct PlaceDecision: Sendable, Equatable, Identifiable {
    let id: String
    /// Canonical form used for lookup — see `canonicalKey`.
    let placeText: String
    /// Exactly what the user was looking at when they decided.
    let displayText: String
    /// `nil` = every use of this text. Otherwise one `"profileID|fieldKey"`.
    let scopeField: String?
    let placeAuthorityID: String
    /// The years this decision covers. Defaulted from the chosen district's own
    /// validity window, so binding "Middleton, Derbyshire" to Bakewell RD (from
    /// 1839) cannot govern an 1824 birth — the exact shape of the bug that
    /// started this work.
    let yearFrom: Int?
    let yearTo: Int?
    let reason: String
    let decidedAt: Date
    let supersededAt: Date?

    var isLive: Bool { supersededAt == nil }

    /// Whitespace-collapsed, case-folded. "Middleton,  Derbyshire " and
    /// "middleton, derbyshire" are the same decision; anything more aggressive
    /// (dropping the county, say) would merge decisions the user made separately.
    static func canonicalKey(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether this decision covers an event in `year`. An undated event is
    /// covered; only a year that falls OUTSIDE the window is refused.
    ///
    /// The first cut had this the other way round — no year meant no cover — on
    /// the reasoning that silence about a date is not permission to assume it
    /// fits. That made the feature inert exactly where it is most needed. Almost
    /// every registration district carries a `validFrom` of 1837 or later, so
    /// almost every decision is windowed; and undated events are precisely the
    /// ones the deterministic resolver already declines on. A decision that
    /// cannot cover them settles nothing.
    ///
    /// The window still does its job, because the guard moved to where the
    /// human is: `PlaceInventory.bind` refuses to record a decision whose
    /// district cannot hold the years on the row. Binding Bakewell RD to Ruth
    /// Brailsford's 1824 birth is rejected at the moment someone tries it,
    /// which is both earlier and more explicable than silently not applying.
    func applies(year: Int?) -> Bool {
        guard let year else { return true }
        if let from = yearFrom, year < from { return false }
        if let to = yearTo, year > to { return false }
        return true
    }

    /// The years this decision cannot cover, out of the ones offered.
    static func yearsOutsideWindow(_ years: [Int], from: Int?, to: Int?) -> [Int] {
        years.filter { year in
            (from.map { year < $0 } ?? false) || (to.map { year > $0 } ?? false)
        }.sorted()
    }

    func covers(occurrenceID: String) -> Bool {
        scopeField == nil || scopeField == occurrenceID
    }
}

/// The live decisions for a project, indexed for lookup.
///
/// **Passed, never global.** The app's one prior user-alias-layer-feeding-a-scorer
/// — `ScoringRules.learnedEquivalences` — is a process-wide mutable static behind
/// a lock, and it is completely dead: nothing in production writes it, nothing
/// hydrates it from its table, and its scoring branch has therefore never fired.
/// A shared mutable store here would also break multi-window (decisions are
/// per-project) and reintroduce the parallel-suite fragility already recorded
/// against `UKChapmanCodes.shared`. So this is a value a caller holds and hands
/// in, and the code that does not receive one is structurally unable to consult
/// a human decision.
nonisolated struct PlaceDecisionSet: Sendable, Equatable {
    private let byText: [String: [PlaceDecision]]

    static let empty = PlaceDecisionSet(decisions: [])

    init(decisions: [PlaceDecision]) {
        byText = Dictionary(grouping: decisions.filter(\.isLive), by: \.placeText)
    }

    var isEmpty: Bool { byText.isEmpty }
    var all: [PlaceDecision] { byText.values.flatMap { $0 }.sorted { $0.id < $1.id } }

    /// The decision governing `text` for a given occurrence and year, if any.
    /// A field-scoped decision wins over a text-wide one — the narrower judgement
    /// is the more considered.
    func decision(for text: String, occurrenceID: String? = nil, year: Int? = nil) -> PlaceDecision? {
        let candidates = (byText[PlaceDecision.canonicalKey(text)] ?? [])
            .filter { $0.applies(year: year) }
            .filter { decision in
                guard let scope = decision.scopeField else { return true }
                return scope == occurrenceID
            }
        return candidates.first { $0.scopeField != nil } ?? candidates.first
    }
}
