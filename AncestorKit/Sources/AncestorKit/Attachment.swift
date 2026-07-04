import Foundation

/// A file (photo, document, transcription) attached to a profile, life event,
/// or specific field source. Per DESIGN.md §5.15.
///
/// The actual file lives on disk in the project's media directory; this struct
/// holds metadata + a relative path. Bundle the SQLite + media dir into a
/// `.ancestor` archive for the lossless export format.
public nonisolated struct Attachment: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var filename: String
    public var mediaType: AttachmentType
    public var caption: String?
    public var dateTaken: Date?
    public var locationTaken: String?
    public let relativePath: String          // Relative to project's media directory
    public let attachedTo: AttachmentTarget
    public let addedAt: Date

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, filename: String, mediaType: AttachmentType, caption: String? = nil, dateTaken: Date? = nil, locationTaken: String? = nil, relativePath: String, attachedTo: AttachmentTarget, addedAt: Date) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.caption = caption
        self.dateTaken = dateTaken
        self.locationTaken = locationTaken
        self.relativePath = relativePath
        self.attachedTo = attachedTo
        self.addedAt = addedAt
    }

}

public nonisolated enum AttachmentType: String, Codable, CaseIterable, Sendable {
    case photo            // JPEG, HEIC, PNG
    case document         // PDF
    case transcription    // Plain text typed by the user

    public var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .document: return "Document"
        case .transcription: return "Transcription"
        }
    }

    public var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .document: return "doc.richtext"
        case .transcription: return "text.alignleft"
        }
    }
}

/// What this attachment is attached to. Encoded as a tagged JSON union.
public nonisolated enum AttachmentTarget: Codable, Hashable, Sendable {
    case profile(id: String)
    case lifeEvent(id: UUID)
    case fieldSource(entityID: String, field: ProfileField)

    /// Stable string for SQL keying.
    public var kind: String {
        switch self {
        case .profile: return "profile"
        case .lifeEvent: return "lifeEvent"
        case .fieldSource: return "fieldSource"
        }
    }

    /// Primary identifier for SQL lookup. For fieldSource, includes the
    /// field name appended after a `:` so a row can be retrieved without
    /// decoding the JSON column.
    public var primaryID: String {
        switch self {
        case .profile(let id): return id
        case .lifeEvent(let id): return id.uuidString
        case .fieldSource(let entityID, let field): return "\(entityID):\(field.rawValue)"
        }
    }
}
