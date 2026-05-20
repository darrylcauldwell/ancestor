import SwiftUI
import os

/// App-wide, single-instance service that backs the *Prose Corpora*
/// section of the Settings UI. Wraps `ProseCorpusAdder` with an
/// `@Observable` SwiftUI surface — the views read `corpora`, the
/// `syncingSourceIDs` set, and the latest verification result; they
/// never touch the registry or adder directly.
///
/// Why a service rather than per-view state: the registry lives in
/// Application Support, is shared across project windows and across
/// app launches, and a crawl initiated from one settings window
/// shouldn't be invisible to another. Keeping the observable state
/// in one place lets every window mirror the same truth.
///
/// Concurrency: `@MainActor` for SwiftUI binding correctness. The
/// async methods spawn `Task { }`s that await the adder's
/// `async`/`throws` surface; results land back on the main actor to
/// update the published state. The crawler itself is an actor and
/// runs off-main internally.
@MainActor @Observable
final class ProseCorpusService {
    /// Combined view-model rows — registry entry + manifest, ready for
    /// the list UI. Reloaded from disk by `refresh()`.
    private(set) var corpora: [Row] = []

    /// Source IDs whose `sync(...)` is in flight. The settings row
    /// shows a spinner for each. Drained on completion (success or
    /// failure).
    private(set) var syncingSourceIDs: Set<String> = []

    /// Latest crawl report keyed by source_id, surfaced inline below
    /// the row so the user can see stop reason, page counts, and the
    /// first few skip causes without needing a separate detail view.
    private(set) var lastReports: [String: ProseCorpusCrawler.CrawlReport] = [:]

    /// Latest *verify* result for the Add sheet. The sheet renders
    /// this as soon as the user runs the probe; cleared when the
    /// sheet dismisses so re-opening starts clean.
    private(set) var pendingVerification: SiteVerification?

    /// `true` while a verify probe is in flight. The Add sheet
    /// disables fields and shows a spinner during this window.
    private(set) var isVerifying: Bool = false

    /// User-visible error message from the most recent failed
    /// add/sync/remove. `nil` when the last operation succeeded or
    /// none has run yet. Cleared by `clearError()` once the UI has
    /// presented it.
    private(set) var lastError: String?

    private let adder: ProseCorpusAdder
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusService")

    init(adder: ProseCorpusAdder) {
        self.adder = adder
        try? loadFromDisk()
    }

    /// Convenience factory for production wiring. Resolves the
    /// Application Support path, builds a registry + adder + the
    /// shared HTTP client. Throws if Application Support is
    /// unreachable, which the app entry surfaces as a startup error.
    static func makeForProduction() throws -> ProseCorpusService {
        let registry = try ProseCorpusRegistry()
        let adder = ProseCorpusAdder(
            registry: registry,
            http: SourceHTTPClient.shared
        )
        return ProseCorpusService(adder: adder)
    }

    // MARK: - Refresh

    /// Reload the corpus list from disk. Called on init and after
    /// every mutation (`add`, `sync`, `remove`). Cheap — registry +
    /// per-corpus manifest reads, no network.
    @discardableResult
    func refresh() throws -> [Row] {
        try loadFromDisk()
        return corpora
    }

    private func loadFromDisk() throws {
        let doc = try adder.registry.load()
        var rows: [Row] = []
        for entry in doc.corpora {
            let storage = ProseCorpusStorage(
                baseDirectory: adder.registry.baseDirectory,
                sourceID: entry.sourceID
            )
            let manifest = (try? storage.readManifest())
            rows.append(Row(entry: entry, manifest: manifest))
        }
        corpora = rows.sorted { $0.entry.addedAt < $1.entry.addedAt }
    }

    // MARK: - Verify (Add sheet)

    /// Run a verification probe against a candidate seed URL. Updates
    /// `pendingVerification` / `isVerifying` so the sheet UI binds
    /// directly. Idempotent — repeated calls overwrite the previous
    /// result.
    func verify(seedURL: URL) async {
        isVerifying = true
        defer { isVerifying = false }
        let result = await adder.verify(seedURL: seedURL)
        pendingVerification = result
    }

    /// Clear the verify state. Called when the Add sheet dismisses so
    /// the next open starts with a fresh slate.
    func clearVerification() {
        pendingVerification = nil
        isVerifying = false
    }

    // MARK: - Add

    /// Commit a verified add and immediately kick off the first sync
    /// in the background. The sheet calls this once the user confirms
    /// the verification result — the list refreshes synchronously so
    /// the new row appears straight away; the spinner on that row
    /// indicates the crawl is running.
    func add(
        seedURL: URL,
        displayTitle: String,
        crawlDepth: Int,
        pageBudget: Int,
        linkFilter: ProseCorpusCrawler.LinkFilter?
    ) async {
        do {
            let result = try adder.commitAdd(
                seedURL: seedURL,
                displayTitle: displayTitle,
                crawlDepth: crawlDepth,
                pageBudget: pageBudget,
                linkFilter: linkFilter
            )
            try loadFromDisk()
            // Kick off the first crawl immediately. The Settings UI
            // shows progress via syncingSourceIDs; failures land in
            // lastError and lastReports.
            await sync(sourceID: result.entry.sourceID)
        } catch {
            lastError = "Add failed: \(error)"
            logger.error("Add failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Sync

    /// Run a crawl for an existing corpus. Updates `syncingSourceIDs`
    /// for the duration; the result lands in `lastReports`. Errors
    /// are captured in `lastError` rather than thrown — the UI
    /// surfaces them as a banner so the user isn't stranded.
    func sync(sourceID: String) async {
        guard !syncingSourceIDs.contains(sourceID) else {
            // Already in flight — don't double-up.
            return
        }
        syncingSourceIDs.insert(sourceID)
        defer { syncingSourceIDs.remove(sourceID) }
        do {
            let report = try await adder.sync(sourceID: sourceID)
            lastReports[sourceID] = report
            try loadFromDisk()
        } catch {
            lastError = "Sync failed for \(sourceID): \(error)"
            logger.error("Sync failed for \(sourceID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Remove

    /// Tear down a corpus end-to-end. Registry row + on-disk tree are
    /// removed in one call. The list refreshes immediately. Active
    /// syncs against the same source are NOT cancelled — the spec
    /// doesn't require interruption and the crawler's writes go to a
    /// directory that won't exist after this returns, so the storage
    /// layer will surface the FileManager error in the report and
    /// the sync will end naturally on its next loop iteration.
    func remove(sourceID: String) async {
        do {
            try adder.remove(sourceID: sourceID)
            lastReports[sourceID] = nil
            try loadFromDisk()
        } catch {
            lastError = "Remove failed for \(sourceID): \(error)"
            logger.error("Remove failed for \(sourceID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Error dismissal

    func clearError() { lastError = nil }

    // MARK: - View-model row

    /// One row per corpus, ready for the SwiftUI list. Combines the
    /// registry entry (always present) with the manifest (always
    /// present after a successful `commitAdd`; may be absent very
    /// briefly during teardown).
    struct Row: Identifiable, Equatable {
        let entry: ProseCorpusRegistryEntry
        let manifest: ProseCorpusManifest?

        var id: String { entry.sourceID }
        var sourceID: String { entry.sourceID }
        var displayTitle: String { entry.displayTitle }
        var seedURL: URL? { manifest?.seedURL }
        var pageCount: Int { manifest?.pageCount ?? 0 }
        var totalBytes: Int { manifest?.totalBytes ?? 0 }
        var hasBeenBuilt: Bool { manifest?.hasBeenBuilt ?? false }
        var lastSyncedAt: Date? { manifest?.lastSyncedAt }
    }
}
