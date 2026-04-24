import Foundation

/// First-class transaction — groups related changes for atomic undo.
struct Transaction: Codable, Identifiable, Sendable {
    let id: UUID
    let kind: TransactionKind
    let undoStrategy: UndoStrategy
    let startedAt: Date
    let completedAt: Date
    let changeCount: Int
    let profileCount: Int

    /// Computed at display time — not stored. Avoids stale strings.
    var summary: String {
        switch kind {
        case .importGEDCOM(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Imported \(filename) (\(profileCount) profiles)"
        case .refreshWikiTree:
            return "WikiTree refresh (\(changeCount) changes)"
        case .manualEdit:
            return "Manual edit (\(changeCount) fields)"
        case .resolveDispute(let field, _):
            return "Resolved \(field.rawValue) dispute"
        case .undo(let txID):
            return "Undo (\(txID.uuidString.prefix(8)))"
        }
    }
}

enum TransactionKind: Codable, Sendable {
    case importGEDCOM(path: String)
    case refreshWikiTree
    case manualEdit
    case resolveDispute(field: ProfileField, profileID: String)
    case undo(ofTransactionID: UUID)
}

/// How to reverse a transaction.
/// - structural: import — delete all entities created by this transaction
/// - replay: edit/refresh/resolve — reverse each FieldChange
enum UndoStrategy: String, Codable, Sendable {
    case structural
    case replay
}

/// Individual entity change — always belongs to a Transaction.
struct FieldChange: Codable, Identifiable, Sendable {
    let id: UUID
    let transactionID: UUID
    let entityID: String
    let entityKind: EntityKind
    let field: ChangeField
    let oldValue: String?
    let newValue: String
    let source: SourceOrigin
    let reason: String?
}

enum EntityKind: String, Codable, Sendable {
    case profile
    case relationship
}
