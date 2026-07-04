import Foundation

/// A file (photo, document, transcription) attached to a profile, life event,
/// or specific field source. Per DESIGN.md §5.15.
///
/// The actual file lives on disk in the project's media directory; this struct
/// holds metadata + a relative path. Bundle the SQLite + media dir into a
/// `.ancestor` archive for the lossless export format.
nonisolated struct Attachment: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var filename: String
    var mediaType: AttachmentType
    var caption: String?
    var dateTaken: Date?
    var locationTaken: String?
    let relativePath: String          // Relative to project's media directory
    let attachedTo: AttachmentTarget
    let addedAt: Date
}

nonisolated enum AttachmentType: String, Codable, CaseIterable, Sendable {
    case photo            // JPEG, HEIC, PNG
    case document         // PDF
    case transcription    // Plain text typed by the user

    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .document: return "Document"
        case .transcription: return "Transcription"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .document: return "doc.richtext"
        case .transcription: return "text.alignleft"
        }
    }
}

/// What this attachment is attached to. Encoded as a tagged JSON union.
nonisolated enum AttachmentTarget: Codable, Hashable, Sendable {
    case profile(id: String)
    case lifeEvent(id: UUID)
    case fieldSource(entityID: String, field: ProfileField)

    /// Stable string for SQL keying.
    var kind: String {
        switch self {
        case .profile: return "profile"
        case .lifeEvent: return "lifeEvent"
        case .fieldSource: return "fieldSource"
        }
    }

    /// Primary identifier for SQL lookup. For fieldSource, includes the
    /// field name appended after a `:` so a row can be retrieved without
    /// decoding the JSON column.
    var primaryID: String {
        switch self {
        case .profile(let id): return id
        case .lifeEvent(let id): return id.uuidString
        case .fieldSource(let entityID, let field): return "\(entityID):\(field.rawValue)"
        }
    }
}
