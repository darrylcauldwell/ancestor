import Foundation

/// Cross-run persistent negative-search reader (connector-audit
/// CONNECTOR_AUDIT_2026-07 §6.1 T1-04 / §5.2). The honesty envelope
/// (a6e9c6d) made `negative_searches` a genuine WRITER — one durable
/// row per clean-zero WIRE query, keyed by `QueryCache.cacheKey`. This
/// is the READER: before the dispatcher re-fires a query on a later
/// run, it asks this cache whether that exact query was proved cleanly
/// empty on a prior run and is still fresh. If so the live request is
/// SKIPPED and the query is treated as a known-empty result — the
/// 30–50% traffic reduction the audit cites for re-researched subjects.
///
/// Distinct from `QueryCache`, which is per-run and dedupes identical
/// wire requests WITHIN one `research()` call. `NegativeSearchCache`
/// spans runs and only ever suppresses proven-empty queries — it never
/// serves cached records, only a synthetic clean-empty outcome.
///
/// Correctness guards (stated here, enforced by the type + covered by
/// `NegativeSearchCacheTests`):
///   (a) Only clean prior negatives suppress. The writer
///       (`NegativeSearchAggregator.genuineNegativeKeys` →
///       `ProjectDatabase.saveNegativeSearch`) records a row ONLY for a
///       query whose entire (source, recordType) pair answered
///       `.ok` / untruncated / zero with no record in hand. Errors,
///       throttles, blocks, and truncated pages are never written, so
///       they can never be read back as a suppression. A suppressed
///       replay is itself excluded from re-persistence (its outcome is
///       `isCleanNegative == false`), so suppressions never double-count.
///   (b) A freshness window bounds every suppression. A stored negative
///       older than the window is ignored, so a stale negative
///       eventually re-verifies against the live source. Default is
///       conservative (`.days(90)` — matches the audit's "~90 days for
///       growing corpora" guidance); callers pass a tighter window (e.g.
///       same-session) when they want to re-verify sooner.
///   (c) A force-refresh escape hatch. `.disabled` ignores the store
///       entirely — every query goes to the wire. Wired to `.verify`
///       mode and a config flag so the user can always demand a fresh
///       pass.
///   (d) The match key is `QueryCache.cacheKey` verbatim on both the
///       write and the read side — the SAME normalization code path —
///       so a param-shape drift between writer and reader is impossible
///       by construction (there is only one shape).
nonisolated struct NegativeSearchCache: Sendable {

    /// How long a stored clean negative may suppress a re-fire before it
    /// must re-verify against the live source (guard (b)).
    nonisolated struct FreshnessWindow: Sendable, Equatable {
        /// Suppress iff `now - searchedAt <= maxAge`.
        let maxAge: TimeInterval

        /// Suppress nothing older than `days` days. The default cross-run
        /// window: long enough to spare a re-researched subject its whole
        /// proven-empty fan-out, short enough that growing corpora
        /// (FreeBMD, FindAGrave) get re-probed within a quarter.
        static func days(_ days: Double) -> FreshnessWindow {
            FreshnessWindow(maxAge: days * 24 * 60 * 60)
        }

        /// Conservative default — 90 days.
        static let `default` = FreshnessWindow.days(90)
    }

    /// The queryKeys proved cleanly empty on a prior run, mapped to the
    /// most-recent time each was proved empty. Empty when suppression is
    /// off or the profile has no stored negatives.
    private let negativesByKey: [String: Date]
    private let window: FreshnessWindow
    /// Clock injection point — tests pin `now` to exercise the freshness
    /// boundary deterministically; production passes `Date()`.
    private let now: Date

    /// A cache that suppresses nothing — the force-refresh escape hatch
    /// (guard (c)) and the safe fallback for manual-input / lead subjects
    /// with no profile id, and for any DB-load failure.
    static let disabled = NegativeSearchCache(negativesByKey: [:], window: .default, now: Date())

    init(negativesByKey: [String: Date], window: FreshnessWindow, now: Date) {
        self.negativesByKey = negativesByKey
        self.window = window
        self.now = now
    }

    /// Build from raw DB rows (`ProjectDatabase.loadNegativeSearchKeys`).
    /// Keeps the most-recent `searched_at` per queryKey (rows arrive
    /// newest-first, but be defensive). Rows are already profile-scoped by
    /// the loader.
    init(
        rows: [(sourceID: String, recordType: String, queryKey: String, date: Date)],
        window: FreshnessWindow = .default,
        now: Date = Date()
    ) {
        var byKey: [String: Date] = [:]
        for row in rows {
            if let existing = byKey[row.queryKey], existing >= row.date { continue }
            byKey[row.queryKey] = row.date
        }
        self.init(negativesByKey: byKey, window: window, now: now)
    }

    /// Build the cross-run cache from rows the pipeline's loader closure
    /// already fetched. Returns `.disabled` (suppress nothing) when there
    /// is no profile id or force-refresh is requested — the safe
    /// direction is always "go to the wire". The pipeline holds a
    /// closure loader rather than the DB itself (mirroring
    /// `rejectionLookup` etc.), so `rows` is the pre-fetched result;
    /// callers pass `[]` when the loader is nil.
    ///
    /// `forceRefresh` is the escape hatch (guard (c)): `.verify` mode and
    /// the `ResearchConfig.forceRefreshNegatives` flag both pass `true`,
    /// yielding `.disabled` so every query re-verifies.
    static func load(
        profileID: String?,
        rows: [(sourceID: String, recordType: String, queryKey: String, date: Date)],
        window: FreshnessWindow = .default,
        forceRefresh: Bool,
        now: Date = Date()
    ) -> NegativeSearchCache {
        guard !forceRefresh, profileID != nil else { return .disabled }
        return NegativeSearchCache(rows: rows, window: window, now: now)
    }

    /// If `queryKey` was proved cleanly empty within the freshness
    /// window, return the suppressed outcome to substitute for a live
    /// dispatch; otherwise nil (go to the wire). The reason string names
    /// the date so the activity feed can surface "skipped — searched
    /// \<date\>, empty".
    func suppression(forQueryKey queryKey: String) -> SearchOutcome? {
        guard let searchedAt = negativesByKey[queryKey] else { return nil }
        let age = now.timeIntervalSince(searchedAt)
        // Guard against clock skew / future timestamps: a negative dated
        // in the future (age < 0) is within any window, which is fine —
        // it's still a recent proven-empty.
        guard age <= window.maxAge else { return nil }
        return .suppressedNegative(reason: "prior clean negative \(Self.stamp(searchedAt))")
    }

    /// True when this cache can suppress at least one query — lets the
    /// dispatcher skip the per-query lookup entirely on the common
    /// first-run / disabled path.
    var isEmpty: Bool { negativesByKey.isEmpty }

    /// UTC `yyyy-MM-dd` stamp for the activity-feed reason string.
    /// Computed from calendar components rather than a shared
    /// `DateFormatter` so the type stays trivially `Sendable` /
    /// `nonisolated` (no non-Sendable static state).
    private static func stamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
