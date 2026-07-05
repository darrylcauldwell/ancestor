import Foundation
import CryptoKit

// PUBLISHER_SPEC Change 1 — the pure projection from canonical data to
// published schema v1 (spec §4). No CloudKit imports, no database access:
// inputs and outputs are value types, so every redaction rule is
// unit-testable. The bundle exporter (Change 2) and PublishEngine
// (Change 4) both consume exactly this.

// MARK: - Published value types (schema v1)

/// The full five-field `GenealogicalDate` encoding (spec §4.2): dates
/// built via the component init aren't reparseable from `original` alone,
/// so bounds/qualifier/approximation publish explicitly.
nonisolated struct PublishedDate: Codable, Sendable, Equatable {
    let original: String
    let earliest: Int?
    let latest: Int?
    let qualifierRaw: String
    let isApproximate: Bool

    init(_ date: GenealogicalDate) {
        original = date.original
        earliest = date.earliest
        latest = date.latest
        qualifierRaw = date.qualifier.rawValue
        isApproximate = date.isApproximate
    }
}

nonisolated struct PublishedCitation: Codable, Sendable, Equatable {
    let field: String
    let source: String
    let url: String?
    /// `SourceTrustTier.rawValue` via `SourceTierRegistry.lookup(url:)` —
    /// never `SourceOrigin.tier`, which is overwrite-policy provenance,
    /// not evidence trust (spec §4.2). Omitted when there is no URL.
    let trustTier: Int?
}

nonisolated struct PublishedBadges: Codable, Sendable, Equatable {
    let completenessScore: Int
    let completenessMax: Int
    let convergence: String?
}

nonisolated struct PublishedPerson: Codable, Sendable, Equatable {
    let id: String                    // publisher-minted record UUID (§4.1)
    let schemaVersion: Int
    let displayName: String
    let givenName: String?
    let familyName: String?
    let genderRaw: String?
    let birth: PublishedDate?
    let birthPlace: String?
    let death: PublishedDate?
    let deathPlace: String?
    let bioText: String               // empty until Change 6
    let citationsJSON: String
    let badgesJSON: String
    let isRedacted: Bool
    let isProvisional: Bool
}

nonisolated struct PublishedRelationship: Codable, Sendable, Equatable {
    let id: String
    let schemaVersion: Int
    let fromPerson: String
    let toPerson: String
    let typeRaw: String
    let roleRaw: String?
    let subtypeRaw: String
    let marriage: PublishedDate?      // stripped when either party is nameOnly (§5)
    let marriageLocation: String?
    let divorce: PublishedDate?
}

nonisolated struct PublishedLifeEvent: Codable, Sendable, Equatable {
    let id: String
    let schemaVersion: Int
    let person: String
    let kindRaw: String
    let date: PublishedDate?
    let location: String?
    let detailsJSON: String?          // household rule applied (§5)
    let sourceURL: String?
}

nonisolated struct PublishedMedia: Codable, Sendable, Equatable {
    let id: String
    let schemaVersion: Int
    let person: String
    let kind: String                  // portrait | document
    let caption: String?
    /// Path relative to the project media directory — the bundle exporter
    /// copies this file; the CloudKit engine turns it into a CKAsset.
    let relativePath: String
}

nonisolated struct PublishedManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generation: Int
    let rootPerson: String?
    let personCount: Int
    let relationshipCount: Int
    let publishedAtISO: String
}

nonisolated struct PublishedTree: Sendable {
    let manifest: PublishedManifest
    let persons: [PublishedPerson]
    let relationships: [PublishedRelationship]
    let events: [PublishedLifeEvent]
    let media: [PublishedMedia]
}

// MARK: - Identity (§4.1)

/// Publisher-minted permanent record UUIDs. Rows never die: deleted,
/// omitted, or re-added entities keep their UUID so viewer caches never
/// see duplicates; canonical merges mark the loser `superseded_by`
/// (a `published_ids` column — DB concern, not projection concern).
nonisolated struct PublishedIdentity {
    struct MintedID: Equatable {
        let kind: String
        let canonicalID: String
        let uuid: String
    }

    private var map: [String: String]
    private(set) var minted: [MintedID] = []
    private let mint: () -> String

    init(existing: [String: String] = [:], mint: @escaping () -> String = { UUID().uuidString }) {
        self.map = existing
        self.mint = mint
    }

    static func key(kind: String, canonicalID: String) -> String { "\(kind)|\(canonicalID)" }

    mutating func uuid(kind: String, canonicalID: String) -> String {
        let k = Self.key(kind: kind, canonicalID: canonicalID)
        if let existing = map[k] { return existing }
        let fresh = mint()
        map[k] = fresh
        minted.append(MintedID(kind: kind, canonicalID: canonicalID, uuid: fresh))
        return fresh
    }
}

// MARK: - Checksum

/// Canonical deterministic serialization (spec Change 1) — the diff basis
/// for `published_state` and the Change 2 bundle-determinism basis.
nonisolated enum PublishChecksum {
    static func checksum(_ record: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(record)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Projection

nonisolated extension PublishedTree {
    static let schemaVersion = 1

    struct Inputs {
        let snapshot: FamilyGraphSnapshot
        let lifeEvents: [LifeEvent]
        let attachments: [Attachment]
        let policies: [String: PublishPolicy]        // profileID → stored policy (absent = .auto)
        let mediaOptIns: Set<UUID>                   // attachment ids opted in (publish_media)
        let convergenceByProfile: [String: String]   // profileID → ConvergenceLevel raw (wired Change 2/4)
        let rootProfileID: String?
        let currentYear: Int                         // injected — household year rule is testable
        let generation: Int
        let publishedAtISO: String
    }

    /// Pure projection. Resolves policy per person, applies every §5
    /// redaction rule, and mints/reuses record UUIDs via `identity`.
    static func project(_ inputs: Inputs, identity: inout PublishedIdentity) -> PublishedTree {
        let snapshot = inputs.snapshot

        // Resolve policy for every live profile (soft-deleted profiles are
        // absent by presence semantics — their records tombstone via diff).
        var resolved: [String: ResolvedPublishPolicy] = [:]
        for (id, profile) in snapshot.profiles where !profile.isDeleted {
            resolved[id] = PublishPolicyResolver.resolve(
                override: inputs.policies[id] ?? .auto,
                potentiallyLiving: snapshot.completeness(for: id).potentiallyLiving
            )
        }

        // Persons — sorted by canonical id for deterministic output.
        var persons: [PublishedPerson] = []
        for canonicalID in resolved.keys.sorted() {
            guard let profile = snapshot.profiles[canonicalID],
                  let policy = resolved[canonicalID], policy != .omit else { continue }
            let uuid = identity.uuid(kind: "person", canonicalID: canonicalID)
            // Change 6 — deterministic bio from committed facts, full
            // persons only (nameOnly bios stay empty by §5 zero-leakage).
            let bioText = policy == .full
                ? PublishBioBuilder.bio(
                    for: profile, lifeEvents: inputs.lifeEvents,
                    snapshot: snapshot, resolved: resolved)
                : ""
            persons.append(publishPerson(
                profile: profile, uuid: uuid, policy: policy,
                completeness: snapshot.completeness(for: canonicalID),
                convergence: inputs.convergenceByProfile[canonicalID],
                bioText: bioText
            ))
        }

        // Relationships — edge rules (§5): any edge touching an omitted or
        // absent person is dropped; an edge touching a nameOnly person
        // publishes bare (marriage/divorce/location stripped).
        var relationships: [PublishedRelationship] = []
        let sortedRels = snapshot.relationships.sorted { $0.id.uuidString < $1.id.uuidString }
        for rel in sortedRels {
            guard let fromPolicy = resolved[rel.from], fromPolicy != .omit,
                  let toPolicy = resolved[rel.to], toPolicy != .omit else { continue }
            let stripped = fromPolicy == .nameOnly || toPolicy == .nameOnly
            relationships.append(PublishedRelationship(
                id: identity.uuid(kind: "relationship", canonicalID: rel.id.uuidString),
                schemaVersion: schemaVersion,
                fromPerson: identity.uuid(kind: "person", canonicalID: rel.from),
                toPerson: identity.uuid(kind: "person", canonicalID: rel.to),
                typeRaw: rel.type.rawValue,
                roleRaw: rel.role?.rawValue,
                subtypeRaw: rel.subtype.rawValue,
                marriage: stripped ? nil : rel.marriageDate.map(PublishedDate.init),
                marriageLocation: stripped ? nil : rel.marriageLocation,
                divorce: stripped ? nil : rel.divorceDate.map(PublishedDate.init)
            ))
        }

        // Life events — full persons only, never sensitive (§5).
        var events: [PublishedLifeEvent] = []
        let sortedEvents = inputs.lifeEvents.sorted { $0.id.uuidString < $1.id.uuidString }
        for event in sortedEvents {
            guard resolved[event.profileID] == .full, !event.sensitive else { continue }
            events.append(PublishedLifeEvent(
                id: identity.uuid(kind: "event", canonicalID: event.id.uuidString),
                schemaVersion: schemaVersion,
                person: identity.uuid(kind: "person", canonicalID: event.profileID),
                kindRaw: event.type.rawValue,
                date: event.date.map(PublishedDate.init),
                location: event.location,
                detailsJSON: detailsJSON(for: event, currentYear: inputs.currentYear),
                sourceURL: firstCitationURL(of: event)
            ))
        }

        // Media — profile-targeted, opted-in, full persons, no transcriptions (§4.2).
        var media: [PublishedMedia] = []
        let sortedAttachments = inputs.attachments.sorted { $0.id.uuidString < $1.id.uuidString }
        for attachment in sortedAttachments {
            guard inputs.mediaOptIns.contains(attachment.id),
                  case .profile(let personID) = attachment.attachedTo,
                  resolved[personID] == .full else { continue }
            let kind: String
            switch attachment.mediaType {
            case .photo: kind = "portrait"
            case .document: kind = "document"
            case .transcription: continue   // citation material, not gallery
            }
            media.append(PublishedMedia(
                id: identity.uuid(kind: "media", canonicalID: attachment.id.uuidString),
                schemaVersion: schemaVersion,
                person: identity.uuid(kind: "person", canonicalID: personID),
                kind: kind,
                caption: attachment.caption,
                relativePath: attachment.relativePath
            ))
        }

        let rootUUID: String? = inputs.rootProfileID.flatMap { rootID in
            guard let policy = resolved[rootID], policy != .omit else { return nil }
            return identity.uuid(kind: "person", canonicalID: rootID)
        }

        return PublishedTree(
            manifest: PublishedManifest(
                schemaVersion: schemaVersion,
                generation: inputs.generation,
                rootPerson: rootUUID,
                personCount: persons.count,
                relationshipCount: relationships.count,
                publishedAtISO: inputs.publishedAtISO
            ),
            persons: persons,
            relationships: relationships,
            events: events,
            media: media
        )
    }


    private static func firstCitationURL(of event: LifeEvent) -> String? {
        for source in event.sources {
            if let url = source.citation?.url { return url }
        }
        return nil
    }

    // MARK: Person projection

    private static func publishPerson(
        profile: Profile,
        uuid: String,
        policy: ResolvedPublishPolicy,
        completeness: ProfileCompleteness,
        convergence: String?,
        bioText: String
    ) -> PublishedPerson {
        if policy == .nameOnly {
            // §5: displayName + relationship edges only. Zero leakage:
            // no dates, places, gender, citations, badges, bio, media.
            return PublishedPerson(
                id: uuid, schemaVersion: schemaVersion,
                displayName: profile.displayName,
                givenName: nil, familyName: nil, genderRaw: nil,
                birth: nil, birthPlace: nil, death: nil, deathPlace: nil,
                bioText: "", citationsJSON: "[]", badgesJSON: "{}",
                isRedacted: true, isProvisional: false
            )
        }

        let trimmedGiven = (profile.firstName ?? "").trimmingCharacters(in: .whitespaces)
        let isProvisional = trimmedGiven.isEmpty
            && profile.birthDate == nil && profile.deathDate == nil

        return PublishedPerson(
            id: uuid, schemaVersion: schemaVersion,
            displayName: profile.displayName,
            givenName: profile.firstName,
            familyName: profile.lastName,
            genderRaw: profile.gender?.rawValue,
            birth: profile.birthDate.map(PublishedDate.init),
            birthPlace: profile.birthLocation,
            death: profile.deathDate.map(PublishedDate.init),
            deathPlace: profile.deathLocation,
            bioText: bioText,
            citationsJSON: citationsJSON(for: profile),
            badgesJSON: badgesJSON(completeness: completeness, convergence: convergence),
            isRedacted: false,
            isProvisional: isProvisional
        )
    }

    // MARK: Field derivations (§4.2)

    private static func sortedKeysEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func citationsJSON(for profile: Profile) -> String {
        var entries: [PublishedCitation] = []
        for field in profile.sources.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for source in profile.sources[field] ?? [] {
                let url = source.citation?.url
                let tier: Int?
                if let url {
                    tier = SourceTierRegistry.lookup(url: url).trustTier.rawValue
                } else {
                    tier = nil
                }
                let entry = PublishedCitation(
                    field: field.rawValue,
                    source: source.citation?.collection ?? source.origin.identifier,
                    url: url,
                    trustTier: tier
                )
                if !entries.contains(entry) { entries.append(entry) }
            }
        }
        guard let data = try? sortedKeysEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func badgesJSON(completeness: ProfileCompleteness, convergence: String?) -> String {
        let badges = PublishedBadges(
            completenessScore: completeness.score,
            completenessMax: completeness.maximum,
            convergence: convergence
        )
        guard let data = try? sortedKeysEncoder().encode(badges) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Household-member rule (§5): `HouseholdMember` entries are free text
    /// with no profile linkage, so per-person policy cannot apply. Members
    /// publish only when the event year is known AND ≤ currentYear − 100;
    /// otherwise the household roster is stripped (empty). With current
    /// sources (census ≤ 1911) everything historical publishes while any
    /// hypothetical recent household is structurally excluded.
    static func detailsJSON(for event: LifeEvent, currentYear: Int) -> String? {
        guard var details = event.details else { return nil }
        if case .census(var census) = details {
            let eventYear = event.date?.latest ?? event.date?.earliest
            let publishable: Bool
            if let eventYear {
                publishable = eventYear <= currentYear - 100
            } else {
                publishable = false
            }
            if !publishable {
                census.household = []
                details = .census(census)
            }
        }
        guard let data = try? sortedKeysEncoder().encode(details) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
