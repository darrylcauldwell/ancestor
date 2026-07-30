import Foundation
import GRDB
import AncestorKit

/// One logged WikiTree contribution offer (v54): a MergeEdit review page was
/// opened in the browser for this profile. "Offered", never "saved" — the
/// commit (or not) happens on wikitree.com in the member's session.
nonisolated struct WikiTreeContributionRecord: Sendable, Equatable {
    let id: String
    let profileID: String
    let wikiTreeID: String
    let fieldsJSON: String
    let bioAppended: Bool
    let summary: String?
    let openedAt: Date
}

/// Persistence for the WikiTree contribution log (WT4,
/// WIKITREE_MERGEEDIT_SPEC §5).
nonisolated extension ProjectDatabase {

    func recordWikiTreeContribution(
        profileID: String, wikiTreeID: String,
        fieldsJSON: String, bioAppended: Bool, summary: String?,
        at date: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO wikitree_contributions
                  (id, profile_id, wikitree_id, fields_json, bio_appended, summary, opened_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "wtc_\(UUID().uuidString)", profileID, wikiTreeID,
                    fieldsJSON, bioAppended, summary, date,
                ])
        }
    }

    /// Contribution offers for one profile, newest first — feeds the sheet's
    /// "last offered" line so repeat offers are visible.
    func wikiTreeContributions(profileID: String) throws -> [WikiTreeContributionRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM wikitree_contributions
                WHERE profile_id = ? ORDER BY opened_at DESC
                """, arguments: [profileID])
            return rows.map { row in
                WikiTreeContributionRecord(
                    id: row["id"], profileID: row["profile_id"], wikiTreeID: row["wikitree_id"],
                    fieldsJSON: row["fields_json"], bioAppended: row["bio_appended"],
                    summary: row["summary"], openedAt: row["opened_at"])
            }
        }
    }
}
