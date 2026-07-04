import Foundation

/// Auto-generated from transactions and Workbench activity. A session
/// "starts" when the project opens and "ends" implicitly after 30 minutes
/// of inactivity — we don't write an explicit end event, just keep
/// `endedAt` updated to the timestamp of the last activity.
nonisolated struct ResearchSession: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var focusSetID: UUID?

    /// Denormalised activity counters — recorded on each mutation so the
    /// summary is cheap to render without joining transactions.
    var profilesAdded: Int
    var profilesEdited: Int
    var disputesResolved: Int
    var hypothesesCreated: Int
    var hypothesesPromoted: Int
    var questionsCreated: Int
    var questionsResolved: Int
    var notesCreated: Int

    /// All transaction IDs touched in this session — useful later for
    /// "show me what I changed" filtering.
    var transactionIDs: [UUID]

    /// `endedAt - startedAt`, falling back to "now - startedAt" while active.
    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Plain-English summary, computed at display time. Mirrors DESIGN.md §5.11.
    var summary: String {
        let dur = formatDuration(duration)
        var parts: [String] = [dur]
        var actions: [String] = []
        if profilesAdded > 0 { actions.append("added \(profilesAdded) profile\(profilesAdded == 1 ? "" : "s")") }
        if profilesEdited > 0 { actions.append("edited \(profilesEdited)") }
        if disputesResolved > 0 { actions.append("resolved \(disputesResolved) dispute\(disputesResolved == 1 ? "" : "s")") }
        if hypothesesCreated > 0 {
            let promoted = hypothesesPromoted > 0 ? " (\(hypothesesPromoted) promoted)" : ""
            actions.append("created \(hypothesesCreated) hypothes\(hypothesesCreated == 1 ? "is" : "es")\(promoted)")
        }
        if questionsCreated > 0 { actions.append("\(questionsCreated) new question\(questionsCreated == 1 ? "" : "s")") }
        if questionsResolved > 0 { actions.append("resolved \(questionsResolved) question\(questionsResolved == 1 ? "" : "s")") }
        if notesCreated > 0 { actions.append("\(notesCreated) note\(notesCreated == 1 ? "" : "s")") }
        if !actions.isEmpty {
            parts.append(actions.joined(separator: ", "))
        } else {
            parts.append("no recorded activity")
        }
        return parts.joined(separator: ". ").capitalizingFirstLetter() + "."
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")\(minutes > 0 ? " \(minutes) min" : "")"
        }
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "Less than a minute"
    }

    /// Has any activity been recorded? Drives whether SessionResumeView
    /// shows summary text or just a "no recorded activity" placeholder.
    var hasActivity: Bool {
        profilesAdded + profilesEdited + disputesResolved
            + hypothesesCreated + hypothesesPromoted
            + questionsCreated + questionsResolved + notesCreated > 0
    }
}

/// Activity events the session tracker increments. One enum case per
/// counter on the session record, plus `.transactionRecorded` to append
/// a transaction id (counters are decoupled — a single user action may
/// produce both a counter bump and a transaction id).
nonisolated enum SessionEvent: Sendable {
    case profileAdded
    case profileEdited
    case disputeResolved
    case hypothesisCreated
    case hypothesisPromoted
    case questionCreated
    case questionResolved
    case noteCreated
    case transactionRecorded(UUID)
}

private nonisolated extension String {
    func capitalizingFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
