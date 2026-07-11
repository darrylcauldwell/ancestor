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

        // E4 (§Change4): this parent edge exists because of the record that
        // implied the parent's surname — the child's birth record, the first
        // entry in the proposal's evidence. Cite it. If somehow no evidence is
        // attached (defensive; a ProposedRelative is by construction derived
        // from a record) the edge is created bare — never fabricate a source.
        var edgeExistence: [UUID: RelationshipExistenceEvidence] = [:]
        if let driving = proposal.evidence.first {
            edgeExistence[parentEdge.id] = .record(driving)
        }

        _ = try addFamily(
            profiles: [ghost],
            relationships: [parentEdge],
            source: .freebmd,
            edgeExistenceEvidence: edgeExistence
        )

        return ghostID
    }

    /// Slice 11 — spouse edge materialization.
    ///
    /// Given a subject whose father AND mother are both linked in the
    /// tree, and a supported `.parentMarriage` hypothesis matching
    /// their surname pair, create the `spouse` relationship between
    /// the two parent profiles with `marriage_date_original` and
    /// `marriage_location` taken from the cited marriage record(s).
    ///
    /// Idempotent: if a spouse relationship between the two parents
    /// already exists, no-op. Returns the new Relationship's UUID when
    /// a fresh edge was created, nil otherwise.
    ///
    /// Per-spec: the marriage record is one of the cited groom-side /
    /// bride-side BMD entries from `.parentMarriage.supportingEvidence`.
    /// "DEC 1911" / "Belper" come straight from the matched record's
    /// `quarter` + `year` + `district` fields.
    @discardableResult
    func ensureSpouseEdgeForParents(
        ofSubject subjectID: String,
        hypotheses: [ResearchHypothesis],
        scoredRecords: [ScoredRecord],
        snapshot: FamilyGraphSnapshot
    ) throws -> UUID? {
        let parents = snapshot.parentsOf(subjectID)
        guard let father = parents.first(where: { $0.gender == .male }),
              let mother = parents.first(where: { $0.gender == .female })
        else { return nil }

        // Find the supported parentMarriage matching this pair.
        let fatherSurname = (father.lastName ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        let motherSurname = (mother.lastName ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        guard !fatherSurname.isEmpty, !motherSurname.isEmpty else { return nil }

        let marriage = hypotheses.first { h in
            guard h.isDeterministicallySupported,
                  case .parentMarriage(let m, let f, _) = h.kind
            else { return false }
            return m.uppercased() == motherSurname
                && f.uppercased() == fatherSurname
        }
        guard let parentMarriage = marriage else { return nil }

        // Already wired?
        let existingSpouse = snapshot.relationships.first { r in
            r.type == .spouse &&
            ((r.from == father.id && r.to == mother.id) ||
             (r.from == mother.id && r.to == father.id))
        }
        if existingSpouse != nil { return nil }

        // Extract marriage date + location from the first cited record
        // that carries a year and district. The two BMD-side entries
        // (groom + bride) carry identical (year, quarter, district), so
        // first-with-data wins.
        let recordByID = Dictionary(uniqueKeysWithValues: scoredRecords.map { ($0.id, $0) })
        var marriageYear: Int?
        var marriageQuarter: String?
        var marriageDistrict: String?
        // E4 (§Change4): remember the marriage record that drives this spouse
        // edge so its existence can cite it. First cited record carrying a year
        // wins — the same one whose (year, quarter, district) fill the edge.
        var drivingMarriageRecord: ScoredRecord?
        for evidenceID in parentMarriage.supportingEvidence {
            guard let scored = recordByID[evidenceID],
                  case .marriage(let m) = scored.record else { continue }
            if drivingMarriageRecord == nil { drivingMarriageRecord = scored }
            if marriageYear == nil { marriageYear = m.marriageYear }
            if marriageQuarter == nil,
               let q = m.quarter, !q.isEmpty { marriageQuarter = q }
            if marriageDistrict == nil,
               let d = m.district, !d.isEmpty { marriageDistrict = d }
            if marriageYear != nil && marriageQuarter != nil && marriageDistrict != nil {
                break
            }
        }
        guard let year = marriageYear else { return nil }

        // "DEC 1911" / "1911" — match the existing date-string
        // convention used elsewhere in the tree.
        let dateString: String = {
            if let quarter = marriageQuarter, !quarter.isEmpty {
                return "\(quarter.uppercased()) \(year)"
            }
            return "\(year)"
        }()
        let marriageDate = GenealogicalDate(parsing: dateString)

        // Spouse edge convention in this codebase: relationship.from is
        // the husband (father), .to is the wife (mother). Mirrors the
        // existing edges produced by GEDCOM import and WikiTree sync.
        let edge = Relationship(
            id: UUID(),
            from: father.id, to: mother.id,
            type: .spouse, role: nil, subtype: .biological,
            marriageDate: marriageDate,
            marriageLocation: marriageDistrict,
            divorceDate: nil
        )
        // E4 (§Change4): the spouse edge exists because of the parents'
        // marriage record. Cite it. `drivingMarriageRecord` is guaranteed
        // non-nil here — we already proved a marriage year came from it above.
        let existence: RelationshipExistenceEvidence? = drivingMarriageRecord.map { .record($0) }
        _ = try addRelationship(edge, existenceEvidence: existence)
        return edge.id
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

        // E4 (§Change4): both parent edges exist because of the sibling's own
        // birth record — the same record whose mother's-maiden-name matched
        // the known family. Cite it on both edges. If evidence is somehow
        // absent, the edges are created bare rather than fabricating a source.
        var edgeExistence: [UUID: RelationshipExistenceEvidence] = [:]
        if let driving = proposal.evidence.first {
            edgeExistence[fatherEdge.id] = .record(driving)
            edgeExistence[motherEdge.id] = .record(driving)
        }

        _ = try addFamily(
            profiles: [ghost],
            relationships: [fatherEdge, motherEdge],
            source: .freebmd,
            edgeExistenceEvidence: edgeExistence
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
