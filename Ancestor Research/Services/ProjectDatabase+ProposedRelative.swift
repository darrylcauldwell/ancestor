import Foundation

/// Shared accept-relative helper used by both `ResearchViewModel` (cluster
/// review) and `CleanseEngine` (cleanse wizard). Centralises the ghost-
/// profile construction so the two call sites can\u{2019}t drift.
nonisolated extension ProjectDatabase {

    /// Create a ghost profile + parent-of edge for an accepted proposal.
    /// Returns the new ghost profile ID. Caller is responsible for any
    /// post-accept state (snapshot refresh, decision tracking).
    @discardableResult
    func acceptProposedRelative(_ proposal: ProposedRelative) throws -> String {
        guard case .parentOf(let subjectID) = proposal.relationship else {
            throw CleanseError.unsupportedRelationship
        }

        let ghostID = UUID().uuidString
        let ghost = Self.makeGhostProfile(id: ghostID, from: proposal)

        let role: ParentRole = switch proposal.gender {
        case .male:   .father
        case .female: .mother
        default:      .unspecified
        }

        let parentEdge = Relationship(
            id: UUID(),
            from: ghostID,
            to: subjectID,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )

        _ = try addFamily(
            profiles: [ghost],
            relationships: [parentEdge],
            source: .freebmd
        )

        return ghostID
    }

    /// Construct the ghost Profile that backs an accepted proposal. Mirrors
    /// the legacy private helper that previously lived in `ResearchViewModel`.
    static func makeGhostProfile(id: String, from proposal: ProposedRelative) -> Profile {
        let birthDate: GenealogicalDate?
        switch (proposal.birthYearLow, proposal.birthYearHigh) {
        case let (lo?, hi?):
            birthDate = GenealogicalDate(parsing: "BET \(lo) AND \(hi)")
        case let (lo?, nil):
            birthDate = GenealogicalDate(parsing: "AFT \(lo)")
        case let (nil, hi?):
            birthDate = GenealogicalDate(parsing: "BEF \(hi)")
        case (nil, nil):
            birthDate = nil
        }

        return Profile(
            id: id,
            externalIDs: [:],
            firstName: proposal.proposedGivenName,
            lastName: proposal.proposedSurname,
            gender: proposal.gender,
            attributes: PersonAttributes(
                nameStatus: proposal.proposedGivenName == nil ? .placeholder : .known,
                lifeStatus: .normal,
                privacy: .normal
            ),
            birthDate: birthDate,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }
}

/// Errors surfaced by the cleanse engine and shared accept-relative helper.
nonisolated enum CleanseError: Error, LocalizedError, Sendable {
    case unsupportedRelationship
    case missingDatabase
    case profileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRelationship:
            return "Only parent-of proposals can be accepted at the moment."
        case .missingDatabase:
            return "No project is open."
        case .profileNotFound(let id):
            return "Profile \(id) was not found in the snapshot."
        }
    }
}
