import Foundation

/// Formal genealogical citation, structured for entry, storage, and rendering.
/// Based on Mills's Evidence Explained citation model. Per DESIGN.md §5.12.
///
/// Optional on `FieldSource` — not all sources warrant a formal citation
/// (manual memory entries usually don't). When present, the citation is what
/// makes a tree usable to other genealogists: they can verify each fact
/// against its original source.
public nonisolated struct Citation: Codable, Hashable, Sendable {
    public var repository: String?     // "The National Archives", "Derbyshire Record Office"
    public var collection: String?     // "FreeBMD Birth Index", "1851 Census of England"
    public var title: String?          // Document or record title within the collection
    public var page: String?           // "Volume 7b, page 213" — locator within the source
    public var url: String?            // For online sources
    public var dateAccessed: Date?     // When the source was last consulted
    public var notes: String?          // Free text for anything that doesn't fit above

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(repository: String? = nil, collection: String? = nil, title: String? = nil, page: String? = nil, url: String? = nil, dateAccessed: Date? = nil, notes: String? = nil) {
        self.repository = repository
        self.collection = collection
        self.title = title
        self.page = page
        self.url = url
        self.dateAccessed = dateAccessed
        self.notes = notes
    }


    /// Standard genealogical format. Rendered at display time so changing
    /// fields updates the rendering automatically.
    /// "FreeBMD, Birth Index, Belper registration district, March quarter 1834,
    ///  volume 7b, page 213, accessed 25 Apr 2026."
    public var formatted: String {
        var parts: [String] = []
        if let collection, !collection.isEmpty { parts.append(collection) }
        if let title, !title.isEmpty { parts.append(title) }
        if let page, !page.isEmpty { parts.append(page) }
        if let repository, !repository.isEmpty { parts.append(repository) }
        if let url, !url.isEmpty { parts.append(url) }
        if let dateAccessed {
            let f = DateFormatter()
            f.dateStyle = .medium
            parts.append("accessed \(f.string(from: dateAccessed))")
        }
        if let notes, !notes.isEmpty { parts.append(notes) }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
    }

    /// `true` when no field carries any non-empty value. Used by callers
    /// to decide whether to persist anything at all.
    public var isEmpty: Bool {
        let strings = [repository, collection, title, page, url, notes]
        return strings.allSatisfy { ($0 ?? "").isEmpty } && dateAccessed == nil
    }
}

/// Quality of evidence — maps to the GEDCOM `QUAY` tag.
/// Stored alongside the citation, separate from the citation itself: a
/// rough family-bible note can have a citation without high quality, and
/// a top-tier source can be cited without claiming "direct" certainty.
public nonisolated enum EvidenceQuality: Int, Codable, CaseIterable, Sendable {
    case unreliable = 0     // Questionable reliability (estimated, hearsay)
    case secondary = 1      // Secondary evidence (derivative, not original)
    case primary = 2        // Primary evidence (original record, participant)
    case direct = 3         // Direct, proven (multiple independent primaries agree)

    public var displayName: String {
        switch self {
        case .unreliable: return "Unreliable"
        case .secondary: return "Secondary"
        case .primary: return "Primary"
        case .direct: return "Direct (proven)"
        }
    }

    /// Description used in tooltips and audit guidance.
    public var explanation: String {
        switch self {
        case .unreliable: return "Estimated or hearsay — use with caution."
        case .secondary: return "Derivative source — based on an earlier original."
        case .primary: return "Original record — created at the time by a participant."
        case .direct: return "Multiple independent primary sources agree."
        }
    }
}
