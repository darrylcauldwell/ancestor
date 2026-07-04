import Foundation

/// One row in the Profile Timeline view (DESIGN.md §7.8).
///
/// Events are derived per-build from the family graph snapshot plus the
/// profile's workbench items — never persisted. The `id` is fresh on each
/// build pass and exists only to satisfy `Identifiable` for SwiftUI lists.
///
/// Full structured life events (occupations, residences, censuses) are
/// deferred to M12; for M9 the timeline assembles birth, death, marriage,
/// notes, hypotheses, and open questions.
public nonisolated struct TimelineEvent: Identifiable, Sendable, Hashable {
    public let id: UUID                  // Stable per build call only
    public let date: GenealogicalDate?   // nil → "undated", sorts to bottom
    public let kind: Kind
    public let title: String             // "Born", "Census", "Note", "Hypothesis: birth year"
    public let description: String       // "Belper, Derbyshire", or note content snippet
    public let sources: [FieldSource]    // empty for workbench-derived events
    public let isHypothetical: Bool      // true for hypothesis-derived rows
    public let attachedNoteCount: Int    // 0 unless this row is a profile event with notes
    public let openQuestionCount: Int    // questions referencing the profile

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, date: GenealogicalDate? = nil, kind: Kind, title: String, description: String, sources: [FieldSource], isHypothetical: Bool, attachedNoteCount: Int, openQuestionCount: Int) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.description = description
        self.sources = sources
        self.isHypothetical = isHypothetical
        self.attachedNoteCount = attachedNoteCount
        self.openQuestionCount = openQuestionCount
    }


    public enum Kind: String, Sendable {
        case birth, death, marriage, divorce
        case note, hypothesis, openQuestion
        case lifeEvent
    }
}
