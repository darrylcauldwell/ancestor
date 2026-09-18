import Foundation
import GRDB
import AncestorKit

/// Correcting the location TEXT itself (Location model Part III).
///
/// The Places tab deliberately refuses to edit the tree from a triage screen —
/// settling a place records where it is, and never rewrites what you wrote. But
/// that leaves a whole class with no honest action at all: `Ashborne` is a
/// misspelling of a district the app knows perfectly well, and `-` is not a
/// place, a house or a street, it is a stray character. Neither "this isn't a
/// place" nor binding a district is true of them; the only correct answer is to
/// fix the text.
///
/// So this is a separate, explicit action rather than a side effect of settling,
/// and it goes through the same transaction + `field_changes` machinery as any
/// other profile edit — so it lands in profile history and is undoable, which a
/// bare UPDATE would not be.
nonisolated extension ProjectDatabase {

    /// Rewrite the location text on specific fields.
    ///
    /// - Parameter newText: the replacement; empty or whitespace clears the
    ///   field, which is the right answer for `-` and other junk.
    /// - Returns: how many fields were rewritten.
    @discardableResult
    func correctLocationText(
        profileFields: [(profileID: String, field: ProfileField)],
        lifeEventIDs: [UUID],
        to newText: String,
        source: SourceOrigin = .manual
    ) throws -> Int {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        var changed = 0

        if !profileFields.isEmpty {
            let transactionID = UUID()
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO transactions
                      (id, kind, undo_strategy, started_at, completed_at, change_count, profile_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        transactionID.uuidString,
                        Self.encodeJSON(TransactionKind.manualEdit),
                        UndoStrategy.replay.rawValue,
                        Date(), Date(),
                        profileFields.count,
                        Set(profileFields.map(\.profileID)).count,
                    ])
                for target in profileFields {
                    guard let column = Self.profileFieldToColumn(target.field.rawValue) else { continue }
                    let current = try String.fetchOne(
                        db, sql: "SELECT \(column) FROM profiles WHERE id = ?",
                        arguments: [target.profileID])
                    guard current != value else { continue }
                    try self.updateProfileField(
                        profileID: target.profileID, field: target.field,
                        oldValue: current, newValue: value,
                        source: source, transactionID: transactionID, db: db)
                    changed += 1
                }
            }
        }

        // Life events carry no per-field change log, so this is a direct write.
        // The structured code is cleared alongside: it was resolved from the OLD
        // text, and leaving it would silently attach the previous place's
        // identity to different words.
        for eventID in lifeEventIDs {
            try dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE life_events SET location = ?, location_code = NULL WHERE id = ?
                    """, arguments: [value, eventID.uuidString])
            }
            changed += 1
        }
        return changed
    }
}
