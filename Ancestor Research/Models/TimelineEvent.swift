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
nonisolated struct TimelineEvent: Identifiable, Sendable, Hashable {
    let id: UUID                  // Stable per build call only
    let date: GenealogicalDate?   // nil → "undated", sorts to bottom
    let kind: Kind
    let title: String             // "Born", "Census", "Note", "Hypothesis: birth year"
    let description: String       // "Belper, Derbyshire", or note content snippet
    let sources: [FieldSource]    // empty for workbench-derived events
    let isHypothetical: Bool      // true for hypothesis-derived rows
    let attachedNoteCount: Int    // 0 unless this row is a profile event with notes
    let openQuestionCount: Int    // questions referencing the profile

    enum Kind: String, Sendable {
        case birth, death, marriage, divorce
        case note, hypothesis, openQuestion
        case lifeEvent
    }
}
