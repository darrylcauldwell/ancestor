import Foundation
import os

/// Reconstructs a reviewable `ResearchResult` from PERSISTED state — the
/// substrate an overnight watcher campaign (or any past run) leaves in the
/// database — so ClusterReviewView can review it without a
/// live pipeline session (CAMPAIGN_REVIEW_SPEC Change 5).
///
/// Sources of truth (all persisted):
///   evidence_records       → ScoredRecords (full fidelity post-v44: gates,
///                            summary, enrichment flag)
///   research_hypotheses    → proposals/banners
///   research_discrepancies → CL3 "conflicts with tree" badge (latest run)
///   negative_searches ∪ evidence source ids → searched-surface approximation
///   research_run_requests  → campaign windows (incl. failures)
///
/// Reconstruction semantics vs the original run (documented, deliberate):
///   • Clusters are re-derived by the SAME deterministic ClusteringEngine
///     over a canonical input order (source_record_id ascending — load order
///     is scored_at DESC, which is not reproducible). Cluster ids are
///     positional and remain session-scoped — decisions persist on record
///     ids / user_status only.
///   • The evidence set is the profile's cross-run UNION (latest verdict per
///     record), not one run's exact input — review sees everything known.
///   • Enrichment-tagged rows are excluded from clustering exactly as the
///     run excluded them (persisted is_enrichment, Change 2).
///   • User-discarded records stay IN the result (live-run parity — the UI
///     dims them via user_status).
@MainActor
enum CampaignReviewService {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research", category: "CampaignReview")

    // MARK: - Per-profile reconstruction

    /// Rebuild a reviewable result for one profile from the database.
    /// Returns nil when the profile has no persisted evidence at all.
    static func reconstructResult(
        profileID: String,
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot
    ) -> ResearchResult? {
        guard let profile = snapshot.profiles[profileID] else { return nil }
        guard let evidence = try? db.loadEvidenceForProfile(profileID),
              !evidence.isEmpty else { return nil }

        // Canonical order — deterministic across reconstructions.
        let ordered = evidence.sorted { $0.sourceRecordID < $1.sourceRecordID }
        let scored = ordered.map(\.asScoredRecord)
        let enrichmentIDs = Set(ordered.filter(\.isEnrichment).map(\.sourceRecordID))

        // Cluster with the run's exclusion applied (pipeline parity:
        // ResearchPipeline filters enrichment records before clustering).
        let homeChapmanCode = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
        let subject = ResearchSubject.fromProfile(
            profile, snapshot: snapshot, mode: .extend, homeChapmanCode: homeChapmanCode)
        let clusterInput = scored.filter { !enrichmentIDs.contains($0.id) }
        let clusters = ClusteringEngine.cluster(
            records: clusterInput,
            sourceInfoMap: [:],  // unused by cluster() since RESEARCH_CONFIDENCE Change 5
            homeChapmanCode: subject.homeChapmanCode
        )

        let hypotheses = (try? db.loadHypotheses(forProfile: profileID)) ?? []
        let discrepancies = (try? db.latestRunDiscrepancies(profileID: profileID)) ?? []

        // Searched-surface approximation for GPS criterion 1: persisted
        // genuine negatives ∪ sources that returned evidence. (The
        // whole-tree resume sentinel uses its own profileID, so it's
        // excluded by construction.)
        let negativeRows = (try? db.loadNegativeSearches(profileID: profileID)) ?? []
        var searchHistory: [SearchAttempt] = negativeRows.map {
            SearchAttempt(sourceID: $0.sourceID,
                          recordType: RecordType(rawValue: $0.recordType) ?? .birth,
                          searchKey: "(persisted negative)",
                          resultCount: 0, timestamp: $0.date)
        }
        let coveredSources = Set(negativeRows.map(\.sourceID))
        for sourceID in Set(ordered.map(\.sourceID)).subtracting(coveredSources).sorted() {
            searchHistory.append(SearchAttempt(
                sourceID: sourceID, recordType: .birth,
                searchKey: "(reconstructed from evidence)",
                resultCount: 1, timestamp: Date()))
        }

        return ResearchResult(
            confirmedFacts: scored.filter { $0.verdict == .fact },
            leads: scored.filter { $0.verdict == .lead },
            allScoredRecords: scored,
            clusters: clusters,
            discrepancies: discrepancies,
            householdMembers: [],
            searchHistory: searchHistory,
            hypotheses: hypotheses,
            enrichmentRecordIDs: enrichmentIDs
        )
    }

    // MARK: - Convergence badge matching

    /// The strongest PERSISTED convergence level among the fact values this
    /// cluster asserts — the per-finding badge datum (CAMPAIGN_REVIEW_SPEC
    /// Change 6). Matches the cluster's fact-verdict records' value keys
    /// (ConvergenceEngine.valueKey) against the profile's persisted
    /// evidence_convergence rows. nil when the cluster asserts no
    /// fact-verdict value or nothing persisted matches.
    nonisolated static func convergenceLevel(
        for cluster: LifeCluster,
        persisted: [ProjectDatabase.EvidenceConvergenceRow]
    ) -> ConvergenceLevel? {
        let clusterKeys = Set(
            cluster.records
                .filter { $0.verdict == .fact }
                .map { ConvergenceEngine.valueKey(for: $0.record) }
        )
        return persisted
            .filter { clusterKeys.contains($0.valueKey) }
            .map(\.level)
            .max()
    }

    /// The add-to-tree action a lead warrants, or nil for "Research first".
    ///
    /// The distinction is whether the lead ASSERTS A PERSON or merely offers a
    /// record candidate. A lead built from a scored record — "George H LAND,
    /// Dec 1866, Rotherham" — carries no `relationship`: it is one index row
    /// out of a namesake-dense set, and adding it blind is how the removed
    /// Promote button minted fake identity profiles. A lead that names a kin
    /// role is a different claim: somebody enumerated this person standing in
    /// that relation to someone already on the tree. A census household is the
    /// archetype — the enumerator wrote them down, so their existence is not
    /// in question, only their dates and later life.
    ///
    /// The node promoted is a `nameStatus.placeholder` with provenance recorded
    /// as an origin note rather than a fabricated citation, so it is visibly a
    /// research node throughout. That is the safety valve that made "Add as
    /// mother/father" acceptable, and it holds identically here.
    ///
    /// SIBLING has no edge of its own in this model — siblings are implied by
    /// shared parents. #37: when the GENERATOR's parents are already in the
    /// tree there is no guessing left, so a sibling lead becomes "Add as
    /// child of X & Y" and promotes with parent edges to each known parent
    /// (live case 2026-08-24: James + Samuel Wheeldon's sibling leads sat
    /// with no add-path even after Joseph and Alice were promoted, and had
    /// to be resubmitted as child leads). With NO parents known the action
    /// stays absent — the row explains why instead of silently offering
    /// only Research (`siblingExplanation`).
    enum AddAction: Equatable {
        case parent(role: String)   // "mother" / "father"
        case child
        case spouse
        /// #37 — sibling lead whose generator's parents are known: promote
        /// as a child of those parents (ids drive the edges, names the label).
        case childOfParents(parentIDs: [String], parentNames: [String])

        /// Button label — reads from the perspective of the profile the lead
        /// sits under ("Add as child" on the father's row).
        var label: String {
            switch self {
            case .parent(let role): "Add as \(role)"
            case .child: "Add as child"
            case .spouse: "Add as spouse"
            case .childOfParents(_, let names):
                "Add as child of \(names.joined(separator: " & "))"
            }
        }
    }

    /// `generatorParents` — the lead's generating profile's parents, resolved
    /// by the caller from the snapshot. Only sibling leads consume it;
    /// defaulted empty so every existing call site keeps its contract.
    static func addAction(
        for lead: Lead,
        generatorParents: [(id: String, name: String)] = []
    ) -> AddAction? {
        if let role = parentRole(lead) { return .parent(role: role) }
        switch lead.relationship?.lowercased() {
        case "child": return .child
        case "spouse": return .spouse
        case let rel? where isHalfSiblingWord(rel):
            // Review C10 — a half-sibling shares exactly ONE parent and the
            // record does not say which, so "Add as child of X & Y" would
            // assert a biological edge to the wrong parent half the time.
            // Research first (`halfSiblingExplanation` says why).
            return nil
        case let rel? where isSiblingWord(rel):
            guard !generatorParents.isEmpty else { return nil }
            return .childOfParents(
                parentIDs: generatorParents.map(\.id),
                parentNames: generatorParents.map(\.name)
            )
        default: return nil     // no kin claim → Research first
        }
    }

    /// The generator's parents eligible to head an "Add as child of X & Y"
    /// promotion — resolved from the snapshot HERE so every lead surface
    /// applies the same rule. Review C10: `snapshot.parentsOf` returns every
    /// parent edge, but `promoteLeadToProfile(asChildOfParents:)` mints a
    /// BIOLOGICAL edge per parent, so explicitly non-biological parents —
    /// `.step` / `.adoptive` — must not be offered: one click would assert
    /// the sibling as the step-parent's biological child. `.unknown`
    /// subtype stays eligible — it is what GEDCOM (no PEDI tag) and
    /// WikiTree imports stamp on ordinary biological parents, and excluding
    /// it would kill the #37 add-path on every imported tree; the same
    /// presumption `AuditRule.treeChildTally` makes (non-step, non-adoptive
    /// = counts as her child).
    nonisolated static func generatorParents(
        for profileID: String, snapshot: FamilyGraphSnapshot
    ) -> [(id: String, name: String)] {
        snapshot.relationships
            .filter {
                $0.type == .parent && $0.to == profileID
                    && $0.subtype != .step && $0.subtype != .adoptive
            }
            .compactMap { snapshot.profiles[$0.from] }
            .map { p in
                let full = [p.firstName, p.lastName].compactMap { $0 }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return (p.id, full.isEmpty ? p.id : full)
            }
    }

    /// Whether a lead claims siblinghood — the vocabulary the several lead
    /// emitters use. Half-siblings count: they ARE a sibling claim, they
    /// just never qualify for the child-of-both-parents promotion.
    static func isSiblingLead(_ lead: Lead) -> Bool {
        lead.relationship.map {
            let rel = $0.lowercased()
            return isSiblingWord(rel) || isHalfSiblingWord(rel)
        } ?? false
    }

    /// Whether a lead claims HALF-siblinghood specifically — see `addAction`.
    static func isHalfSiblingLead(_ lead: Lead) -> Bool {
        lead.relationship.map { isHalfSiblingWord($0.lowercased()) } ?? false
    }

    private static func isSiblingWord(_ raw: String) -> Bool {
        ["sibling", "brother", "sister"]
            .contains(raw.trimmingCharacters(in: .whitespaces))
    }

    /// Review C10 — half-sibling vocabulary is matched squashed (hyphens and
    /// spaces removed) so every emitter's spelling lands here: the MCP
    /// submit_lead free-text "half-brother"/"half-sister", a census
    /// schedule's "Half Brother", and FindAGrave's camelCase "halfSibling"
    /// (which used to dodge the sibling match entirely).
    private static func isHalfSiblingWord(_ raw: String) -> Bool {
        let squashed = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return ["halfsibling", "halfbrother", "halfsister"].contains(squashed)
    }

    /// #37 — the honest row caption for a sibling lead that CANNOT offer an
    /// add action, so "Research" alone stops reading as a dead end.
    static let siblingExplanation =
        "Siblings are added as children of shared parents — add this person's parents to the tree first, and this lead will offer \"Add as child of…\"."

    /// Review C10 — the half-sibling counterpart: the shared parent is
    /// unknowable from the record, so no add action can ever be offered.
    static let halfSiblingExplanation =
        "A half-sibling shares exactly one parent, and the record doesn't say which — research this person to establish the shared parent before adding."

    /// The Research button's help text for a lead with no add action.
    static func researchExplanation(for lead: Lead) -> String {
        if isHalfSiblingLead(lead) { return halfSiblingExplanation }
        if isSiblingLead(lead) { return siblingExplanation }
        return "Investigate this candidate before deciding."
    }

    /// May a promoted lead ATTACH to this existing profile, or must it create a
    /// new one?
    ///
    /// `ProposalDedup` classes an asymmetric pair — query has a given name, the
    /// candidate does not — as a WEAK match on surname alone, and when no strong
    /// match exists the weak one wins. That is right for enriching a
    /// surname-only placeholder in the same role, and catastrophic otherwise.
    /// Live case, 2026-08-21: promoting the newly-found daughter "Evelyn E
    /// Gould" matched her mother's surname-only SPOUSE placeholder " Gould",
    /// so no profile was created and the husband was recorded as his own wife's
    /// child. The file's own comment says the weak set is for "the pure
    /// surname-only-on-both-sides case"; the code was broader than the intent.
    ///
    /// A candidate that carries a given name matched ON that name — strong, and
    /// genuinely the same person. A NAMELESS candidate carries no identity at
    /// all, so it may only be attached to when it is already related to the
    /// generator in the role this lead claims: that is enrichment of the right
    /// placeholder. Anything else merely shares a surname, and "when in doubt,
    /// split" says make a new node — a spurious duplicate is easy to merge, a
    /// wrong merge is not.
    static func mayAttach(
        lead: Lead, to candidate: Profile, relationships: [Relationship]
    ) -> Bool {
        if !(candidate.firstName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        // Ask the edge builder what edge this promotion WOULD create, then
        // require an equivalent one to exist already. Using the same function
        // keeps the two rules from drifting apart.
        guard let wouldBe = ProjectDatabase.relationshipEdge(
            fromLead: lead, ghostID: candidate.id, generatorID: lead.profileID)
        else { return false }
        return relationships.contains {
            $0.type == wouldBe.type && $0.from == wouldBe.from && $0.to == wouldBe.to
        }
    }

    /// "mother"/"father" for a parent-inference lead, else nil. A parent role
    /// is the only one where a surname alone identifies the person — you have
    /// at most one mother and one father.
    static func parentRole(_ lead: Lead) -> String? {
        switch lead.relationship?.lowercased() {
        case "mother": "mother"
        case "father": "father"
        default: nil
        }
    }

    /// Identity key for collapsing leads into one review row.
    ///
    /// Parent-inference leads key on (profile, role, surname) — one per
    /// surname by nature. Everything else keys on (profile, surname, given,
    /// year), so "Ida L Land 1885" arriving from three records collapses while
    /// a different year stays separate.
    ///
    /// The role branch is gated on PARENT roles specifically. It used to fire
    /// for any non-empty `relationship`, and "one per surname" is true of a
    /// mother but false of a CHILD or a sibling — they share a surname by
    /// definition. Every child-of-X lead therefore collapsed into a single row:
    /// Lilian A Land (b. ~1893) and George W Land (b. ~1898), both children of
    /// George Land in the 1901 Wirksworth census, showed as one row badged
    /// "2 records" with Lilian invisible inside it (owner report 2026-08-21).
    /// Two different people are not one finding.
    static func leadGroupKey(_ lead: Lead) -> String {
        if let role = parentRole(lead) {
            return "rel|\(lead.profileID)|\(role)|\((lead.surname ?? lead.name).uppercased())"
        }
        let surname = (lead.surname ?? "").uppercased()
        let given = (lead.givenName ?? "").uppercased()
        let year = lead.birthYear.map(String.init) ?? lead.deathYear.map(String.init) ?? "?"
        return "id|\(lead.profileID)|\(surname)|\(given)|\(year)"
    }
}
