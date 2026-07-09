import Foundation

// Family-bundle JSON → rows. The bundle (Export Family Bundle…, PUBLISHER
// Change 2) carries the same records with the same UUIDs as the CloudKit
// zone, so a bundle-backed source exercises the exact pipeline the zone
// does — this is the offline test harness and the "family gathering"
// demo path. JSON shapes per AncestorApp/family-bundle.schema.json
// (nested date objects, where CK records carry flattened columns).

public nonisolated enum BundleDecoder {

    /// Decode a bundle directory into a manifest + records, ready for
    /// `ViewerCache.apply`. The bundle's manifest.json has no record UUID
    /// (it is one per bundle), so a stable synthetic id is minted.
    public static func decode(bundleDirectory: URL) throws -> (manifest: ManifestRow, records: [MappedRecord]) {
        func data(_ file: String) throws -> Data {
            try Data(contentsOf: bundleDirectory.appendingPathComponent(file))
        }
        return try decode(
            manifestJSON: data("manifest.json"),
            peopleJSON: data("people.json"),
            relationshipsJSON: data("relationships.json"),
            eventsJSON: data("events.json"),
            mediaJSON: data("media.json"),
            mediaDirectory: bundleDirectory.appendingPathComponent("media"))
    }

    public static func decode(
        manifestJSON: Data,
        peopleJSON: Data,
        relationshipsJSON: Data,
        eventsJSON: Data,
        mediaJSON: Data,
        mediaDirectory: URL? = nil
    ) throws -> (manifest: ManifestRow, records: [MappedRecord]) {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(BundleManifest.self, from: manifestJSON)
        let people = try decoder.decode([BundlePerson].self, from: peopleJSON)
        let relationships = try decoder.decode([BundleRelationship].self, from: relationshipsJSON)
        let events = try decoder.decode([BundleLifeEvent].self, from: eventsJSON)
        let media = try decoder.decode([BundleMedia].self, from: mediaJSON)

        let manifestID = "bundle-manifest"
        let manifestRow = ManifestRow(
            id: manifestID,
            schemaVersion: manifest.schemaVersion,
            generation: manifest.generation,
            rootPerson: manifest.rootPerson,
            personCount: manifest.personCount,
            relationshipCount: manifest.relationshipCount,
            publishedAtISO: manifest.publishedAtISO)

        var records: [MappedRecord] = [.manifest(manifestRow)]

        for p in people {
            records.append(.person(PersonRow(
                id: p.id, manifestID: manifestID, schemaVersion: p.schemaVersion,
                displayName: p.displayName, givenName: p.givenName,
                familyName: p.familyName, genderRaw: p.genderRaw,
                birthOriginal: p.birth?.original, birthEarliest: p.birth?.earliest,
                birthLatest: p.birth?.latest, birthQualifierRaw: p.birth?.qualifierRaw,
                birthIsApproximate: p.birth?.isApproximate, birthPlace: p.birthPlace,
                deathOriginal: p.death?.original, deathEarliest: p.death?.earliest,
                deathLatest: p.death?.latest, deathQualifierRaw: p.death?.qualifierRaw,
                deathIsApproximate: p.death?.isApproximate, deathPlace: p.deathPlace,
                bioText: p.bioText, citationsJSON: p.citationsJSON,
                badgesJSON: p.badgesJSON, isRedacted: p.isRedacted,
                isProvisional: p.isProvisional)))
        }
        for r in relationships {
            records.append(.relationship(RelationshipRow(
                id: r.id, fromPersonID: r.fromPerson, toPersonID: r.toPerson,
                schemaVersion: r.schemaVersion, typeRaw: r.typeRaw,
                roleRaw: r.roleRaw, subtypeRaw: r.subtypeRaw,
                marriageOriginal: r.marriage?.original, marriageEarliest: r.marriage?.earliest,
                marriageLatest: r.marriage?.latest, marriageQualifierRaw: r.marriage?.qualifierRaw,
                marriageIsApproximate: r.marriage?.isApproximate, marriageLocation: r.marriageLocation,
                divorceOriginal: r.divorce?.original, divorceEarliest: r.divorce?.earliest,
                divorceLatest: r.divorce?.latest, divorceQualifierRaw: r.divorce?.qualifierRaw,
                divorceIsApproximate: r.divorce?.isApproximate)))
        }
        for e in events {
            records.append(.lifeEvent(EventRow(
                id: e.id, personID: e.person, schemaVersion: e.schemaVersion,
                kindRaw: e.kindRaw, dateOriginal: e.date?.original,
                dateEarliest: e.date?.earliest, dateLatest: e.date?.latest,
                dateQualifierRaw: e.date?.qualifierRaw, dateIsApproximate: e.date?.isApproximate,
                location: e.location, detailsJSON: e.detailsJSON, sourceURL: e.sourceURL)))
        }
        for m in media {
            let localPath = mediaDirectory.map { $0.appendingPathComponent(m.relativePath).path }
            records.append(.media(MediaRow(
                id: m.id, personID: m.person, schemaVersion: m.schemaVersion,
                kind: m.kind, caption: m.caption, relativePath: m.relativePath,
                localAssetPath: localPath.flatMap {
                    FileManager.default.fileExists(atPath: $0) ? $0 : nil
                })))
        }
        return (manifestRow, records)
    }
}

// MARK: - Bundle JSON shapes (family-bundle.schema.json)

private nonisolated struct BundleDate: Decodable {
    let original: String
    let earliest: Int?
    let latest: Int?
    let qualifierRaw: String
    let isApproximate: Bool
}

private nonisolated struct BundleManifest: Decodable {
    let schemaVersion: Int
    let generation: Int
    let rootPerson: String?
    let personCount: Int
    let relationshipCount: Int
    let publishedAtISO: String
}

private nonisolated struct BundlePerson: Decodable {
    let id: String
    let schemaVersion: Int
    let displayName: String
    let givenName: String?
    let familyName: String?
    let genderRaw: String?
    let birth: BundleDate?
    let birthPlace: String?
    let death: BundleDate?
    let deathPlace: String?
    let bioText: String
    let citationsJSON: String
    let badgesJSON: String
    let isRedacted: Bool
    let isProvisional: Bool
}

private nonisolated struct BundleRelationship: Decodable {
    let id: String
    let schemaVersion: Int
    let fromPerson: String
    let toPerson: String
    let typeRaw: String
    let roleRaw: String?
    let subtypeRaw: String
    let marriage: BundleDate?
    let marriageLocation: String?
    let divorce: BundleDate?
}

private nonisolated struct BundleLifeEvent: Decodable {
    let id: String
    let schemaVersion: Int
    let person: String
    let kindRaw: String
    let date: BundleDate?
    let location: String?
    let detailsJSON: String?
    let sourceURL: String?
}

private nonisolated struct BundleMedia: Decodable {
    let id: String
    let schemaVersion: Int
    let person: String
    let kind: String
    let caption: String?
    let relativePath: String
}
