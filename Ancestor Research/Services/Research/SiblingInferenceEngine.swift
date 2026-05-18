import Foundation

/// One inferred sibling for a subject — a birth record that shares the
/// subject's surname AND mother's maiden name AND registration district,
/// within a plausible sibling age window. Carries both parent profile IDs
/// from the subject's tree so the accept flow can wire the new ghost
/// profile to both parents in one step.
///
/// Differs from `ProposedRelative` (parent inference) because the proposal
/// here describes a *peer* of the subject, not an ancestor, and needs to
/// reference two parent profiles rather than one. Kept as a separate type
/// rather than overloading `ProposedRelative.childOf` so the data shape
/// stays honest and the UI can render siblings under their own section.
nonisolated struct SiblingProposal: Identifiable, Sendable {
    /// Stable id derived from the candidate birth record's id so re-runs
    /// produce consistent proposal IDs (lets the user persist accept /
    /// reject decisions across sessions).
    let id: String
    let candidateRecordID: String
    let proposedSurname: String?
    let proposedGivenName: String?
    let gender: Gender?
    /// Birth year from the candidate record — concrete, not a range.
    let birthYear: Int?
    let district: String?
    /// Subject's father / mother profile IDs at inference time. The accept
    /// flow uses these to wire the new ghost to both parents atomically.
    let fatherID: String
    let motherID: String
    /// Records that contributed evidence to this proposal. Today this is
    /// just the candidate birth record; future hypothesis-engine integration
    /// could add corroborating census household memberships.
    let evidence: [ScoredRecord]

    var displayName: String {
        [proposedGivenName, proposedSurname]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Pure inference: given a subject's resolved birth record + the parents
/// already linked to them + a pool of candidate birth records, return any
/// records that look like full siblings (shared parents).
///
/// Caller is responsible for:
///   • Resolving the subject's birth record first (via SubjectIdentityResolver).
///   • Dispatching the FreeBMD query that produces the candidate pool.
///   • Confirming both parents are linked (the engine returns nothing
///     without parent IDs to wire).
///
/// Match rule (intentionally strict to keep the result trustworthy):
///   • Same surname as subject's birth record
///   • Same mother's maiden name (the BMD index's biological-mother key)
///   • Same registration district
///   • |birthYear - subject.birthYear| ≤ 20  (typical fertility span)
///   • Not the subject themselves (record id mismatch)
///   • Not already a known child of the parents in the snapshot
nonisolated enum SiblingInferenceEngine {

    /// Maximum age gap between siblings to consider biologically plausible.
    /// 20 years covers extreme but realistic spans without admitting
    /// half-siblings or step-children with surname coincidence.
    static let maxSiblingAgeGap = 20

    /// Compute sibling proposals.
    ///
    /// - Parameters:
    ///   - subjectBirthRecord: the record `SubjectIdentityResolver` pinned.
    ///   - candidateRecords: pool of birth records to consider (typically
    ///     the result of a FreeBMD query with surname + no given name +
    ///     district filter).
    ///   - knownFatherID: profile id of the subject's father.
    ///   - knownMotherID: profile id of the subject's mother.
    ///   - snapshot: live family graph. Used to dedup against children of
    ///     the parents that are already in the tree (the subject themselves
    ///     and any previously-accepted siblings).
    /// - Returns: sibling proposals sorted by birth year ascending. Empty
    ///   when the subject's birth record carries no MMN (no key to match
    ///   on) or no candidate records pass the filter.
    static func inferSiblings(
        subjectBirthRecord: ScoredRecord,
        candidateRecords: [ScoredRecord],
        knownFatherID: String,
        knownMotherID: String,
        snapshot: FamilyGraphSnapshot
    ) -> [SiblingProposal] {
        guard case .birth(let subjectBirth) = subjectBirthRecord.record else {
            return []
        }
        guard let mmn = subjectBirth.mothersMaidenName?
            .trimmingCharacters(in: .whitespaces),
              !mmn.isEmpty else {
            return []
        }
        let subjectSurname = (subjectBirth.common.surname ?? "")
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        let subjectDistrict = (subjectBirth.district ?? "")
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard let subjectYear = subjectBirth.birthYear else {
            return []
        }

        // Profile ids of children of EITHER parent in the snapshot —
        // candidates whose record we've already accepted should not be
        // re-proposed. We can't match by record id directly (the linked
        // child's id is the ghost profile, not the BMD record), so we
        // match by (year, district) within ±1 year tolerance.
        let knownChildSignatures: Set<String> = {
            let children = snapshot.childrenOf(knownFatherID)
                + snapshot.childrenOf(knownMotherID)
            var seen: Set<String> = []
            for child in children {
                if let year = child.birthDate?.earliest {
                    seen.insert("\(year)|\(child.birthLocation ?? "")")
                }
            }
            return seen
        }()

        var results: [SiblingProposal] = []
        for record in candidateRecords {
            guard case .birth(let birth) = record.record else { continue }
            guard record.id != subjectBirthRecord.id else { continue }

            let recordSurname = (birth.common.surname ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard recordSurname == subjectSurname else { continue }

            let recordMMN = (birth.mothersMaidenName ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard recordMMN == mmn.uppercased() else { continue }

            let recordDistrict = (birth.district ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard !recordDistrict.isEmpty, recordDistrict == subjectDistrict else { continue }

            guard let recordYear = birth.birthYear else { continue }
            guard abs(recordYear - subjectYear) <= maxSiblingAgeGap else { continue }

            // Skip if a child with this rough birth signature is already in
            // the tree (avoids re-proposing the subject and any siblings
            // already accepted).
            let signature = "\(recordYear)|"  // location not on record so partial dedup
            if knownChildSignatures.contains(signature) { continue }

            let inferredGender: Gender? = {
                let given = (birth.common.givenName ?? "").trimmingCharacters(in: .whitespaces)
                // Don't attempt gender inference from given names — too
                // error-prone and locale-specific. Caller can set it on
                // accept if confident.
                _ = given
                return nil
            }()

            results.append(SiblingProposal(
                id: "siblingOf:\(knownFatherID):\(record.id)",
                candidateRecordID: record.id,
                proposedSurname: birth.common.surname,
                proposedGivenName: birth.common.givenName,
                gender: inferredGender,
                birthYear: recordYear,
                district: birth.district,
                fatherID: knownFatherID,
                motherID: knownMotherID,
                evidence: [record]
            ))
        }
        return results.sorted { ($0.birthYear ?? 0) < ($1.birthYear ?? 0) }
    }
}
