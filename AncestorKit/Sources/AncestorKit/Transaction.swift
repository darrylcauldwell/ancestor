import Foundation

/// First-class transaction — groups related changes for atomic undo.
public nonisolated struct Transaction: Codable, Identifiable, Sendable {
    public let id: UUID
    public let kind: TransactionKind
    public let undoStrategy: UndoStrategy
    public let startedAt: Date
    public let completedAt: Date
    public let changeCount: Int
    public let profileCount: Int

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, kind: TransactionKind, undoStrategy: UndoStrategy, startedAt: Date, completedAt: Date, changeCount: Int, profileCount: Int) {
        self.id = id
        self.kind = kind
        self.undoStrategy = undoStrategy
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.changeCount = changeCount
        self.profileCount = profileCount
    }


    /// Computed at display time — not stored. Avoids stale strings.
    public var summary: String {
        switch kind {
        case .importGEDCOM(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Imported \(filename) (\(profileCount) profiles)"
        case .refreshWikiTree:
            return "WikiTree refresh (\(changeCount) changes)"
        case .addProfile:
            return "Added person"
        case .addFamily:
            return "Added family (\(profileCount) people)"
        case .addRelationship:
            return "Added relationship"
        case .removeRelationship:
            return "Removed relationship"
        case .softDelete:
            return "Removed \(profileCount > 1 ? "\(profileCount) people" : "person")"
        case .manualEdit:
            return "Manual edit (\(changeCount) fields)"
        case .resolveDispute(let field, _):
            return "Resolved \(field.rawValue) dispute"
        case .undo(let txID):
            return "Undo (\(txID.uuidString.prefix(8)))"
        }
    }
}

public nonisolated enum TransactionKind: Codable, Sendable {
    case importGEDCOM(path: String)
    case refreshWikiTree
    case addProfile(profileID: String)
    case addFamily(profileIDs: [String])
    case addRelationship(relationshipID: UUID)
    case removeRelationship(relationshipID: UUID)
    case softDelete(profileIDs: [String])
    case manualEdit
    case resolveDispute(field: ProfileField, profileID: String)
    case undo(ofTransactionID: UUID)
}

/// How to reverse a transaction.
/// - structural: import — delete all entities created by this transaction
/// - replay: edit/refresh/resolve — reverse each FieldChange
public nonisolated enum UndoStrategy: String, Codable, Sendable {
    case structural
    case replay
}

/// Individual entity change — always belongs to a Transaction.
public nonisolated struct FieldChange: Codable, Identifiable, Sendable {
    public let id: UUID
    public let transactionID: UUID
    public let entityID: String
    public let entityKind: EntityKind
    public let field: ChangeField
    public let oldValue: String?
    public let newValue: String
    public let source: SourceOrigin
    public let reason: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, transactionID: UUID, entityID: String, entityKind: EntityKind, field: ChangeField, oldValue: String? = nil, newValue: String, source: SourceOrigin, reason: String? = nil) {
        self.id = id
        self.transactionID = transactionID
        self.entityID = entityID
        self.entityKind = entityKind
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.reason = reason
    }

}

public nonisolated enum EntityKind: String, Codable, Sendable {
    case profile
    case relationship
}
