import Foundation

/// Bridges confirmed research-run facts into `pending_facts` so unattended
/// (MCP watcher) runs surface their verdicts for human review — in Triage
/// and via the profile panel's pending-facts badge.
///
/// Why this exists: the UI-initiated research flow reviews confirmed facts
/// live in cluster review (`ResearchViewModel.applyCluster` → ApplyEngine),
/// but that state is session-only. Watcher runs (kicked off over MCP) had
/// NO reviewable surface — evidence and the result envelope persisted, yet
/// a confirmed death landed nowhere a human could approve it. Precedent for
/// routing pipeline write-backs through `pending_facts`:
/// `BirthYearConsensusDetector` and the SubjectSpouseMarriage given-name
/// recovery both do exactly this "so the user reviews them with the same UI".
///
/// Emission rules (deliberately narrow):
///   • only `.fact`-verdict records the UI apply path would write
///     (`RecordScorer.wouldApply`) — sandwich verdicts, never leads;
///   • only fields the profile does NOT already populate — the
///     check-before-overwrite invariant: an unattended run must never queue
///     an overwrite of user-entered data for one-click approval;
///   • birth/death date + location only — the fields
///     `applyAcceptedPendingFact` knows how to write. Marriage facts write
///     to relationship edges and keep their cluster-review path.
///   • one pending fact per (field, value) per run — multiple witnesses of
///     the same value collapse to the first (its citation), so the review
///     queue isn't padded with duplicates.
nonisolated enum ResearchRunFactBridge {

    /// Build the pending facts a completed run should queue for review.
    /// Pure and static — the watcher persists the result.
    static func pendingFacts(
        from confirmedFacts: [ScoredRecord],
        profile: Profile,
        runID: String?,
        submittedAt: Date = Date()
    ) -> [PendingFact] {
        var out: [PendingFact] = []
        var seen = Set<String>()  // "(field)|(value)" in-run dedup

        for scored in confirmedFacts where RecordScorer.wouldApply(scored) {
            switch scored.record {
            case .death(let r):
                if profile.deathDate == nil,
                   let value = bestDate(exact: r.deathDate, year: r.deathYear) {
                    append(field: "deathDate", value: value, scored: scored,
                           profile: profile, runID: runID, submittedAt: submittedAt,
                           into: &out, seen: &seen)
                }
                if isBlank(profile.deathLocation),
                   let place = r.deathPlace, !place.isEmpty {
                    append(field: "deathLocation", value: place, scored: scored,
                           profile: profile, runID: runID, submittedAt: submittedAt,
                           into: &out, seen: &seen)
                }
            case .birth(let r):
                if profile.birthDate == nil,
                   let value = bestDate(exact: r.birthDate, year: r.birthYear) {
                    append(field: "birthDate", value: value, scored: scored,
                           profile: profile, runID: runID, submittedAt: submittedAt,
                           into: &out, seen: &seen)
                }
                if isBlank(profile.birthLocation),
                   let place = r.birthPlace, !place.isEmpty {
                    append(field: "birthLocation", value: place, scored: scored,
                           profile: profile, runID: runID, submittedAt: submittedAt,
                           into: &out, seen: &seen)
                }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func append(
        field: String, value: String, scored: ScoredRecord,
        profile: Profile, runID: String?, submittedAt: Date,
        into out: inout [PendingFact], seen: inout Set<String>
    ) {
        let dedupKey = "\(field)|\(value.uppercased())"
        guard !seen.contains(dedupKey) else { return }
        seen.insert(dedupKey)

        let sourceURL = scored.record.detailURL
            ?? scored.record.rawFields["ark"]
            ?? ""
        let sourceTitle = scored.record.rawFields["collection.title"]
            ?? scored.record.sourceID
        let gateSummary = scored.gates
            .map { "\($0.gate.rawValue): \($0.outcome == .pass ? "pass" : $0.reason)" }
            .joined(separator: "; ")
        let reasoning = [
            "Confirmed by the deterministic research pipeline (4-gate verdict: fact).",
            runID.map { "Run: \($0)" },
            "Gates — \(gateSummary)",
        ].compactMap(\.self).joined(separator: "\n")

        out.append(PendingFact(
            id: EvidenceFirewall.idempotencyKey(
                profileID: profile.id, field: field,
                value: value, sourceURL: sourceURL
            ),
            profileID: profile.id,
            field: field,
            value: value,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            evidenceText: String(scored.summary.prefix(200)),
            reasoning: reasoning,
            confidence: "high",
            agentID: "research-run",
            submittedAt: submittedAt,
            verificationStatus: .pending
        ))
    }

    /// Prefer the record's exact date string; fall back to the bare year.
    private static func bestDate(exact: String?, year: Int?) -> String? {
        if let exact, !exact.trimmingCharacters(in: .whitespaces).isEmpty { return exact }
        if let year { return String(year) }
        return nil
    }

    private static func isBlank(_ s: String?) -> Bool {
        (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
