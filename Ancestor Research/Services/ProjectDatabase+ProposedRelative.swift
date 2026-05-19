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

    /// Create a ghost profile for an accepted sibling proposal and wire it to
    /// BOTH parents of the subject in one atomic transaction. Returns the new
    /// ghost profile ID. The caller (`ResearchViewModel.acceptSibling`) is
    /// responsible for snapshot refresh and decision tracking.
    @discardableResult
    func acceptSiblingProposal(_ proposal: SiblingProposal) throws -> String {
        let ghostID = UUID().uuidString
        let ghost = Self.makeGhostProfile(id: ghostID, from: proposal)

        let fatherEdge = Relationship(
            id: UUID(),
            from: proposal.fatherID,
            to: ghostID,
            type: .parent,
            role: .father,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
        let motherEdge = Relationship(
            id: UUID(),
            from: proposal.motherID,
            to: ghostID,
            type: .parent,
            role: .mother,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )

        _ = try addFamily(
            profiles: [ghost],
            relationships: [fatherEdge, motherEdge],
            source: .freebmd
        )

        return ghostID
    }

    /// Construct the ghost Profile that backs an accepted sibling proposal.
    /// Mirrors `makeGhostProfile(id:from:)` for `ProposedRelative` — the
    /// fields available differ (sibling has a concrete birth year and
    /// district; parent has a low/high range), so we build them in their
    /// natural shapes here rather than coercing through a common type.
    static func makeGhostProfile(id: String, from proposal: SiblingProposal) -> Profile {
        let birthDate: GenealogicalDate? = proposal.birthYear.flatMap { year in
            GenealogicalDate(parsing: "ABT \(year)")
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
            birthLocation: proposal.district,
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
