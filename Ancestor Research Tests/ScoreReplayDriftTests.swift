import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Store-vs-rules drift analysis.
///
/// The Slice 1.5 capture reported 12,875 of 31,481 stored records re-scoring
/// differently than the verdict on disk, 117 of them stored as `fact`. That
/// number on its own is not a finding — it has at least four possible causes
/// with completely different consequences, and this suite separates them:
///
/// 1. **A replay artefact.** The original `searchType` is not persisted, so the
///    replay scores each record under its own type. Where a row was FILED as a
///    different type, that substitution alone can move the verdict, and nothing
///    is wrong with the store.
/// 2. **The subject changed.** A profile edited since it was researched
///    legitimately re-scores. That is the tree improving, not drifting.
/// 3. **The rules changed.** Gates have been repaired repeatedly (the 14 gate
///    repairs of the 2026-07 sandwich audit, the geography and exclusivity work).
///    Rows scored under older rules keep their old verdict until re-researched.
/// 4. **The exclusivity pass.** A stored fact contested by a rival — which is
///    what `ContradictoryFactsAudit` already surfaces, per profile.
///
/// Only (3) and (4) are the user's problem, and only for rows that are APPLIED
/// or awaiting review. This is opt-in and diagnostic: it prints and never fails,
/// because a drift count is not a regression.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SCORE_REPLAY"] == "1"))
@MainActor
struct ScoreReplayDriftTests {

    private func tally<T: Hashable>(_ items: [T]) -> [(T, Int)] {
        Dictionary(grouping: items, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private func line<T>(_ label: String, _ counts: [(T, Int)], limit: Int = 12) -> String {
        let body = counts.prefix(limit).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let rest = counts.count > limit ? " (+\(counts.count - limit) more)" : ""
        return "[drift]   \(label): \(body)\(rest)"
    }

    @Test func analyseDrift() throws {
        guard let projectPath = ProcessInfo.processInfo.environment["SCORE_REPLAY_PROJECT"],
              FileManager.default.fileExists(atPath: projectPath)
        else {
            Issue.record("SCORE_REPLAY_PROJECT must name a project .sqlite")
            return
        }

        let db = try ProjectDatabase(path: projectPath)
        let snapshot = try db.buildSnapshot()
        let all = ScoreReplay.diagnoseAll(in: db, snapshot: snapshot)

        print("[drift] ===== \(all.count) stored records, \(Set(all.map(\.profileID)).count) profiles =====")

        // --- How much of the store can even be compared -------------------
        let withStoredGates = all.filter { !$0.storedGates.isEmpty }
        print("[drift] rows with persisted gates: \(withStoredGates.count) of \(all.count) "
              + "— the rest are pre-v44 and store a verdict but NO gates, so nothing "
              + "may be concluded from comparing their reasons")

        // --- Cause 1: the replay's own searchType assumption ---------------
        let typeMismatch = all.filter { $0.intrinsicType != $0.filedType }
        let typeMismatchChangesVerdict = typeMismatch.filter {
            $0.filedTypeVerdict != $0.preExclusivityVerdict
        }
        print("[drift] filed type ≠ intrinsic type on \(typeMismatch.count) rows; of those, "
              + "\(typeMismatchChangesVerdict.count) score differently under the filed type "
              + "— that many of the drift figure are a REPLAY ARTEFACT, not a store problem")
        if !typeMismatch.isEmpty {
            print(line("mismatched types", tally(typeMismatch.map { "\($0.filedType)→\($0.intrinsicType)" })))
        }

        // --- Cause 1b: rows scored against a subject we cannot rebuild -----
        let artefacts = all.filter { $0.drifted && $0.scoredAgainstUnreconstructableSubject }
        print("[drift] scored against a child-gap probe subject (givenName nil, no birth "
              + "window, deaths only — ResearchPipeline.swift:817-823): \(artefacts.count) "
              + "drifted rows EXCLUDED. The replay rebuilds one subject per profile and "
              + "cannot reconstruct a probe subject, so these compare different inputs.")
        print(line("excluded by profile", tally(artefacts.map(\.profileID)), limit: 8))

        // --- The transition matrix ----------------------------------------
        let drifted = all.filter(\.driftedMeaningfully)
        print("[drift] drifted MEANINGFULLY: \(drifted.count) of \(all.count) "
              + "(\(drifted.count * 100 / max(all.count, 1))%) — "
              + "raw figure before exclusions was \(all.filter(\.drifted).count)")
        print(line("transitions", tally(all.map { "\($0.storedVerdict.rawValue)→\($0.finalVerdict.rawValue)" })))
        print(line("drifted by source", tally(drifted.map(\.sourceID))))
        print(line("drifted by type", tally(drifted.map { "\($0.intrinsicType)" })))
        print(line("drifted by user_status", tally(drifted.map { $0.userStatus.rawValue })))
        print("[drift]   drifted rows that are APPLIED: \(drifted.filter { $0.appliedAt != nil }.count)")
        print(line("drifted by scored year", tally(drifted.map {
            Calendar.current.component(.year, from: $0.scoredAt) * 100
                + Calendar.current.component(.month, from: $0.scoredAt)
        })))

        // --- The direction that matters: stored fact, no longer a fact -----
        let lostFacts = all.filter { $0.storedVerdict == .fact && $0.finalVerdict != .fact }
        print("[drift] ===== \(lostFacts.count) stored FACTS that no longer score fact =====")
        let byExclusivity = lostFacts.filter(\.demotedByExclusivity)
        print("[drift]   demoted by the EXCLUSIVITY pass: \(byExclusivity.count) "
              + "— ContradictoryFactsAudit already surfaces these per profile")
        print("[drift]   rejected by a per-record GATE: \(lostFacts.count - byExclusivity.count) "
              + "— nothing surfaces these today")
        print(line("blocking gate", tally(lostFacts.compactMap {
            $0.blockingGate.map { "\($0.gate.rawValue)/\($0.outcome.rawValue)" }
        })))
        print(line("blocking reason", tally(lostFacts.compactMap { $0.blockingGate?.reason }), limit: 20))
        print(line("by source", tally(lostFacts.map(\.sourceID))))
        print(line("by type", tally(lostFacts.map { "\($0.intrinsicType)" })))
        print(line("by user_status", tally(lostFacts.map { $0.userStatus.rawValue })))
        print("[drift]   of these, APPLIED to the tree: \(lostFacts.filter { $0.appliedAt != nil }.count)")
        print("[drift]   of these, enrichment rows: \(lostFacts.filter(\.isEnrichment).count)")
        print(line("by scored month", tally(lostFacts.map {
            Calendar.current.component(.year, from: $0.scoredAt) * 100
                + Calendar.current.component(.month, from: $0.scoredAt)
        })))

        // The applied ones are the only ones already ON the tree — they matter
        // most and are few enough to name.
        let applied = lostFacts.filter { $0.appliedAt != nil }
        if !applied.isEmpty {
            print("[drift] ===== APPLIED records that no longer score fact =====")
            for d in applied.prefix(60) {
                let who = snapshot.profiles[d.profileID].map { "\($0.firstName) \($0.lastName)" }
                    ?? d.profileID
                print("[drift]   \(who) [\(d.profileID)] \(d.sourceID)/\(d.recordID) "
                      + "\(d.intrinsicType) — now \(d.finalVerdict.rawValue) via "
                      + "\(d.blockingGate.map { "\($0.gate.rawValue)/\($0.outcome.rawValue): \($0.reason)" } ?? "no blocking gate")")
            }
        }

        // Specimens for the non-applied majority, grouped so one cause does not
        // fill the list.
        print("[drift] ===== specimens, one per distinct blocking reason =====")
        var seenReason = Set<String>()
        for d in lostFacts {
            let reason = d.blockingGate?.reason ?? "«none»"
            guard seenReason.insert(reason).inserted else { continue }
            let who = snapshot.profiles[d.profileID].map { "\($0.firstName) \($0.lastName)" }
                ?? d.profileID
            print("[drift]   \(who) \(d.sourceID)/\(d.recordID) \(d.intrinsicType) "
                  + "stored=\(d.storedVerdict.rawValue) now=\(d.finalVerdict.rawValue) "
                  + "storedGates=\(d.storedGates.isEmpty ? "«none, pre-v44»" : d.storedGates.map { "\($0.gate.rawValue)/\($0.outcome.rawValue)" }.joined(separator: ",")) "
                  + "→ \(reason)")
        }

        // --- The other direction, for completeness ------------------------
        let gainedFacts = all.filter { $0.storedVerdict != .fact && $0.finalVerdict == .fact }
        print("[drift] ===== \(gainedFacts.count) stored non-facts that NOW score fact =====")
        print(line("by source", tally(gainedFacts.map(\.sourceID))))
        print(line("by type", tally(gainedFacts.map { "\($0.intrinsicType)" })))
        print(line("from verdict", tally(gainedFacts.map { $0.storedVerdict.rawValue })))
        print("[drift]   of these, user-DISCARDED: \(gainedFacts.filter { $0.userStatus == .discarded }.count)")

        // --- Full per-record dumps, for investigation ----------------------
        // The console truncates and groups; these are the raw rows.
        func dump(_ name: String, _ rows: [ScoreReplay.Detail]) {
            let header = "profile\tprofileName\trecord\tsource\ttype\tstored\tpre\tfinal\t"
                + "userStatus\tapplied\tscoredAt\tstoredGates\tfinalGates\n"
            let body = rows.map { d -> String in
                let who = snapshot.profiles[d.profileID]
                    .map { "\($0.firstName ?? "") \($0.lastName ?? "")" } ?? ""
                func gates(_ g: [GateResult]) -> String {
                    g.isEmpty ? "«none»"
                        : g.map { "\($0.gate.rawValue)/\($0.outcome.rawValue)/\($0.reason)" }
                            .joined(separator: " ¦ ")
                }
                return [d.profileID, who, d.recordID, d.sourceID, "\(d.intrinsicType)",
                        d.storedVerdict.rawValue, d.preExclusivityVerdict.rawValue,
                        d.finalVerdict.rawValue, d.userStatus.rawValue,
                        d.appliedAt == nil ? "no" : "YES",
                        ISO8601DateFormatter().string(from: d.scoredAt),
                        gates(d.storedGates), gates(d.finalGates)]
                    .joined(separator: "\t")
            }.joined(separator: "\n")
            let path = NSTemporaryDirectory() + "drift-\(name).tsv"
            try? (header + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("[drift] wrote \(rows.count) rows to \(path)")
        }

        dump("lost-facts", lostFacts)
        dump("gained-facts", gainedFacts)
        dump("lead-to-impossible",
             all.filter { $0.storedVerdict == .lead && $0.finalVerdict == .impossible })
        dump("impossible-to-lead",
             all.filter { $0.storedVerdict == .impossible && $0.finalVerdict == .lead })
        dump("applied-drift", all.filter { $0.drifted && $0.appliedAt != nil })

        // The lead→impossible mass is 97% of the drift figure; its shape is the
        // single most important thing to characterise.
        let leadToImpossible = all.filter {
            $0.storedVerdict == .lead && $0.finalVerdict == .impossible
        }
        print("[drift] ===== \(leadToImpossible.count) stored leads that are now IMPOSSIBLE =====")
        print(line("blocking gate", tally(leadToImpossible.compactMap {
            $0.blockingGate.map { "\($0.gate.rawValue)/\($0.outcome.rawValue)" }
        })))
        print(line("by source", tally(leadToImpossible.map(\.sourceID))))
        print(line("by type", tally(leadToImpossible.map { "\($0.intrinsicType)" })))
        print(line("reason shape", tally(leadToImpossible.compactMap {
            // Collapse the numbers out so the SHAPES group.
            $0.blockingGate?.reason
                .replacingOccurrences(of: "[0-9]+", with: "N", options: .regularExpression)
        }), limit: 25))
        print(line("by profile", tally(leadToImpossible.map { d in
            snapshot.profiles[d.profileID].map { "\($0.firstName ?? "") \($0.lastName ?? "")" }
                ?? d.profileID
        }), limit: 20))

        print("[drift] ===== the \(gainedFacts.count) stored non-facts that now score FACT =====")
        for d in gainedFacts.prefix(90) {
            let who = snapshot.profiles[d.profileID]
                .map { "\($0.firstName ?? "") \($0.lastName ?? "")" } ?? d.profileID
            print("[drift]   \(who) \(d.sourceID)/\(d.recordID) \(d.intrinsicType) "
                  + "stored=\(d.storedVerdict.rawValue) status=\(d.userStatus.rawValue) "
                  + "applied=\(d.appliedAt == nil ? "no" : "YES")")
        }

        #expect(!all.isEmpty)
    }
}
