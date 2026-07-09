import Foundation
import AncestorKit

// Decoded rows of the five published record types — the platform-neutral
// intermediate between a record source (CloudKit zone or family bundle)
// and the cache. Column names mirror published-schema-v1.ckdb exactly;
// the `checksum` field is publisher-internal and deliberately not carried.

public nonisolated struct ManifestRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var schemaVersion: Int
    public var generation: Int
    public var rootPerson: String?
    public var personCount: Int
    public var relationshipCount: Int
    public var publishedAtISO: String

    public init(id: String, schemaVersion: Int = 1, generation: Int = 0,
                rootPerson: String? = nil, personCount: Int = 0,
                relationshipCount: Int = 0, publishedAtISO: String = "") {
        self.id = id
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.rootPerson = rootPerson
        self.personCount = personCount
        self.relationshipCount = relationshipCount
        self.publishedAtISO = publishedAtISO
    }
}

public nonisolated struct PersonRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var manifestID: String
    public var schemaVersion: Int
    public var displayName: String
    public var givenName: String?
    public var familyName: String?
    public var genderRaw: String?
    public var birthOriginal: String?
    public var birthEarliest: Int?
    public var birthLatest: Int?
    public var birthQualifierRaw: String?
    public var birthIsApproximate: Bool?
    public var birthPlace: String?
    public var deathOriginal: String?
    public var deathEarliest: Int?
    public var deathLatest: Int?
    public var deathQualifierRaw: String?
    public var deathIsApproximate: Bool?
    public var deathPlace: String?
    public var bioText: String
    public var citationsJSON: String
    public var badgesJSON: String
    public var isRedacted: Bool
    public var isProvisional: Bool

    public init(id: String, manifestID: String, schemaVersion: Int = 1,
                displayName: String = "", givenName: String? = nil,
                familyName: String? = nil, genderRaw: String? = nil,
                birthOriginal: String? = nil, birthEarliest: Int? = nil,
                birthLatest: Int? = nil, birthQualifierRaw: String? = nil,
                birthIsApproximate: Bool? = nil, birthPlace: String? = nil,
                deathOriginal: String? = nil, deathEarliest: Int? = nil,
                deathLatest: Int? = nil, deathQualifierRaw: String? = nil,
                deathIsApproximate: Bool? = nil, deathPlace: String? = nil,
                bioText: String = "", citationsJSON: String = "",
                badgesJSON: String = "", isRedacted: Bool = false,
                isProvisional: Bool = false) {
        self.id = id
        self.manifestID = manifestID
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.genderRaw = genderRaw
        self.birthOriginal = birthOriginal
        self.birthEarliest = birthEarliest
        self.birthLatest = birthLatest
        self.birthQualifierRaw = birthQualifierRaw
        self.birthIsApproximate = birthIsApproximate
        self.birthPlace = birthPlace
        self.deathOriginal = deathOriginal
        self.deathEarliest = deathEarliest
        self.deathLatest = deathLatest
        self.deathQualifierRaw = deathQualifierRaw
        self.deathIsApproximate = deathIsApproximate
        self.deathPlace = deathPlace
        self.bioText = bioText
        self.citationsJSON = citationsJSON
        self.badgesJSON = badgesJSON
        self.isRedacted = isRedacted
        self.isProvisional = isProvisional
    }
}

public nonisolated struct RelationshipRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var fromPersonID: String
    public var toPersonID: String
    public var schemaVersion: Int
    public var typeRaw: String
    public var roleRaw: String?
    public var subtypeRaw: String
    public var marriageOriginal: String?
    public var marriageEarliest: Int?
    public var marriageLatest: Int?
    public var marriageQualifierRaw: String?
    public var marriageIsApproximate: Bool?
    public var marriageLocation: String?
    public var divorceOriginal: String?
    public var divorceEarliest: Int?
    public var divorceLatest: Int?
    public var divorceQualifierRaw: String?
    public var divorceIsApproximate: Bool?

    public init(id: String, fromPersonID: String, toPersonID: String,
                schemaVersion: Int = 1, typeRaw: String, roleRaw: String? = nil,
                subtypeRaw: String = "unknown",
                marriageOriginal: String? = nil, marriageEarliest: Int? = nil,
                marriageLatest: Int? = nil, marriageQualifierRaw: String? = nil,
                marriageIsApproximate: Bool? = nil, marriageLocation: String? = nil,
                divorceOriginal: String? = nil, divorceEarliest: Int? = nil,
                divorceLatest: Int? = nil, divorceQualifierRaw: String? = nil,
                divorceIsApproximate: Bool? = nil) {
        self.id = id
        self.fromPersonID = fromPersonID
        self.toPersonID = toPersonID
        self.schemaVersion = schemaVersion
        self.typeRaw = typeRaw
        self.roleRaw = roleRaw
        self.subtypeRaw = subtypeRaw
        self.marriageOriginal = marriageOriginal
        self.marriageEarliest = marriageEarliest
        self.marriageLatest = marriageLatest
        self.marriageQualifierRaw = marriageQualifierRaw
        self.marriageIsApproximate = marriageIsApproximate
        self.marriageLocation = marriageLocation
        self.divorceOriginal = divorceOriginal
        self.divorceEarliest = divorceEarliest
        self.divorceLatest = divorceLatest
        self.divorceQualifierRaw = divorceQualifierRaw
        self.divorceIsApproximate = divorceIsApproximate
    }
}

public nonisolated struct EventRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var personID: String
    public var schemaVersion: Int
    public var kindRaw: String
    public var dateOriginal: String?
    public var dateEarliest: Int?
    public var dateLatest: Int?
    public var dateQualifierRaw: String?
    public var dateIsApproximate: Bool?
    public var location: String?
    public var detailsJSON: String?
    public var sourceURL: String?

    public init(id: String, personID: String, schemaVersion: Int = 1,
                kindRaw: String, dateOriginal: String? = nil,
                dateEarliest: Int? = nil, dateLatest: Int? = nil,
                dateQualifierRaw: String? = nil, dateIsApproximate: Bool? = nil,
                location: String? = nil, detailsJSON: String? = nil,
                sourceURL: String? = nil) {
        self.id = id
        self.personID = personID
        self.schemaVersion = schemaVersion
        self.kindRaw = kindRaw
        self.dateOriginal = dateOriginal
        self.dateEarliest = dateEarliest
        self.dateLatest = dateLatest
        self.dateQualifierRaw = dateQualifierRaw
        self.dateIsApproximate = dateIsApproximate
        self.location = location
        self.detailsJSON = detailsJSON
        self.sourceURL = sourceURL
    }
}

public nonisolated struct MediaRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var personID: String
    public var schemaVersion: Int
    public var kind: String
    public var caption: String?
    public var relativePath: String
    /// Cache-local copy of the CKAsset file (or the bundle's media/ file).
    /// nil when the asset hasn't been materialised.
    public var localAssetPath: String?

    public init(id: String, personID: String, schemaVersion: Int = 1,
                kind: String, caption: String? = nil, relativePath: String = "",
                localAssetPath: String? = nil) {
        self.id = id
        self.personID = personID
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.caption = caption
        self.relativePath = relativePath
        self.localAssetPath = localAssetPath
    }
}

/// One decoded record of any published type.
public nonisolated enum MappedRecord: Sendable, Equatable {
    case manifest(ManifestRow)
    case person(PersonRow)
    case relationship(RelationshipRow)
    case lifeEvent(EventRow)
    case media(MediaRow)
}

/// Decoded `badgesJSON` — publish-time completeness/convergence values.
/// Never recomputed viewer-side (spec decision log #4).
public nonisolated struct ViewerBadges: Codable, Sendable, Equatable {
    public let completenessScore: Int
    public let completenessMax: Int
    public let convergence: String?

    public init(completenessScore: Int, completenessMax: Int, convergence: String?) {
        self.completenessScore = completenessScore
        self.completenessMax = completenessMax
        self.convergence = convergence
    }
}

/// Decoded `citationsJSON` entry.
public nonisolated struct ViewerCitation: Codable, Sendable, Equatable {
    public let field: String
    public let source: String
    public let url: String?
    public let trustTier: Int?

    public init(field: String, source: String, url: String?, trustTier: Int?) {
        self.field = field
        self.source = source
        self.url = url
        self.trustTier = trustTier
    }
}

/// The schema version this build of the viewer core understands.
/// A manifest above this renders from cache under an "update the app"
/// banner (PUBLISHER_SPEC §4.3).
public nonisolated enum ViewerSchema {
    public static let supportedVersion = 1
}

nonisolated extension GenealogicalDate {
    /// Reconstruct from the published five-field encoding; nil when the
    /// record carries no date at all.
    init?(original: String?, earliest: Int?, latest: Int?,
          qualifierRaw: String?, isApproximate: Bool?) {
        guard original != nil || earliest != nil || latest != nil else { return nil }
        self.init(
            original: original ?? "",
            earliest: earliest,
            latest: latest,
            isApproximate: isApproximate ?? false,
            qualifier: DateQualifier(rawValue: qualifierRaw ?? "") ?? .yearOnly)
    }
}
