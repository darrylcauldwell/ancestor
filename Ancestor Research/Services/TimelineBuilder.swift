import Foundation

/// Pure transformation from a family graph snapshot + workbench data into
/// a list of `TimelineEvent` rows for one profile (DESIGN.md §7.8).
///
/// No I/O, no GRDB. The result is regenerated per build call so the caller
/// (a SwiftUI view) re-derives whenever the underlying snapshot or workbench
/// state changes.
nonisolated enum TimelineBuilder {

    /// Build the chronological timeline for one profile.
    ///
    /// - Parameters:
    ///   - profileID: ID of the profile to focus on. Returns `[]` when not in snapshot.
    ///   - snapshot: Current family graph — supplies birth/death and spouse edges.
    ///   - notes: All workbench notes; only those attached to `profileID` are included.
    ///   - hypotheses: All hypotheses; only `.fieldValue` claims targeting `profileID` are included.
    ///   - questions: All open questions; those referencing `profileID` become rows.
    /// - Returns: Events sorted ascending by date. Undated events go to the bottom.
    static func build(
        profileID: String,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        hypotheses: [Hypothesis],
        questions: [OpenQuestion],
        lifeEvents: [LifeEvent] = []
    ) -> [TimelineEvent] {
        guard let profile = snapshot.profiles[profileID] else { return [] }

        var events: [TimelineEvent] = []

        // Birth
        if profile.birthDate != nil || profile.birthLocation != nil {
            events.append(TimelineEvent(
                id: UUID(),
                date: profile.birthDate,
                kind: .birth,
                title: "Born",
                description: profile.birthLocation ?? "",
                sources: profile.sources[.birthDate] ?? profile.sources[.birthLocation] ?? [],
                isHypothetical: false,
                attachedNoteCount: 0,
                openQuestionCount: 0
            ))
        }

        // Death
        if profile.deathDate != nil || profile.deathLocation != nil {
            events.append(TimelineEvent(
                id: UUID(),
                date: profile.deathDate,
                kind: .death,
                title: "Died",
                description: profile.deathLocation ?? "",
                sources: profile.sources[.deathDate] ?? profile.sources[.deathLocation] ?? [],
                isHypothetical: false,
                attachedNoteCount: 0,
                openQuestionCount: 0
            ))
        }

        // Marriages and divorces — one per spouse relationship involving profile
        for rel in snapshot.relationships
        where rel.type == .spouse && (rel.from == profileID || rel.to == profileID) {
            let otherID = rel.from == profileID ? rel.to : rel.from
            let otherName = snapshot.profiles[otherID]?.displayName ?? "spouse"

            if rel.marriageDate != nil || rel.marriageLocation != nil {
                events.append(TimelineEvent(
                    id: UUID(),
                    date: rel.marriageDate,
                    kind: .marriage,
                    title: "Married \(otherName)",
                    description: rel.marriageLocation ?? "",
                    sources: [],
                    isHypothetical: false,
                    attachedNoteCount: 0,
                    openQuestionCount: 0
                ))
            }

            if let divorce = rel.divorceDate {
                events.append(TimelineEvent(
                    id: UUID(),
                    date: divorce,
                    kind: .divorce,
                    title: "Divorced \(otherName)",
                    description: "",
                    sources: [],
                    isHypothetical: false,
                    attachedNoteCount: 0,
                    openQuestionCount: 0
                ))
            }
        }

        // Life events (M12) — occupation, residence, census, baptism, etc.
        for event in lifeEvents where event.profileID == profileID {
            events.append(TimelineEvent(
                id: UUID(),
                date: event.date ?? event.endDate,
                kind: .lifeEvent,
                title: lifeEventTitle(event),
                description: event.location ?? "",
                sources: event.sources,
                isHypothetical: false,
                attachedNoteCount: 0,
                openQuestionCount: 0
            ))
        }

        // Workbench notes attached to this profile
        for note in notes {
            guard case .profile(let id) = note.attachedTo, id == profileID else { continue }
            events.append(TimelineEvent(
                id: UUID(),
                date: dateForNote(note),
                kind: .note,
                title: noteTitle(for: note),
                description: snippet(of: note.content),
                sources: [],
                isHypothetical: false,
                attachedNoteCount: 1,
                openQuestionCount: 0
            ))
        }

        // Hypotheses with field-value claims targeting this profile
        for hypothesis in hypotheses {
            guard case .fieldValue(let claimProfileID, let field, let value) = hypothesis.claim,
                  claimProfileID == profileID else { continue }
            events.append(TimelineEvent(
                id: UUID(),
                date: hypotheticalDate(field: field, value: value),
                kind: .hypothesis,
                title: "Hypothesis: \(field.rawValue)",
                description: value,
                sources: [],
                isHypothetical: true,
                attachedNoteCount: 0,
                openQuestionCount: 0
            ))
        }

        // Open questions referencing this profile
        for question in questions where question.profileIDs.contains(profileID) {
            events.append(TimelineEvent(
                id: UUID(),
                date: nil,
                kind: .openQuestion,
                title: "Open question",
                description: question.text,
                sources: [],
                isHypothetical: false,
                attachedNoteCount: 0,
                openQuestionCount: 1
            ))
        }

        return events.sorted(by: orderedAscending)
    }

    // MARK: - Sorting

    /// Ascending by best-known year. Undated events sort to the bottom; among
    /// undated rows the order is stable on `kind` then `title` for determinism.
    private static func orderedAscending(_ a: TimelineEvent, _ b: TimelineEvent) -> Bool {
        switch (a.date?.bestYear, b.date?.bestYear) {
        case let (lhs?, rhs?):
            if lhs != rhs { return lhs < rhs }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        if a.kind.rawValue != b.kind.rawValue {
            return a.kind.rawValue < b.kind.rawValue
        }
        return a.title < b.title
    }

    // MARK: - Life event → title

    private static func lifeEventTitle(_ event: LifeEvent) -> String {
        let typeName = event.type.displayName
        if let description = event.description?.trimmingCharacters(in: .whitespaces),
           !description.isEmpty {
            return "\(typeName): \(description)"
        }
        return typeName
    }

    // MARK: - Note → date heuristic

    /// Year regex: 1500-2099. Matches the spec's `\b(1[5-9]\d\d|20\d\d)\b`.
    private static let yearPattern = #"\b(1[5-9]\d\d|20\d\d)\b"#

    /// Determine the date to anchor a workbench note in the timeline.
    /// Prefers the first 4-digit year mentioned in the content; falls back to
    /// the year of `note.createdAt` parsed via the user's calendar.
    private static func dateForNote(_ note: WorkbenchNote) -> GenealogicalDate? {
        if let mentioned = firstYear(in: note.content) {
            return GenealogicalDate(parsing: String(mentioned))
        }
        let year = Calendar.current.component(.year, from: note.createdAt)
        return GenealogicalDate(parsing: String(year))
    }

    private static func firstYear(in text: String) -> Int? {
        guard let range = text.range(of: yearPattern, options: .regularExpression) else {
            return nil
        }
        return Int(text[range])
    }

    private static func noteTitle(for note: WorkbenchNote) -> String {
        "Note: \(note.tag.displayName)"
    }

    /// Trim a note body to a single-line snippet for the row description.
    private static func snippet(of content: String, maxLength: Int = 140) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return collapsed[..<cutoff] + "\u{2026}"
    }

    // MARK: - Hypothesis → date

    /// If the hypothesis's claim is itself a date field, parse the value as a
    /// year so the row anchors on the timeline. Otherwise undated.
    private static func hypotheticalDate(field: ProfileField, value: String) -> GenealogicalDate? {
        switch field {
        case .birthDate, .deathDate:
            let parsed = GenealogicalDate(parsing: value)
            return (parsed.earliest != nil || parsed.latest != nil) ? parsed : nil
        default:
            return nil
        }
    }
}
