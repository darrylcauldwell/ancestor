import Foundation
import AncestorKit

// Rows → AncestorKit models. The output feeds TreeLayout / the canvas
// renderer unchanged. Viewer-only facts that have no Profile home
// (redaction flags, publish-time badges, citations) travel in
// ViewerAnnotations beside the snapshot.

public nonisolated struct ViewerAnnotations: Sendable, Equatable {
    public let isRedacted: Bool
    public let isProvisional: Bool
    public let badges: ViewerBadges?
    public let citations: [ViewerCitation]

    public init(isRedacted: Bool, isProvisional: Bool,
                badges: ViewerBadges?, citations: [ViewerCitation]) {
        self.isRedacted = isRedacted
        self.isProvisional = isProvisional
        self.badges = badges
        self.citations = citations
    }
}

public nonisolated struct ViewerTree: Sendable {
    public let manifest: ManifestRow
    public let snapshot: FamilyGraphSnapshot
    public let annotations: [String: ViewerAnnotations]
    /// Person record UUID → life events, sorted by year.
    public let events: [String: [LifeEvent]]
    /// Person record UUID → media rows (portraits first).
    public let media: [String: [MediaRow]]
    /// True when the manifest was written by a newer publisher than this
    /// build understands — render the cached tree under an "update the
    /// app" banner (§4.3).
    public var schemaExceedsSupported: Bool {
        manifest.schemaVersion > ViewerSchema.supportedVersion
    }

    /// Where a viewer should land: the manifest's root person when
    /// published, else the best-connected person. Never an isolated
    /// record — an entry point with no relationships strands focus-driven
    /// navigation (found live: a rootless manifest dropped the TV shell
    /// on a name-only person with zero edges).
    public let suggestedRootID: String?
}

public nonisolated enum SnapshotBuilder {

    public static func build(
        manifest: ManifestRow,
        persons: [PersonRow],
        relationships: [RelationshipRow],
        events: [EventRow],
        media: [MediaRow]
    ) -> ViewerTree {
        var profiles: [String: Profile] = [:]
        var annotations: [String: ViewerAnnotations] = [:]

        for row in persons {
            profiles[row.id] = profile(from: row)
            annotations[row.id] = ViewerAnnotations(
                isRedacted: row.isRedacted,
                isProvisional: row.isProvisional,
                badges: decode(ViewerBadges.self, from: row.badgesJSON),
                citations: decode([ViewerCitation].self, from: row.citationsJSON) ?? [])
        }

        // Edges referencing a person that isn't cached (yet) are dropped —
        // a mid-publish partial fetch must degrade to a smaller tree, not
        // dangling edges (§4.3). Unknown relationship types are skipped
        // for forward compatibility.
        let edges: [Relationship] = relationships.compactMap { row in
            guard profiles[row.fromPersonID] != nil, profiles[row.toPersonID] != nil,
                  let type = RelationshipType(rawValue: row.typeRaw)
            else { return nil }
            return Relationship(
                id: UUID(uuidString: row.id) ?? UUID(),
                from: row.fromPersonID,
                to: row.toPersonID,
                type: type,
                role: row.roleRaw.flatMap(ParentRole.init(rawValue:)),
                subtype: RelationshipSubtype(rawValue: row.subtypeRaw) ?? .unknown,
                marriageDate: GenealogicalDate(
                    original: row.marriageOriginal, earliest: row.marriageEarliest,
                    latest: row.marriageLatest, qualifierRaw: row.marriageQualifierRaw,
                    isApproximate: row.marriageIsApproximate),
                marriageLocation: row.marriageLocation,
                divorceDate: GenealogicalDate(
                    original: row.divorceOriginal, earliest: row.divorceEarliest,
                    latest: row.divorceLatest, qualifierRaw: row.divorceQualifierRaw,
                    isApproximate: row.divorceIsApproximate))
        }

        var eventsByPerson: [String: [LifeEvent]] = [:]
        for row in events where profiles[row.personID] != nil {
            eventsByPerson[row.personID, default: []].append(lifeEvent(from: row))
        }
        for key in eventsByPerson.keys {
            eventsByPerson[key]?.sort { ($0.sortYear ?? Int.max) < ($1.sortYear ?? Int.max) }
        }

        var mediaByPerson: [String: [MediaRow]] = [:]
        for row in media where profiles[row.personID] != nil {
            mediaByPerson[row.personID, default: []].append(row)
        }
        for key in mediaByPerson.keys {
            mediaByPerson[key]?.sort { $0.kind == "portrait" && $1.kind != "portrait" }
        }

        let snapshot = FamilyGraphSnapshot(profiles: profiles, relationships: edges)
        return ViewerTree(
            manifest: manifest,
            snapshot: snapshot,
            annotations: annotations,
            events: eventsByPerson,
            media: mediaByPerson,
            suggestedRootID: suggestedRoot(manifest: manifest, snapshot: snapshot))
    }

    /// Manifest root when it exists in the published set; otherwise the
    /// person with the most relationship edges (ties broken by name for
    /// determinism); nil only for an empty tree.
    static func suggestedRoot(manifest: ManifestRow, snapshot: FamilyGraphSnapshot) -> String? {
        if let root = manifest.rootPerson, snapshot.profiles[root] != nil { return root }
        var degree: [String: Int] = [:]
        for edge in snapshot.relationships {
            degree[edge.from, default: 0] += 1
            degree[edge.to, default: 0] += 1
        }
        return snapshot.profiles.values
            .max { lhs, rhs in
                let l = degree[lhs.id] ?? 0
                let r = degree[rhs.id] ?? 0
                if l != r { return l < r }
                return (lhs.displayName, lhs.id) > (rhs.displayName, rhs.id)
            }?
            .id
    }

    // MARK: - Row → model

    static func profile(from row: PersonRow) -> Profile {
        // Profile.displayName is computed from name parts, so published
        // displayName fidelity matters: when the parts don't recompose to
        // the published string (middle names folded oddly, redacted
        // persons with no parts), the whole displayName rides in
        // firstName so the tree renders exactly what was published.
        var firstName = row.givenName
        var lastName = row.familyName
        let recomposed = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        if recomposed != row.displayName {
            firstName = row.displayName.isEmpty ? nil : row.displayName
            lastName = nil
        }

        return Profile(
            id: row.id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: row.genderRaw.flatMap(Gender.init(rawValue:)),
            birthDate: GenealogicalDate(
                original: row.birthOriginal, earliest: row.birthEarliest,
                latest: row.birthLatest, qualifierRaw: row.birthQualifierRaw,
                isApproximate: row.birthIsApproximate),
            birthLocation: row.birthPlace,
            deathDate: GenealogicalDate(
                original: row.deathOriginal, earliest: row.deathEarliest,
                latest: row.deathLatest, qualifierRaw: row.deathQualifierRaw,
                isApproximate: row.deathIsApproximate),
            deathLocation: row.deathPlace,
            bio: row.bioText.isEmpty ? nil : row.bioText,
            isDeleted: false,
            sources: [:],
            disputes: [:])
    }

    static func lifeEvent(from row: EventRow) -> LifeEvent {
        LifeEvent(
            id: UUID(uuidString: row.id) ?? UUID(),
            profileID: row.personID,
            type: LifeEventType(rawValue: row.kindRaw) ?? .other,
            date: GenealogicalDate(
                original: row.dateOriginal, earliest: row.dateEarliest,
                latest: row.dateLatest, qualifierRaw: row.dateQualifierRaw,
                isApproximate: row.dateIsApproximate),
            location: row.location,
            details: row.detailsJSON.flatMap {
                try? JSONDecoder().decode(LifeEventDetails.self, from: Data($0.utf8))
            })
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
