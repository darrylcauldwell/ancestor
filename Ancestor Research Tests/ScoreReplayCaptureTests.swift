import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Subject place model Slice 1.5 — the driver that runs the replay against
/// a REAL project.
///
/// The spec's open question was "fixture corpus or the live project?" — the
/// answer is both, for different jobs. `ScoreReplayTests` proves the harness is
/// trustworthy, repeatably, on every run. This suite is the one that produces
/// evidence about an actual change, and it is opt-in because it needs a project
/// file and takes as long as the tree is large.
///
/// Every variable takes the `TEST_RUNNER_` prefix — `xcodebuild` does not pass
/// the caller's environment to the test process, it forwards only that
/// namespace, stripping the prefix on the way in. Without it the suite silently
/// skips, which looks exactly like a pass.
///
/// ```
/// # before the change — takes ~2½ min on a 30k-record store
/// TEST_RUNNER_RUN_SCORE_REPLAY=1 \
///   TEST_RUNNER_SCORE_REPLAY_PROJECT=/path/to/copy-of-project.sqlite \
///   TEST_RUNNER_SCORE_REPLAY_OUT=before.txt \
///   xcodebuild test -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" \
///     -destination "platform=macOS" -skipMacroValidation \
///     -only-testing:"Ancestor Research Tests/ScoreReplayCaptureTests"
///
/// # after the change — same command, plus a baseline to judge against
/// … TEST_RUNNER_SCORE_REPLAY_BASELINE=before.txt TEST_RUNNER_SCORE_REPLAY_OUT=after.txt …
/// ```
///
/// **Point it at a COPY of the project.** `ProjectDatabase.init` runs migrations,
/// which is a write, so opening the live file is not the read-only act the rest
/// of this harness is careful to be. The replay itself never writes — that is
/// pinned by `replayingDoesNotTouchTheStore` — but the open is not free.
///
/// Capture names are resolved inside the test host's sandbox container temp
/// directory, so a bare `before.txt` works and an absolute `/tmp/...` path will
/// be refused by the sandbox. The resolved path is printed.
///
/// With `SCORE_REPLAY_BASELINE` set the suite stops being a dump and becomes a
/// gate: it FAILS on any narrowing — a record that was a fact before and is not
/// one now — because that is invariant (a), the demotion that surfaces days
/// later in a Health audit on a record the user already applied. Other changes
/// are reported but do not fail; a widening is often the intended outcome and
/// wants a human read, not a red build.
///
/// The replay opens the project read-only in the sense that matters: it loads,
/// re-scores in memory, and returns. `replayingDoesNotTouchTheStore` pins that.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SCORE_REPLAY"] == "1"))
@MainActor
struct ScoreReplayCaptureTests {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The test host runs inside the app's sandbox, so it cannot write to
    /// `/tmp` or anywhere else of the caller's choosing — a bare name is
    /// therefore resolved inside the container's own temp directory, which is
    /// where captures actually live. An absolute path is honoured as given; if
    /// the sandbox refuses it, the error says so plainly rather than silently
    /// relocating the file.
    private func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : NSTemporaryDirectory() + path
    }

    @Test func captureAndCompare() throws {
        guard let projectPath = env["SCORE_REPLAY_PROJECT"] else {
            Issue.record("SCORE_REPLAY_PROJECT must name a project .sqlite")
            return
        }
        guard FileManager.default.fileExists(atPath: projectPath) else {
            Issue.record("no project at SCORE_REPLAY_PROJECT")
            return
        }

        let db = try ProjectDatabase(path: projectPath)
        let snapshot = try db.buildSnapshot()
        // Optional single-profile scope. A whole-corpus replay is ~2½ minutes,
        // which is too slow for the "I edited the tree — did that fix it?"
        // loop; scoped to one profile it is seconds. Diffing a scoped capture
        // against a whole-corpus baseline would report every other profile as
        // disappeared, so a scope forbids a baseline.
        let onlyProfile = env["SCORE_REPLAY_PROFILE"]
        let rows: [ScoreReplay.Row]
        if let onlyProfile {
            #expect(env["SCORE_REPLAY_BASELINE"] == nil,
                    "a scoped replay cannot be diffed against a whole-corpus baseline")
            print("[replay] scoped to profile \(onlyProfile)")
            rows = ScoreReplay.replay(profileID: onlyProfile, in: db, snapshot: snapshot)
            for row in rows where row.verdict == "fact" || row.gates.contains(where: {
                $0.hasPrefix("name:fail") || $0.hasPrefix("exclusivity:")
            }) {
                print("[replay]   \(row.verdict)\t\(row.recordID)\n[replay]     \(row.gates.joined(separator: "\n[replay]     "))")
            }
        } else {
            rows = ScoreReplay.replayAll(in: db, snapshot: snapshot)
        }

        let profilesWithEvidence = Set(rows.map(\.profileID)).count
        let facts = rows.filter { $0.verdict == "fact" }.count
        print("""
            [replay] \(rows.count) records across \(profilesWithEvidence) profiles \
            (of \(snapshot.profiles.count) in the tree) — \(facts) fact, \
            \(rows.count - facts) not
            """)

        // How far the STORE has drifted from what the rules decide now. Not a
        // pass/fail — a profile edited since it was researched will legitimately
        // re-score differently, and `ContradictoryFactsAudit` is what surfaces
        // that to the user. It is printed because a large number here is worth
        // knowing before reading a diff, and it is the same figure the Health
        // audit reports profile by profile.
        var storedVerdict: [String: RecordVerdict] = [:]
        for profileID in Set(rows.map(\.profileID)) {
            for row in (try? db.loadEvidenceForProfile(profileID)) ?? [] {
                storedVerdict["\(profileID)\u{1}\(row.sourceRecordID)"] = row.verdict
            }
        }
        let drifted = rows.filter {
            storedVerdict["\($0.profileID)\u{1}\($0.recordID)"]?.rawValue != $0.verdict
        }
        let storedFactsNowNot = drifted.filter {
            storedVerdict["\($0.profileID)\u{1}\($0.recordID)"] == .fact
        }.count
        // Rows scored against a child-gap probe subject are excluded — the
        // replay cannot rebuild that subject, so their "drift" is a comparison
        // artefact, not a statement about the store. See
        // `ScoreReplay.Detail.scoredAgainstUnreconstructableSubject`.
        // Skipped when scoped: `diagnoseAll` would sweep the whole corpus,
        // costing the speed the scope exists for, and its totals would not
        // line up with a one-profile `rows`.
        if onlyProfile == nil {
            let details = ScoreReplay.diagnoseAll(in: db, snapshot: snapshot)
            let artefacts = details.filter { $0.drifted && $0.scoredAgainstUnreconstructableSubject }
            let meaningful = details.filter(\.driftedMeaningfully)
            print("[replay] store-vs-rules drift: \(meaningful.count) records re-score differently "
                  + "than stored (\(storedFactsNowNot) of them stored as fact); "
                  + "\(artefacts.count) further rows differ only because they were scored against a "
                  + "child-gap probe subject the replay cannot rebuild — excluded, not drift")
            #expect(drifted.count == meaningful.count + artefacts.count,
                    "every drifted row is either meaningful or an excluded artefact")
        } else {
            print("[replay] \(drifted.count) of \(rows.count) rows differ from the stored "
                  + "verdict (\(storedFactsNowNot) stored as fact)")
        }

        #expect(!rows.isEmpty, "a project with no stored evidence proves nothing")

        let out = resolve(env["SCORE_REPLAY_OUT"] ?? "score-replay.txt")
        try ScoreReplay.report(rows).write(toFile: out, atomically: true, encoding: .utf8)
        print("[replay] capture written to \(out)")

        guard let baselineName = env["SCORE_REPLAY_BASELINE"] else {
            print("[replay] no SCORE_REPLAY_BASELINE — captured only, nothing compared")
            return
        }
        let baselinePath = resolve(baselineName)
        let baseline = ScoreReplay.parse(
            try String(contentsOfFile: baselinePath, encoding: .utf8))
        #expect(!baseline.isEmpty, "the baseline capture is empty — nothing to compare against")

        let changes = ScoreReplay.diff(before: baseline, after: rows)
        guard !changes.isEmpty else {
            print("[replay] no change — the decision core reached the same verdicts, "
                  + "by the same reasons, on all \(rows.count) records")
            return
        }

        let counts = Dictionary(grouping: changes, by: \.kind)
            .map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ")
        print("[replay] \(changes.count) changed: \(counts)")
        for change in changes.prefix(200) { print(change.description) }
        if changes.count > 200 { print("[replay] …\(changes.count - 200) more not printed") }

        // The gate. Everything else is reported for a human to read; a
        // narrowing is the one that must stop a ship.
        let narrowings = ScoreReplay.narrowings(changes)
        #expect(narrowings.isEmpty,
                "records accepted before are no longer accepted — invariant (a)")
    }
}
