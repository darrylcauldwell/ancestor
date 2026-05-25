import Foundation

/// Pre-insert dedup for accepted proposals — both sibling
/// (`SiblingProposal`) and parent-inferred (`ProposedRelative`).
/// Mirrors `MCPServer.SiblingDedup.decideDedup` (the `promote_lead`
/// path) so all three accept-flows behave identically per
/// ENGINE_FOUNDATION_SPEC §Change3:
/// surname + given-name + ±2-year window.
///
/// Decision semantics:
/// - `noMatch`  → caller should create a new profile.
/// - `matched`  → caller should link the existing profile to the
///                proposal's parents (idempotently, per
///                `addRelationshipIfAbsent`) instead of creating
///                a new ghost.
/// - `multipleMatches` → fall through to "create new" (CLAUDE.md
///                "When in doubt, split" — the audit's
///                duplicateDetection rule then surfaces all three
///                for the user to resolve manually).
nonisolated enum ProposalDedup {

    /// Normalised identity + birth-window shape that both
    /// `SiblingProposal` and `ProposedRelative` can map onto. The
    /// helper consumes this rather than the proposal types directly
    /// so the dedup logic stays single-source.
    struct Query {
        let surname: String?
        let givenName: String?
        /// Earliest plausible birth year. For `SiblingProposal` this
        /// is the concrete birth year. For `ProposedRelative` this
        /// is `birthYearLow`.
        let birthYearEarliest: Int?
        /// Latest plausible birth year. Mirrors
        /// `birthYearEarliest` for point queries.
        let birthYearLatest: Int?
    }

    enum Decision: Equatable {
        case noMatch
        case matched(profileID: String)
        case multipleMatches
    }

    static func decide(query: Query, candidates: [Profile]) -> Decision {
        let querySurname = normalised(query.surname)
        guard !querySurname.isEmpty else { return .noMatch }

        let queryGiven = normalised(query.givenName)
        let queryHasGiven = !queryGiven.isEmpty

        // Surname is the gate — case-insensitive, trimmed.
        let surnameMatches = candidates.filter { c in
            !c.isDeleted && normalised(c.lastName) == querySurname
        }

        let matched: [String] = surnameMatches.compactMap { c in
            let candGiven = normalised(c.firstName)
            let candHasGiven = !candGiven.isEmpty
            let candEarliest = c.birthDate?.earliest
            let candLatest = c.birthDate?.latest ?? candEarliest

            guard yearWindowsOverlap(
                aEarliest: query.birthYearEarliest, aLatest: query.birthYearLatest,
                bEarliest: candEarliest, bLatest: candLatest
            ) else { return nil }

            if queryHasGiven && candHasGiven {
                // Strict: both have given names → must match exactly.
                return queryGiven == candGiven ? c.id : nil
            }
            // Asymmetric or both-surname-only: surname + year overlap
            // is the whole match signal.
            return c.id
        }

        switch matched.count {
        case 0: return .noMatch
        case 1: return .matched(profileID: matched[0])
        default: return .multipleMatches
        }
    }

    /// True when window [aEarliest…aLatest] (with ±2-year fudge on
    /// the query side) overlaps [bEarliest…bLatest]. If either
    /// window has no year information, returns true — surname is
    /// the only signal and the count gate in `decide` decides what
    /// to do with it.
    static func yearWindowsOverlap(
        aEarliest: Int?, aLatest: Int?,
        bEarliest: Int?, bLatest: Int?
    ) -> Bool {
        let aHasYear = aEarliest != nil || aLatest != nil
        let bHasYear = bEarliest != nil || bLatest != nil
        guard aHasYear, bHasYear else { return true }

        let aE = (aEarliest ?? aLatest!) - 2
        let aL = (aLatest ?? aEarliest!) + 2
        let bE = bEarliest ?? bLatest!
        let bL = bLatest ?? bEarliest!

        return aE <= bL && aL >= bE
    }

    private static func normalised(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }
}

// MARK: - Per-proposal query builders

extension ProposalDedup.Query {
    /// Build a dedup query from a sibling proposal. Birth year is a
    /// point so earliest == latest.
    init(siblingProposal proposal: SiblingProposal) {
        self.surname = proposal.proposedSurname
        self.givenName = proposal.proposedGivenName
        self.birthYearEarliest = proposal.birthYear
        self.birthYearLatest = proposal.birthYear
    }

    /// Build a dedup query from a parent-inferred proposal. Carries
    /// the proposal's full year range (often wider — e.g. 1871–1898).
    init(parentProposal proposal: ProposedRelative) {
        self.surname = proposal.proposedSurname
        self.givenName = proposal.proposedGivenName
        self.birthYearEarliest = proposal.birthYearLow
        self.birthYearLatest = proposal.birthYearHigh
    }
}
