import Foundation

/// Faithful port of `agent/pipeline.py`'s `_emit_*_verdict` helpers
/// (SWIFT_MCP_EVAL_BACKEND_SPEC #Change2). Each returns one of
/// `"supported" | "contradicted" | "inconclusive"` — the exact string
/// shape consumed by the §5.8 eval-harness envelope.
///
/// Free functions in Python; static methods on a namespacing enum in
/// Swift. State / corpus parameters are replaced by the Swift-native
/// equivalents: `ResearchResult` for confirmed facts + household
/// members + clusters, `FamilyGraphSnapshot` for parent / spouse
/// edges (the role `LocalTwin` plays on the Python side).
nonisolated enum VerdictEmitter {

    static let supported = "supported"
    static let inconclusive = "inconclusive"
    static let contradicted = "contradicted"

    /// Port of `_emit_parent_link_verdict`. Conservative — `.supported`
    /// when at least one parent's surname (from the family graph)
    /// appears in any household-member name token. Identical
    /// tokenisation to Python: uppercase, split on whitespace,
    /// case-insensitive set intersection.
    ///
    /// Token source widening (parity fix, 2026-05-24): Python's
    /// `_extract_household_members` runs on **raw** search results,
    /// before the scorer. Swift's pipeline-level extraction filters
    /// to `.fact` only — so census records demoted to leads (e.g.
    /// Ernest's 1891 Belper census, demoted for unknown district
    /// "Duffield") never contribute their household tokens.
    /// Verdict-only widening: walk every `.census` record in
    /// `allScoredRecords` (facts AND leads) for token collection.
    /// State.householdMembers (which feeds the UI's proposed-relatives
    /// surface) keeps the stricter `.fact`-only filter — adding lead
    /// households there would surface weaker evidence as relative
    /// proposals.
    ///
    /// Python tier-3 ("subject's own surname as fallback") was
    /// removed there for the same reason it'd misfire here — the
    /// member-token set aggregates across census searches and is
    /// not per-household scoped, so a shared surname is not by itself
    /// parent-link evidence.
    static func parentLinkVerdict(
        result: ResearchResult,
        snapshot: FamilyGraphSnapshot,
        subjectProfileID: String?
    ) -> String {
        guard let pid = subjectProfileID else { return inconclusive }

        var memberTokens = Set<String>()
        // Tier 1: members the pipeline curated into result.householdMembers
        // (from .fact-grade census records).
        for m in result.householdMembers {
            memberTokens.formUnion(
                m.name.uppercased().split(separator: " ").map(String.init)
            )
        }
        // Tier 2: members carried on every other census record's
        // household payload (leads too) — verdict-only signal.
        for scored in result.allScoredRecords {
            if case .census(let census) = scored.record,
               let household = census.household {
                for member in household {
                    memberTokens.formUnion(
                        member.name.uppercased().split(separator: " ").map(String.init)
                    )
                }
            }
        }
        if memberTokens.isEmpty { return inconclusive }

        let parents = snapshot.parentsOf(pid)
        if parents.isEmpty { return inconclusive }
        let parentSurnames: Set<String> = Set(
            parents.compactMap { $0.lastName?.uppercased() }
                .filter { !$0.isEmpty }
        )
        if parentSurnames.isEmpty { return inconclusive }

        return parentSurnames.intersection(memberTokens).isEmpty
            ? inconclusive
            : supported
    }

    /// Port of `_emit_identity_verdict`. The Python signal is the
    /// corpus-match score (`>= 0.9`) — i.e., the harness's input
    /// matched a known corpus entry. The Swift harness identifies
    /// the subject by profile-id so the matching question doesn't
    /// arise; the native analog is the clustering engine's verdict.
    /// At least one `.confirmed`-match-quality cluster means the
    /// engine positively confirmed candidate-life evidence for the
    /// subject. No confirmed cluster → inconclusive.
    static func identityVerdict(result: ResearchResult) -> String {
        let confirmed = result.clusters.contains { $0.matchQuality == .confirmed }
        return confirmed ? supported : inconclusive
    }

    /// Port of `_emit_spouse_verdict`. Three signals, any sufficient:
    ///   1. A confirmed marriage fact whose record carries a spouse
    ///      name (the post-Sep-1912 FreeBMD spouse_or_mother field).
    ///   2. A household member whose relationship is Wife / Husband
    ///      / Spouse (census co-residence).
    ///   3. The tree records at least one spouse-edge for the
    ///      subject — the Swift analog of LocalTwin's spouse lookup.
    static func spouseVerdict(
        result: ResearchResult,
        snapshot: FamilyGraphSnapshot,
        subjectProfileID: String?
    ) -> String {
        for fact in result.confirmedFacts {
            guard case .marriage(let m) = fact.record else { continue }
            if let s = m.spouseName,
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return supported
            }
        }

        let spouseRels: Set<String> = ["wife", "husband", "spouse"]
        for m in result.householdMembers
        where spouseRels.contains(m.relationship.lowercased()) {
            return supported
        }

        if let pid = subjectProfileID, !snapshot.spousesOf(pid).isEmpty {
            return supported
        }

        return inconclusive
    }
}
