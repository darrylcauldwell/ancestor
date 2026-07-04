import Foundation

/// A first-class life event with date range, location, sources, and
/// confidence. Per DESIGN.md §5.13: "the most common kind of fact in
/// genealogy after birth/marriage/death" — occupation, residence, census,
/// baptism, burial, military service, etc.
///
/// Birth and death stay on `Profile` (they're identity-defining and feed
/// audit + completeness). Marriage stays on `Relationship`. Everything
/// else lives here.
nonisolated struct LifeEvent: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let profileID: String
    var type: LifeEventType
    var date: GenealogicalDate?         // Start (or only) date
    var endDate: GenealogicalDate?      // For duration events: residence, occupation, military
    var location: String?
    /// Structured gazetteer ID (e.g. "DBY:Crich") chosen via LocationPicker.
    /// nil for freeform entries.
    var locationCode: String?
    var description: String?            // "Framework knitter", "42 King Street", "Royal Navy"
    /// Typed payload for military / probate / burial / census events
    /// (Task #50). Nil for legacy rows and for event types where freeform
    /// `description` is sufficient. JSON-encoded into `life_events.details_json`.
    var details: LifeEventDetails?
    var sources: [FieldSource]          // FieldSource carries citation + quality + confidence
    var confidence: FactConfidence
    let createdByTransactionID: UUID?   // nil for life events created outside the transaction system
    var sensitive: Bool = false         // M14 §7.15.2 — exclude from shared exports when set

    /// Best-guess single year for sorting on the timeline.
    var sortYear: Int? {
        date?.bestYear ?? endDate?.bestYear
    }

    /// Memberwise initializer with optional fields defaulted so existing
    /// callers don't need updating.
    init(
        id: UUID, profileID: String, type: LifeEventType,
        date: GenealogicalDate? = nil, endDate: GenealogicalDate? = nil,
        location: String? = nil, locationCode: String? = nil,
        description: String? = nil,
        details: LifeEventDetails? = nil,
        sources: [FieldSource] = [], confidence: FactConfidence = .standard,
        createdByTransactionID: UUID? = nil,
        sensitive: Bool = false
    ) {
        self.id = id
        self.profileID = profileID
        self.type = type
        self.date = date
        self.endDate = endDate
        self.location = location
        self.locationCode = locationCode
        self.description = description
        self.details = details
        self.sources = sources
        self.confidence = confidence
        self.createdByTransactionID = createdByTransactionID
        self.sensitive = sensitive
    }
}

/// Categories of life event. Birth/death/marriage are NOT in this enum —
/// they live on Profile and Relationship. Other categories enumerated per
/// DESIGN.md §5.13.
nonisolated enum LifeEventType: String, Codable, CaseIterable, Sendable {
    // Lifecycle (point-in-time)
    case baptism, burial, probate

    // Census (point-in-time, links to a household)
    case census

    // Duration events (date → endDate range)
    case residence
    case occupation
    case education
    case militaryService
    case religion

    // Movement (point-in-time)
    case immigration, emigration

    // Free text
    case other

    var displayName: String {
        switch self {
        case .baptism: return "Baptism"
        case .burial: return "Burial"
        case .probate: return "Probate"
        case .census: return "Census"
        case .residence: return "Residence"
        case .occupation: return "Occupation"
        case .education: return "Education"
        case .militaryService: return "Military Service"
        case .religion: return "Religion"
        case .immigration: return "Immigration"
        case .emigration: return "Emigration"
        case .other: return "Other"
        }
    }

    /// Whether the event has a meaningful end date — used by the editor to
    /// show the endDate field only when relevant.
    var hasDuration: Bool {
        switch self {
        case .residence, .occupation, .education, .militaryService, .religion: return true
        default: return false
        }
    }

    var systemImage: String {
        switch self {
        case .baptism: return "drop"
        case .burial: return "leaf"
        case .probate: return "doc.text.magnifyingglass"
        case .census: return "person.3"
        case .residence: return "house"
        case .occupation: return "briefcase"
        case .education: return "graduationcap"
        case .militaryService: return "shield"
        case .religion: return "book.closed"
        case .immigration: return "arrow.down.right.circle"
        case .emigration: return "arrow.up.right.circle"
        case .other: return "calendar"
        }
    }
}
