import Foundation
import AncestorKit

/// `.parentIdentityCandidate` ⟨G10⟩ — engine-origin identity candidates
/// seeded from F4a parentRole disputes (CONFLICT_LAYER_SPEC CL6).
///
/// Seeding happens at dispute-production time (ConflictSweep), not in the
/// pipeline generator — disputes live in the store, not the snapshot. The
/// candidate set always includes the tree's incumbent edge as a candidate
/// with its own provenance ⟨G11⟩: the tree is a witness too, never a
/// silent home-field advantage.
///
/// Grading enforces the no-self-confirmation rule the user-seeded kind
/// established (`HypothesisEngine+ParentCandidates`): `.supported`
/// requires linkage back to the subject — a child's birth record whose
/// mother's-maiden-name matches the candidate, or household co-presence.
/// A bare same-name index row stays `.inconclusive`.
nonisolated extension HypothesisEngine {

    static func parentIdentityGroupID(profileID: String, role: String) -> String {
        "parentIdentity:\(profileID):\(role)"
    }

    /// Build the candidate set for one F4a conflict: the incumbent (tree
    /// edge, with its provenance named in the reasoning) plus each
    /// record-derived rival from the dispute's competing sources.
    static func seedParentIdentityCandidates(
        profileID: String,
        role: String,
        candidateNames: [(name: String, provenance: String)]
    ) -> [ResearchHypothesis] {
        let now = Date()
        let groupID = parentIdentityGroupID(profileID: profileID, role: role)
        return candidateNames.map { candidate in
            let kind = HypothesisKind.parentIdentityCandidate(
                profileID: profileID, role: role, candidateName: candidate.name)
            var hypothesis = ResearchHypothesis(
                id: kind.identityKey(subjectProfileID: profileID),
                subjectProfileID: profileID,
                kind: kind,
                origin: .engine,
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Candidate \(role) '\(candidate.name)' (\(candidate.provenance)). Pending linkage evidence.",
                createdAt: now,
                lastTestedAt: now,
                attempts: 0,
                history: []
            )
            hypothesis.candidateGroupID = groupID
            return hypothesis
        }
    }

    /// AC2 — supported requires LINKAGE BACK TO THE SUBJECT: a fact-grade
    /// birth record for the subject whose mother's-maiden-name matches the
    /// candidate's surname (mother role), or a census household containing
    /// the candidate's given name alongside the subject. A bare index row
    /// naming the candidate elsewhere never supports (no self-confirmation).
    static func gradeParentIdentityCandidate(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .parentIdentityCandidate(_, let role, let candidateName) = hypothesis.kind else {
            return GradeResult(
                verdict: .inconclusive, isModelAssisted: false,
                supportingEvidence: [], contradictingEvidence: [],
                reasoning: "Malformed parent-identity candidate.")
        }
        let candidateSurname = candidateName
            .split(separator: " ").last.map(String.init)?.uppercased() ?? candidateName.uppercased()
        let candidateGiven = candidateName
            .split(separator: " ").first.map(String.init)?.uppercased()

        // Linkage 1 — subject's birth-shaped record carries the candidate's
        // surname as mother's maiden name (mother role only).
        if role == "mother" {
            let mmnLink = state.scoredRecords.first { scored in
                guard scored.verdict == .fact,
                      case .birth(let r) = scored.record,
                      let mmn = r.mothersMaidenName, !mmn.isEmpty else { return false }
                return mmn.uppercased() == candidateSurname
            }
            if let link = mmnLink {
                return GradeResult(
                    verdict: .supported, isModelAssisted: false,
                    supportingEvidence: ["birth record MMN \(candidateSurname) [\(link.id)]"],
                    contradictingEvidence: [],
                    reasoning: "Linkage back to subject: birth record's mother's-maiden-name matches candidate surname \(candidateSurname).")
            }
        }

        // Linkage 2 — census household co-presence: a fact-grade census
        // record for the subject whose household lists the candidate's
        // given name in a parent relation.
        if let given = candidateGiven {
            let householdLink = state.scoredRecords.first { scored in
                guard scored.verdict == .fact,
                      case .census(let r) = scored.record,
                      let household = r.household else { return false }
                return household.contains { member in
                    let rel = member.relationship.lowercased()
                    let isParentRelation = rel.contains("head") || rel.contains("wife")
                        || rel.contains("father") || rel.contains("mother")
                    return isParentRelation
                        && member.name.uppercased().contains(given)
                }
            }
            if let link = householdLink {
                return GradeResult(
                    verdict: .supported, isModelAssisted: false,
                    supportingEvidence: ["household co-presence [\(link.id)]"],
                    contradictingEvidence: [],
                    reasoning: "Linkage back to subject: census household lists '\(candidateName)' in a parent relation alongside the subject.")
            }
        }

        return GradeResult(
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "No linkage back to the subject yet — a bare index row naming '\(candidateName)' elsewhere is not evidence this person is the subject's \(role) (no self-confirmation).")
    }
}
