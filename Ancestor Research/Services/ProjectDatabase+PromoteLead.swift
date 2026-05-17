import Foundation

/// Promote a Lead to a ghost Profile. Closes the "lead investigation"
/// loop opened by `startResearch(lead:)` — once the user has reviewed the
/// findings in Triage and decides the lead is real, this turns the lead
/// into an actual Profile node so the existing apply paths (cluster Apply,
/// proposed-relative Apply, marriage-to-spouse-edge) have a target.
///
/// Same overwrite-safe + idempotent transaction shape as
/// `acceptProposedRelative` — both build their ghost Profile via shared
/// patterns and commit one `addFamily` transaction so audit/undo work
/// uniformly. The lead row stays in the DB with status `.promoted` so
/// re-promoting is a no-op visible in the Leads tab.
nonisolated extension ProjectDatabase {

    /// Promote a Lead — creates a ghost Profile from its fields and, when
    /// the lead carries a relationship hint, attaches an edge to the
    /// generating profile so the promoted person appears in the right place
    /// in the tree. Marks `lead.status = .promoted`. Returns the new ghost
    /// Profile ID so the caller can persist evidence under it.
    @discardableResult
    func promoteLeadToProfile(_ lead: Lead) throws -> String {
        let ghostID = UUID().uuidString
        let ghost = Self.makeGhostProfile(id: ghostID, fromLead: lead)

        var relationships: [Relationship] = []
        let generatorID = lead.profileID
        if !generatorID.isEmpty,
           let edge = Self.relationshipEdge(
               fromLead: lead, ghostID: ghostID, generatorID: generatorID
           ) {
            relationships.append(edge)
        }

        _ = try addFamily(
            profiles: [ghost],
            relationships: relationships,
            source: .freebmd
        )

        // Persist promotion on the lead itself so the Leads tab reflects
        // the resolution and the same lead doesn't reappear in the queue.
        let promoted = Lead(
            id: lead.id, profileID: lead.profileID,
            name: lead.name, surname: lead.surname, givenName: lead.givenName,
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            relationship: lead.relationship, source: lead.source,
            status: .promoted, evidence: lead.evidence,
            createdAt: lead.createdAt,
            investigatedAt: lead.investigatedAt,
            resolvedAt: Date(),
            resolution: .promoted
        )
        try saveLead(promoted)

        return ghostID
    }

    /// Build a Profile from a Lead's fields. Birth/death years become
    /// year-granularity GenealogicalDates so they show in the timeline.
    /// `nameStatus.placeholder` flags the new node visually as a research
    /// stub — same UI treatment as ghost relatives.
    nonisolated static func makeGhostProfile(id: String, fromLead lead: Lead) -> Profile {
        let trimmedGiven = lead.givenName?.trimmingCharacters(in: .whitespaces)
        let trimmedSurname = lead.surname?.trimmingCharacters(in: .whitespaces)
        let birthDate: GenealogicalDate? = lead.birthYear.map {
            GenealogicalDate(parsing: String($0))
        }
        let deathDate: GenealogicalDate? = lead.deathYear.map {
            GenealogicalDate(parsing: String($0))
        }
        return Profile(
            id: id,
            externalIDs: [:],
            firstName: (trimmedGiven?.isEmpty ?? true) ? nil : trimmedGiven,
            lastName: (trimmedSurname?.isEmpty ?? true) ? nil : trimmedSurname,
            gender: nil,
            attributes: PersonAttributes(
                nameStatus: (trimmedGiven?.isEmpty ?? true) ? .placeholder : .known,
                lifeStatus: .normal,
                privacy: .normal
            ),
            birthDate: birthDate,
            birthLocation: nil,
            deathDate: deathDate,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    /// Map a Lead's free-text `relationship` to a structural edge between
    /// the ghost and the generating profile. Returns nil for unrecognised
    /// or absent relationships — the ghost is still created, just
    /// freestanding for the user to wire up manually. Sibling promotion
    /// would need shared-parent inference, which is out of scope here.
    nonisolated static func relationshipEdge(
        fromLead lead: Lead,
        ghostID: String,
        generatorID: String
    ) -> Relationship? {
        let kind = (lead.relationship ?? "").lowercased()
        switch kind {
        case "spouse":
            return Relationship(
                id: UUID(),
                from: ghostID, to: generatorID,
                type: .spouse, role: nil, subtype: .unknown,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            )
        case "child":
            // Generator is the parent of the promoted person.
            return Relationship(
                id: UUID(),
                from: generatorID, to: ghostID,
                type: .parent, role: .unspecified, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            )
        case "parent", "father", "mother":
            // Promoted person is the parent of the generator.
            let role: ParentRole = kind == "father" ? .father
                : kind == "mother" ? .mother
                : .unspecified
            return Relationship(
                id: UUID(),
                from: ghostID, to: generatorID,
                type: .parent, role: role, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            )
        default:
            return nil
        }
    }
}
