import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// Review F02 / F05 (2026-08-26) — a volunteer service's declared daily
/// ceiling is a duty of care, not a rate-limit detail. FreeREG and FreeCEN are
/// run by volunteers and publish a 300/day limit; FreeBMD forbids programmatic
/// access outright. Exceeding a ceiling, or silently clearing a
/// parked-until-tomorrow state, is taking something from people who gave it
/// freely.
///
/// EV31 added an on-demand parish-DETAIL fetch path with its own
/// `SourceBudgetTracker`, cached on `AppState` for the life of the project.
/// `SourceBudgetTracker` rehydrates from `source_budget_state` only in `init`
/// and persisted the WHOLE row on every counted request, so:
///
///   10:00  a detail fetch builds tracker D, count 3, and caches it
///   11:30  a research run's own tracker spends FreeREG to 300 and parks it
///   11:35  cached tracker D still holds 3 → believes FreeREG is available,
///          fetches, and writes 3+1 back over the 300
///   11:40  the next run rehydrates 4 and finds 296 requests of headroom
///
/// — over 600 requests in one UTC day against a declared 300, and the park
/// gone. Three independent repairs, all pinned here:
///
///   1. `ProjectDatabase.saveSourceBudgetWindow` merges non-destructively: a
///      spent request can never be un-spent (within a window the count only
///      rises; only a genuine day roll resets it).
///   2. `AppState.detailFetchBudgetTracker()` builds FRESH every call, so the
///      decision to fetch is made against what is actually spent right now.
///   3. `SourceBudgetTracker.absorb` is the read half of (1). Non-destructive
///      merging stops a stale tracker un-spending a budget, but it does so by
///      DISCARDING the lower writer's count — so while a background
///      `RunRequestWatcher` run held the higher number, the detail path's own
///      GETs were never counted at all and the day's true total still ran over
///      the ceiling. `loadParishDetailsForReview` absorbs before every
///      dispatch, so its request lands on top of the run's spend.
@MainActor
struct SourceBudgetTrackerTests {

    private static func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// 00:00 UTC on two consecutive days — the reset boundaries a
    /// `.utcMidnight` window anchors to.
    private static let day1 = at("2026-08-26T00:00:00Z")
    private static let day2 = at("2026-08-27T00:00:00Z")
    private static let noon = at("2026-08-26T12:00:00Z")

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func window(_ count: Int, start: Date = SourceBudgetTrackerTests.day1,
                        source: String = "freereg") -> SourceBudgetWindow {
        SourceBudgetWindow(sourceID: source, windowStart: start, requestCount: count)
    }

    // MARK: - 1. A spent request can never be un-spent

    @Test func aStaleWriterCannotHandBackAVolunteersSpentDay() throws {
        let db = try makeDB()
        // The research run parked FreeREG at its 300/day ceiling.
        try db.saveSourceBudgetWindow(window(300))
        // The detail fetcher, holding a count frozen hours earlier, records
        // one more request and persists 3 + 1.
        try db.saveSourceBudgetWindow(window(4))

        let stored = try db.loadSourceBudgetWindows()
        #expect(stored.count == 1)
        #expect(stored.first?.requestCount == 300,
                "a stale tracker must not restore 296 requests of headroom against a volunteer host")
        #expect(stored.first?.windowStart == Self.day1)
    }

    @Test func theCountStillRisesWithinTheWindow() throws {
        let db = try makeDB()
        try db.saveSourceBudgetWindow(window(3))
        try db.saveSourceBudgetWindow(window(4))
        #expect(try db.loadSourceBudgetWindows().first?.requestCount == 4,
                "non-destructive must not mean frozen — real spend still counts up")
    }

    @Test func aDayRollIsTheOnlyLegitimateReset() throws {
        let db = try makeDB()
        try db.saveSourceBudgetWindow(window(300))
        // Tomorrow's first request: a strictly newer window replaces outright.
        try db.saveSourceBudgetWindow(window(1, start: Self.day2))
        let stored = try db.loadSourceBudgetWindows().first
        #expect(stored?.requestCount == 1)
        #expect(stored?.windowStart == Self.day2)
    }

    @Test func aWriterStillOnYesterdaysWindowCannotTouchTodaysCount() throws {
        let db = try makeDB()
        try db.saveSourceBudgetWindow(window(5, start: Self.day2))
        // A tracker that has not rolled forward yet, carrying a big stale count.
        try db.saveSourceBudgetWindow(window(900, start: Self.day1))
        let stored = try db.loadSourceBudgetWindows().first
        #expect(stored?.requestCount == 5, "yesterday's count is not today's")
        #expect(stored?.windowStart == Self.day2)
    }

    @Test func aLaterTimestampOnTheSameDayIsNotADayRoll() throws {
        // `SourceBudgetWindow` anchors a source's FIRST window at the
        // wall-clock moment of its first counted request, not at the reset
        // boundary — so two trackers that both started before the row existed
        // carry DIFFERENT `windowStart` values for the same day. Comparing raw
        // timestamps would read the later of the two as a fresh day and wipe a
        // live count, which is the same volunteer-quota reset by another route.
        let db = try makeDB()
        let morning = Self.at("2026-08-26T09:30:00Z")
        let later = Self.at("2026-08-26T10:00:00Z")
        try db.saveSourceBudgetWindow(
            SourceBudgetWindow(sourceID: "freereg", windowStart: morning, requestCount: 200))
        try db.saveSourceBudgetWindow(
            SourceBudgetWindow(sourceID: "freereg", windowStart: later, requestCount: 1))
        let stored = try db.loadSourceBudgetWindows().first
        #expect(stored?.requestCount == 200, "same UTC day is the same budget")
        #expect(stored?.windowStart == morning, "the day keeps its earliest anchor")
    }

    @Test func aFirstWriteForAnUnseenSourceStillInserts() throws {
        let db = try makeDB()
        try db.saveSourceBudgetWindow(window(1))
        #expect(try db.loadSourceBudgetWindows().first?.requestCount == 1)
    }

    @Test func sourcesDoNotShareAWindow() throws {
        let db = try makeDB()
        try db.saveSourceBudgetWindow(window(300, source: "freereg"))
        try db.saveSourceBudgetWindow(window(2, source: "freecen"))
        let rows = try db.loadSourceBudgetWindows()
            .reduce(into: [String: Int]()) { $0[$1.sourceID] = $1.requestCount }
        #expect(rows["freereg"] == 300)
        #expect(rows["freecen"] == 2, "the merge is per source, not global")
    }

    // MARK: - The full F02 scenario, at tracker level

    @Test func theDetailPathCannotResetABudgetTheRunSpent() async throws {
        let db = try makeDB()
        let clock = Self.noon
        let policies = ["freereg": SourceBudgetPolicy(dailyLimit: 5, reset: .utcMidnight)]
        let persist: @Sendable (SourceBudgetWindow) -> Void = { w in
            try? db.saveSourceBudgetWindow(w)
        }

        // 10:00 — one parish-detail GET from a review bucket.
        let detail = SourceBudgetTracker(
            policies: policies, restoredWindows: [], now: { clock }, persist: persist)
        await detail.recordRequest("freereg")
        #expect(!(await detail.isPaused("freereg")))

        // 10:05–11:30 — the research run's own tracker rehydrates and spends
        // the rest of the day.
        let run = SourceBudgetTracker(
            policies: policies, restoredWindows: try db.loadSourceBudgetWindows(),
            now: { clock }, persist: persist)
        for _ in 0..<4 { await run.recordRequest("freereg") }
        #expect(await run.isPaused("freereg"), "5 of 5 — parked until tomorrow")

        // 11:35 — the cached tracker that shipped still believes it has room…
        #expect(!(await detail.isPaused("freereg")),
                "this is exactly the staleness the AppState cache preserved")
        // …but it can no longer un-spend the day.
        await detail.recordRequest("freereg")
        #expect(try db.loadSourceBudgetWindows().first?.requestCount == 5,
                "the persisted ceiling survives a stale writer")

        // And the fix on the other side: a FRESH tracker — what
        // `AppState.detailFetchBudgetTracker()` now builds on every call —
        // sees the park and refuses.
        let reopened = SourceBudgetTracker(
            policies: policies, restoredWindows: try db.loadSourceBudgetWindows(),
            now: { clock }, persist: persist)
        #expect(await reopened.isPaused("freereg"),
                "a volunteer source that has spent its day is not asked again")
    }

    // MARK: - 3. A live tracker can absorb what another tracker has spent

    /// Review F02 (2026-08-26) — the non-destructive merge alone stops a spent
    /// budget being handed back, but it does so by DISCARDING the lower
    /// writer's count. So while a `RunRequestWatcher` run was spending FreeREG
    /// in the background, the parish-detail path's own GETs were absorbed into
    /// the run's larger number and never counted at all — the day's true total
    /// ran over the declared ceiling by however many the review clicks cost.
    /// `absorb` is the read half of the merge: the same rule, applied before
    /// the decision instead of after it.

    @Test func absorbingSeesWhatAnotherTrackerSpent() async {
        let clock = Self.noon
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [window(3)], now: { clock })
        #expect(!(await tracker.isPaused("freereg")), "3 of 300 — headroom when it was built")
        await tracker.absorb([window(300)])
        #expect(await tracker.isPaused("freereg"),
                "FreeREG published 300/day; a review click must not be request 301")
    }

    @Test func absorbingNeverLowersALiveCount() async {
        let clock = Self.noon
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [window(300)], now: { clock })
        // A writer sitting on a count frozen hours ago.
        await tracker.absorb([window(3)])
        #expect(await tracker.isPaused("freereg"), "a spent request cannot be un-spent by a stale reader")
    }

    @Test func absorbingKeepsTheEarliestAnchorWithinADay() async {
        // Two trackers that each started before the row existed anchor the
        // same day at different wall-clock moments. Comparing raw timestamps
        // would read the later as a fresh day; the merge is by reset period.
        let clock = Self.noon
        let morning = Self.at("2026-08-26T09:30:00Z")
        let later = Self.at("2026-08-26T10:00:00Z")
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [
                SourceBudgetWindow(sourceID: "freereg", windowStart: morning, requestCount: 200)],
            now: { clock })
        await tracker.absorb([
            SourceBudgetWindow(sourceID: "freereg", windowStart: later, requestCount: 1)])
        #expect(await tracker.state(for: "freereg") == .available(remaining: 100),
                "same UTC day is the same budget — 200 spent, not 1")
    }

    @Test func absorbingAStrictlyLaterWindowIsTheOneLegitimateReset() async {
        let clock = Self.at("2026-08-27T12:00:00Z")
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [window(300)], now: { clock })
        await tracker.absorb([window(2, start: Self.day2)])
        #expect(await tracker.state(for: "freereg") == .available(remaining: 298),
                "tomorrow's count is tomorrow's — and it is 2, not 0 and not 300")
    }

    @Test func absorbingAnEarlierWindowCannotTouchToday() async {
        let clock = Self.at("2026-08-27T12:00:00Z")
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [window(2, start: Self.day2)], now: { clock })
        await tracker.absorb([window(900, start: Self.day1)])
        #expect(await tracker.state(for: "freereg") == .available(remaining: 298),
                "yesterday's count is not today's")
    }

    @Test func absorbingIsPerSourceAndAddsUnseenOnes() async {
        let clock = Self.noon
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight),
                       "freecen": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)],
            restoredWindows: [window(300, source: "freereg")], now: { clock })
        await tracker.absorb([window(5, source: "freecen")])
        #expect(await tracker.isPaused("freereg"), "the merge is per source, not global")
        #expect(await tracker.state(for: "freecen") == .available(remaining: 295))
    }

    /// The whole point, end to end: the detail path's request must land ON TOP
    /// of what the run spent, not be masked by it.
    @Test func anAbsorbedDetailRequestIsCountedOnTopOfTheRunsSpend() async throws {
        let db = try makeDB()
        let clock = Self.noon
        let persist: @Sendable (SourceBudgetWindow) -> Void = { try? db.saveSourceBudgetWindow($0) }
        let policies = ["freereg": SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)]

        // The detail tracker was built while the day was untouched.
        let detail = SourceBudgetTracker(
            policies: policies, restoredWindows: [], now: { clock }, persist: persist)
        // A background run then spends 100 and persists them.
        try db.saveSourceBudgetWindow(window(100))

        await detail.absorb(try db.loadSourceBudgetWindows())
        await detail.recordRequest("freereg")
        #expect(try db.loadSourceBudgetWindows().first?.requestCount == 101,
                "without absorbing, this writes 1, the MAX merge keeps 100, and the GET the volunteer host actually served is never counted")
    }

    @Test func absorbingADayRollReArmsTheExhaustionAnnouncement() async {
        // The once-per-window announcement must not be swallowed by a roll
        // that arrived through `absorb` rather than through `recordRequest`.
        let clock = MovableClock(Self.noon)
        let announced = Announcements()
        let tracker = SourceBudgetTracker(
            policies: ["freereg": SourceBudgetPolicy(dailyLimit: 2, reset: .utcMidnight)],
            restoredWindows: [window(1)], now: { clock.date },
            emit: { _, _ in await announced.record() })
        await tracker.recordRequest("freereg")           // 2 of 2 — announced once
        #expect(await announced.count == 1)

        clock.set(Self.at("2026-08-27T12:00:00Z"))
        await tracker.absorb([window(1, start: Self.day2)])
        await tracker.recordRequest("freereg")           // 2 of 2 on the new day
        #expect(await announced.count == 2,
                "a new day's exhaustion is a new fact for the user, not a repeat")
    }

    // MARK: - 2. AppState never caches the detail tracker

    private func stateWithFreeREG(_ db: ProjectDatabase) -> AppState {
        let state = AppState()
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(FreeREGSource())
        // Registry first, database second: `attachSearchRegistry` starts the
        // MCP run-request watcher when a project is already open, and these
        // tests want no polling loop against a scratch file.
        state.attachSearchRegistry(registry)
        state.currentDatabase = db
        return state
    }

    @Test func theDetailBudgetTrackerIsBuiltFreshEveryCall() throws {
        let db = try makeDB()
        let state = stateWithFreeREG(db)
        let first = state.detailFetchBudgetTracker()
        let second = state.detailFetchBudgetTracker()
        #expect(first != nil)
        #expect(first !== second,
                "a cached tracker rehydrates once and never learns what a run spent afterwards")
    }

    @Test func aDetailTrackerBuiltAfterARunSeesTheParkedSource() async throws {
        let db = try makeDB()
        let state = stateWithFreeREG(db)

        // 10:00 — the tracker the review bucket built while there was headroom.
        let early = state.detailFetchBudgetTracker()
        #expect(!(await early?.isPaused("freereg") ?? true))

        // 11:30 — a research run spends FreeREG's declared 300/day ceiling.
        // Anchored to the current UTC day so the window is live, not rolled.
        let today = Calendar.utc.startOfDay(for: Date())
        try db.saveSourceBudgetWindow(
            SourceBudgetWindow(sourceID: "freereg", windowStart: today, requestCount: 300))

        // 11:35 — the next bucket open. The cached instance is still blind…
        #expect(!(await early?.isPaused("freereg") ?? true))
        // …so the detail path must not be handed it.
        let reopened = state.detailFetchBudgetTracker()
        #expect(await reopened?.isPaused("freereg") == true,
                "FreeREG published 300/day; a review click must not be request 301")
    }
}

/// Counts `DailyBudgetExhausted` emissions. File scope and `@unchecked
/// Sendable`, matching this target's established test-double idiom — the
/// target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and
/// `SourceBudgetTracker`'s `emit`/`now` hooks are `@Sendable`.
private actor Announcements {
    private(set) var count = 0
    func record() { count += 1 }
}

/// A clock the test can wind forward. `SourceBudgetTracker`'s `now` is a
/// `@Sendable` closure, which cannot capture a mutable local `var`.
/// `nonisolated` because the closure is `@Sendable`: every access is already
/// NSLock-guarded, so it is safe off the main actor and must say so.
private final nonisolated class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func set(_ new: Date) { lock.withLock { value = new } }
}
