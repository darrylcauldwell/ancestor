/// Three orthogonal axes describing a person's identity status, life status, and privacy.
/// A profile can be unknownName AND infantDeath AND livingPrivate simultaneously.
/// Stored as a single JSON column on the profiles table.
public nonisolated struct PersonAttributes: Codable, Hashable, Sendable {
    public var nameStatus: NameStatus
    public var lifeStatus: LifeStatus
    public var privacy: Privacy

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(nameStatus: NameStatus, lifeStatus: LifeStatus, privacy: Privacy) {
        self.nameStatus = nameStatus
        self.lifeStatus = lifeStatus
        self.privacy = privacy
    }


    public static let `default` = PersonAttributes(
        nameStatus: .known,
        lifeStatus: .normal,
        privacy: .normal
    )
}

/// Do we know who this person is?
public nonisolated enum NameStatus: String, Codable, Sendable {
    case known          // Default — normal profile
    case unknown        // "The daughter who married a Smith" — display as "?"
    case placeholder    // Temporary — created by sibling shortcut, will be replaced
}

/// Any special life-event category?
public nonisolated enum LifeStatus: String, Codable, Sendable {
    case normal         // Default
    case infantDeath    // Died young, often unnamed — italic/muted display, exempt from completeness
    case stillborn      // Recorded for family completeness, exempt from most audit
}

/// Should this person's data be restricted in exports?
public nonisolated enum Privacy: String, Codable, Sendable {
    case normal         // Default — visible everywhere
    case livingPrivate  // Name withheld in export/sharing — display as "[Living]"
}
