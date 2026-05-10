import Foundation
import GRDB

/// Life event persistence (M12). Adds, updates, deletes, loads `LifeEvent`
/// records keyed on profileID. Per DESIGN.md §5.13.
nonisolated extension ProjectDatabase {

    @discardableResult
    func addLifeEvent(_ event: LifeEvent) throws -> LifeEvent {
        try dbQueue.write { db in
            try Self.insertLifeEvent(event, db: db)
        }
        return event
    }

    @discardableResult
    func updateLifeEvent(_ event: LifeEvent) throws -> LifeEvent {
        let sourcesJSON = Self.encodeJSON(event.sources)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE life_events
                SET type = ?,
                    date_original = ?, date_earliest = ?, date_latest = ?,
                    date_qualifier = ?, date_approximate = ?,
                    end_date_original = ?, end_date_earliest = ?, end_date_latest = ?,
                    end_date_qualifier = ?, end_date_approximate = ?,
                    location = ?, description = ?,
                    sources_json = ?, confidence = ?, sensitive = ?
                WHERE id = ?
                """, arguments: [
                    event.type.rawValue,
                    event.date?.original, event.date?.earliest, event.date?.latest,
                    event.date?.qualifier.rawValue, event.date.map { $0.isApproximate ? 1 : 0 },
                    event.endDate?.original, event.endDate?.earliest, event.endDate?.latest,
                    event.endDate?.qualifier.rawValue, event.endDate.map { $0.isApproximate ? 1 : 0 },
                    event.location, event.description,
                    sourcesJSON, event.confidence.rawInt,
                    event.sensitive ? 1 : 0,
                    event.id.uuidString,
                ])
        }
        return event
    }

    func deleteLifeEvent(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM life_events WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func loadLifeEvents(profileID: String) throws -> [LifeEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM life_events WHERE profile_id = ?
                """, arguments: [profileID])
            return rows.compactMap(Self.lifeEventFromRow)
                .sorted { ($0.sortYear ?? .max) < ($1.sortYear ?? .max) }
        }
    }

    func loadAllLifeEvents() throws -> [LifeEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM life_events")
            return rows.compactMap(Self.lifeEventFromRow)
        }
    }

    // MARK: - Row encoding/decoding

    static func insertLifeEvent(_ event: LifeEvent, db: Database) throws {
        let sourcesJSON = encodeJSON(event.sources)
        try db.execute(sql: """
            INSERT INTO life_events
              (id, profile_id, type,
               date_original, date_earliest, date_latest, date_qualifier, date_approximate,
               end_date_original, end_date_earliest, end_date_latest, end_date_qualifier, end_date_approximate,
               location, description, sources_json, confidence, created_by_transaction_id, sensitive)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id.uuidString, event.profileID, event.type.rawValue,
                event.date?.original, event.date?.earliest, event.date?.latest,
                event.date?.qualifier.rawValue, event.date.map { $0.isApproximate ? 1 : 0 },
                event.endDate?.original, event.endDate?.earliest, event.endDate?.latest,
                event.endDate?.qualifier.rawValue, event.endDate.map { $0.isApproximate ? 1 : 0 },
                event.location, event.description, sourcesJSON, event.confidence.rawInt,
                event.createdByTransactionID?.uuidString,
                event.sensitive ? 1 : 0,
            ])
    }

    static func lifeEventFromRow(_ row: Row) -> LifeEvent? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let profileID: String = row["profile_id"],
            let typeStr: String = row["type"], let type = LifeEventType(rawValue: typeStr),
            let sourcesJSON: String = row["sources_json"],
            let sourcesData = sourcesJSON.data(using: .utf8),
            let sources = try? JSONDecoder().decode([FieldSource].self, from: sourcesData),
            let confidenceRaw: Int = row["confidence"],
            let confidence = FactConfidence(rawInt: confidenceRaw)
        else { return nil }

        let date = decodeLifeEventDate(row, prefix: "date")
        let endDate = decodeLifeEventDate(row, prefix: "end_date")

        let txIDStr: String? = row["created_by_transaction_id"]
        let txID = txIDStr.flatMap(UUID.init(uuidString:))
        let sensitiveRaw: Int? = row["sensitive"]
        let sensitive = (sensitiveRaw ?? 0) == 1

        return LifeEvent(
            id: id, profileID: profileID, type: type,
            date: date, endDate: endDate,
            location: row["location"], description: row["description"],
            sources: sources, confidence: confidence,
            createdByTransactionID: txID,
            sensitive: sensitive
        )
    }

    private static func decodeLifeEventDate(_ row: Row, prefix: String) -> GenealogicalDate? {
        guard let original: String = row["\(prefix)_original"] else { return nil }
        let earliest: Int? = row["\(prefix)_earliest"]
        let latest: Int? = row["\(prefix)_latest"]
        let qualifierStr: String? = row["\(prefix)_qualifier"]
        let qualifier = qualifierStr.flatMap(DateQualifier.init(rawValue:)) ?? .yearOnly
        let approxRaw: Int? = row["\(prefix)_approximate"]
        let isApproximate = (approxRaw ?? 0) == 1
        return GenealogicalDate(
            original: original,
            earliest: earliest, latest: latest,
            isApproximate: isApproximate,
            qualifier: qualifier
        )
    }
}
