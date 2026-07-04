import Foundation

/// Free-text markdown attached to anything — a profile, a relationship,
/// a hypothesis, a question, or just the project. Notes are where most
/// thinking starts; some of it later gets promoted to questions or hypotheses.
nonisolated struct WorkbenchNote: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var content: String           // Markdown. `[[Profile Name]]` becomes a clickable link in W6.
    var tag: NoteTag
    var attachedTo: NoteAttachment
    var createdAt: Date
    var updatedAt: Date
    var sensitive: Bool = false   // M14 §7.15.2 — exclude from shared exports when set

    /// Convenience init for callers that haven't been updated to pass `sensitive`.
    init(
        id: UUID, content: String, tag: NoteTag, attachedTo: NoteAttachment,
        createdAt: Date, updatedAt: Date, sensitive: Bool = false
    ) {
        self.id = id
        self.content = content
        self.tag = tag
        self.attachedTo = attachedTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sensitive = sensitive
    }
}

nonisolated enum NoteTag: String, Codable, CaseIterable, Sendable {
    case observation        // "Noticed that..."
    case todo               // "Need to check..."
    case insight            // "This means that..."
    case sourceLog          // "Searched FreeBMD for..."
    case meta               // Notes about the research process itself

    var displayName: String {
        switch self {
        case .observation: return "Observation"
        case .todo: return "Todo"
        case .insight: return "Insight"
        case .sourceLog: return "Source log"
        case .meta: return "Meta"
        }
    }
}

/// What a note is attached to. Persisted as JSON plus a flat
/// `(attachment_kind, attachment_id)` pair for indexed lookup.
nonisolated enum NoteAttachment: Codable, Hashable, Sendable {
    case project
    case profile(id: String)
    case relationship(id: UUID)
    case hypothesis(id: UUID)
    case question(id: UUID)

    /// Discriminator used by the indexed `attachment_kind` column.
    var kind: String {
        switch self {
        case .project: return "project"
        case .profile: return "profile"
        case .relationship: return "relationship"
        case .hypothesis: return "hypothesis"
        case .question: return "question"
        }
    }

    /// Flat ID for the indexed `attachment_id` column. nil for `.project`.
    var attachmentID: String? {
        switch self {
        case .project: return nil
        case .profile(let id): return id
        case .relationship(let id): return id.uuidString
        case .hypothesis(let id): return id.uuidString
        case .question(let id): return id.uuidString
        }
    }
}
