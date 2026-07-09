import Foundation
import CloudKit

// CKRecord → row decoding. Every published field is ENCRYPTED in the
// production schema (published-schema-v1.ckdb), so values are read from
// `record.encryptedValues` — the one exception is `asset`, a plain ASSET
// field. Unknown record types and unknown fields are ignored silently
// (PUBLISHER_SPEC §4.3 forward compatibility); a record missing its `id`
// falls back to the SQLiteData record-name convention `<uuid>:<tableName>`.

public nonisolated enum RecordMapper {

    public static let manifestType = "publishedManifests"
    public static let personType = "publishedPersons"
    public static let relationshipType = "publishedRelationships"
    public static let lifeEventType = "publishedLifeEvents"
    public static let mediaType = "publishedMedia"

    /// Decode one CKRecord. `materialiseAsset` is called for media records
    /// that carry an asset file (the fetcher copies it somewhere durable
    /// and returns the local path); decode failures return nil rather than
    /// throwing — one undecodable record must not abort a zone fetch.
    public static func map(
        _ record: CKRecord,
        materialiseAsset: (URL, String) -> String? = { _, _ in nil }
    ) -> MappedRecord? {
        guard let id = rowID(of: record) else { return nil }
        let enc = record.encryptedValues

        switch record.recordType {
        case manifestType:
            return .manifest(ManifestRow(
                id: id,
                schemaVersion: int(enc[Key.schemaVersion]) ?? 1,
                generation: int(enc["generation"]) ?? 0,
                rootPerson: string(enc["rootPerson"]),
                personCount: int(enc["personCount"]) ?? 0,
                relationshipCount: int(enc["relationshipCount"]) ?? 0,
                publishedAtISO: string(enc["publishedAtISO"]) ?? ""))

        case personType:
            guard let manifestID = string(enc["manifestID"]) else { return nil }
            return .person(PersonRow(
                id: id,
                manifestID: manifestID,
                schemaVersion: int(enc[Key.schemaVersion]) ?? 1,
                displayName: string(enc["displayName"]) ?? "",
                givenName: string(enc["givenName"]),
                familyName: string(enc["familyName"]),
                genderRaw: string(enc["genderRaw"]),
                birthOriginal: string(enc["birthOriginal"]),
                birthEarliest: int(enc["birthEarliest"]),
                birthLatest: int(enc["birthLatest"]),
                birthQualifierRaw: string(enc["birthQualifierRaw"]),
                birthIsApproximate: bool(enc["birthIsApproximate"]),
                birthPlace: string(enc["birthPlace"]),
                deathOriginal: string(enc["deathOriginal"]),
                deathEarliest: int(enc["deathEarliest"]),
                deathLatest: int(enc["deathLatest"]),
                deathQualifierRaw: string(enc["deathQualifierRaw"]),
                deathIsApproximate: bool(enc["deathIsApproximate"]),
                deathPlace: string(enc["deathPlace"]),
                bioText: string(enc["bioText"]) ?? "",
                citationsJSON: string(enc["citationsJSON"]) ?? "",
                badgesJSON: string(enc["badgesJSON"]) ?? "",
                isRedacted: bool(enc["isRedacted"]) ?? false,
                isProvisional: bool(enc["isProvisional"]) ?? false))

        case relationshipType:
            guard let fromPersonID = string(enc["fromPersonID"]) else { return nil }
            return .relationship(RelationshipRow(
                id: id,
                fromPersonID: fromPersonID,
                toPersonID: string(enc["toPersonID"]) ?? "",
                schemaVersion: int(enc[Key.schemaVersion]) ?? 1,
                typeRaw: string(enc["typeRaw"]) ?? "",
                roleRaw: string(enc["roleRaw"]),
                subtypeRaw: string(enc["subtypeRaw"]) ?? "unknown",
                marriageOriginal: string(enc["marriageOriginal"]),
                marriageEarliest: int(enc["marriageEarliest"]),
                marriageLatest: int(enc["marriageLatest"]),
                marriageQualifierRaw: string(enc["marriageQualifierRaw"]),
                marriageIsApproximate: bool(enc["marriageIsApproximate"]),
                marriageLocation: string(enc["marriageLocation"]),
                divorceOriginal: string(enc["divorceOriginal"]),
                divorceEarliest: int(enc["divorceEarliest"]),
                divorceLatest: int(enc["divorceLatest"]),
                divorceQualifierRaw: string(enc["divorceQualifierRaw"]),
                divorceIsApproximate: bool(enc["divorceIsApproximate"])))

        case lifeEventType:
            guard let personID = string(enc["personID"]) else { return nil }
            return .lifeEvent(EventRow(
                id: id,
                personID: personID,
                schemaVersion: int(enc[Key.schemaVersion]) ?? 1,
                kindRaw: string(enc["kindRaw"]) ?? "",
                dateOriginal: string(enc["dateOriginal"]),
                dateEarliest: int(enc["dateEarliest"]),
                dateLatest: int(enc["dateLatest"]),
                dateQualifierRaw: string(enc["dateQualifierRaw"]),
                dateIsApproximate: bool(enc["dateIsApproximate"]),
                location: string(enc["location"]),
                detailsJSON: string(enc["detailsJSON"]),
                sourceURL: string(enc["sourceURL"])))

        case mediaType:
            guard let personID = string(enc["personID"]) else { return nil }
            var localAssetPath: String?
            if let asset = record["asset"] as? CKAsset, let fileURL = asset.fileURL {
                localAssetPath = materialiseAsset(fileURL, id)
            }
            return .media(MediaRow(
                id: id,
                personID: personID,
                schemaVersion: int(enc[Key.schemaVersion]) ?? 1,
                kind: string(enc["kind"]) ?? "",
                caption: string(enc["caption"]),
                relativePath: string(enc["relativePath"]) ?? "",
                localAssetPath: localAssetPath))

        default:
            return nil
        }
    }

    /// The row primary key: the encrypted `id` field, falling back to the
    /// `<uuid>:<tableName>` record-name convention.
    static func rowID(of record: CKRecord) -> String? {
        if let id = record.encryptedValues["id"] as? String, !id.isEmpty { return id }
        return rowID(fromRecordName: record.recordID.recordName)
    }

    /// Parse `<uuid>:<tableName>` → uuid. Returns nil for names that don't
    /// follow the convention (e.g. `cloudkit.share` records).
    static func rowID(fromRecordName name: String) -> String? {
        guard let colon = name.firstIndex(of: ":"), colon != name.startIndex else { return nil }
        return String(name[name.startIndex..<colon])
    }

    /// Parse `<uuid>:<tableName>` → tableName.
    static func tableName(fromRecordName name: String) -> String? {
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let table = String(name[name.index(after: colon)...])
        return table.isEmpty ? nil : table
    }

    private enum Key {
        static let schemaVersion = "schemaVersion"
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int(_ value: Any?) -> Int? {
        if let v = value as? Int64 { return Int(v) }
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        int(value).map { $0 != 0 }
    }
}
