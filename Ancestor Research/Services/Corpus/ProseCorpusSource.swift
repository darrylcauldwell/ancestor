import Foundation
import GRDB
import os

/// Per-spec §9 retrieval surface for the prose-corpus subsystem.
///
/// One `ProseCorpusSource` instance is registered with the global
/// `SourceRegistry` at app boot — that gives the user a single
/// Settings toggle ("Prose Corpora") that gates *all* user-added
/// corpora at once. Per-corpus enable/disable is a future
/// refinement; for v1, all registered corpora participate when the
/// global toggle is on.
///
/// The source declares `recordTypes: []` on purpose — prose
/// candidates are not record-typed in the structured sense (a page
/// "about Cauldwell in Wirksworth 1820" is not a birth/death/marriage
/// record), so the dispatcher's standard per-record-type loop will
/// never route to this source. Instead, callers (the research view
/// model surfacing activity-log entries; in P6, the MLX extractor)
/// call `searchCandidates(query:limit:)` directly — a dedicated
/// surface that returns `ProseCandidate` values, not `SourceRecord`s.
/// This keeps prose pages out of the structured-record pipeline
/// (scorer, convergence, evidence firewall) entirely until P6
/// promotes extracted facts through the firewall like any other
/// pending fact.
///
/// Concurrency: an `actor`, because each search opens N SQLite
/// `DatabaseQueue`s (one per registered corpus). Caching them keeps
/// repeat searches cheap; the actor's serial section serialises
/// cache writes. SQLite handles its own threading.
actor ProseCorpusSource: RecordSource {

    // MARK: - RecordSource protocol surface

    nonisolated let sourceID = "prose-corpus"
    nonisolated let scopeHandling: ScopeHandling = .localCorpus
    nonisolated let displayName = "Prose Corpora"
    nonisolated let descriptiveName = "User-added narrative sources (parish records, local-history pages, etc.)"
    /// Empty — prose candidates aren't dispatch-routable by record
    /// type. Callers go through `searchCandidates(...)` directly.
    nonisolated let recordTypes: Set<RecordType> = []
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = []
    nonisolated let dataLineage: SourceLineage = .communityEdited
    nonisolated let trustTier: SourceTrustTier = .community
    nonisolated let evidenceDirectness: EvidenceDirectness = .derivative
    nonisolated let tosStatus = SourceToSStatus(
        level: .community,
        summary: "User-supplied URLs — terms of service are the user's responsibility to verify."
    )
    nonisolated let kind: SourceKind = .general

    /// No-op for the standard RecordSource entry point; returns an
    /// empty result so the source registers cleanly but the
    /// dispatcher never confuses prose candidates with structured
    /// records. Real entry point is `searchCandidates(...)`.
    func search(_ query: RecordQuery) async -> SourceQueryResult {
        return .results([])
    }

    // MARK: - Dependencies

    /// Same path the registry/storage layer uses — typically
    /// `~/Library/Application Support/AncestorResearch` in production,
    /// or a temp directory in tests.
    let registryBaseDirectory: URL

    /// Surname-variant lookup. Injectable so tests can stub a small
    /// fixture; production passes `SurnameVariants.shared`.
    let surnameVariants: SurnameVariants

    /// Gazetteer used to translate a `Region` query into a set of
    /// candidate place tokens that match `page_places.place_lower`.
    let gazetteer: [GazetteerEntry]

    init(
        registryBaseDirectory: URL,
        surnameVariants: SurnameVariants,
        gazetteer: [GazetteerEntry]
    ) {
        self.registryBaseDirectory = registryBaseDirectory
        self.surnameVariants = surnameVariants
        self.gazetteer = gazetteer
    }

    /// Convenience factory for production wiring — resolves
    /// Application Support, uses the shared `SurnameVariants` and
    /// `LocationGazetteer` singletons. Throws on Application Support
    /// resolution failure; the bootstrap caller treats that as
    /// "prose-corpus retrieval unavailable this launch" rather than
    /// a fatal startup error.
    ///
    /// `@MainActor` because Swift 6.2's project default isolation
    /// puts the actor's init on MainActor; this factory runs the
    /// init under the same isolation domain to satisfy that. The
    /// resulting instance is still a regular actor — its async API
    /// is called from any context via `await`.
    @MainActor
    static func makeForProduction() throws -> ProseCorpusSource {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = appSupport.appendingPathComponent("AncestorResearch", isDirectory: true)
        return ProseCorpusSource(
            registryBaseDirectory: base,
            surnameVariants: SurnameVariants.shared,
            gazetteer: LocationGazetteer.shared.all()
        )
    }

    nonisolated private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusSource")

    // MARK: - Index cache

    /// Cached `ProseCorpusIndex` instances keyed by `source_id`. Re-
    /// opened lazily on first hit; survives for the lifetime of the
    /// source instance. Bounded only by the registry size, which is
    /// user-controlled and small (a handful of corpora per user).
    private var indexCache: [String: ProseCorpusIndex] = [:]

    private func index(forCorpusID corpusID: String) throws -> ProseCorpusIndex {
        if let cached = indexCache[corpusID] { return cached }
        let path = registryBaseDirectory
            .appendingPathComponent("corpora", isDirectory: true)
            .appendingPathComponent(corpusID, isDirectory: true)
            .appendingPathComponent("index.sqlite")
            .path
        let opened = try ProseCorpusIndex(path: path)
        indexCache[corpusID] = opened
        return opened
    }

    /// Invalidate the cached index for a corpus. Called by
    /// `ProseCorpusService` after a `remove` so the next search
    /// doesn't try to read a torn-down SQLite file.
    func invalidate(corpusID: String) {
        indexCache.removeValue(forKey: corpusID)
    }

    /// Load the markdown body for a candidate by opening the corpus's
    /// `ProseCorpusStorage` and reading the `.md` file at the page
    /// hash. Returns nil if the file is missing or malformed —
    /// callers (the P6 prose extractor) treat that as "skip this
    /// candidate" rather than failing the whole run.
    func loadPageBody(forCandidate candidate: ProseCandidate) -> (frontmatter: PageFrontmatter, body: String)? {
        let storage = ProseCorpusStorage(
            baseDirectory: registryBaseDirectory,
            sourceID: candidate.sourceID
        )
        return try? storage.readPage(pageHash: candidate.pageHash)
    }

    // MARK: - searchCandidates — the real entry point

    /// Run a prose-corpus search across every registered corpus and
    /// return the global top-K candidates ranked by the spec §9.2
    /// weighting (`surname * 3 + year * 2 + place * 1`).
    ///
    /// Returns an empty array if the query has no `surname` (surname
    /// is the gate — same as the spec's `INNER JOIN surname_hits`).
    /// Errors at the per-corpus level (corrupt index, missing file)
    /// are logged and the corpus is skipped; the rest of the search
    /// continues so one bad corpus doesn't take down retrieval.
    func searchCandidates(query: RecordQuery, limit: Int = 5) async -> [ProseCandidate] {
        guard let surname = query.surname, !surname.isEmpty else {
            return []
        }
        let registry = ProseCorpusRegistry(baseDirectory: registryBaseDirectory)
        guard let document = try? registry.load() else { return [] }
        if document.corpora.isEmpty { return [] }

        let summary = Self.activitySummary(surname: surname, query: query)
        await ResearchActivityBus.shared.publish(
            .sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness)
        )

        // Build the per-query parameter set once.
        let surnameTokens = Self.surnameTokens(for: surname, variants: surnameVariants)
        let yearRange = Self.yearRange(from: query)
        let placeTokens = Self.placeTokens(for: query.region, gazetteer: gazetteer)

        var allHits: [ProseCandidate] = []
        for entry in document.corpora {
            do {
                let index = try self.index(forCorpusID: entry.sourceID)
                let rows = try Self.queryIndex(
                    index: index,
                    sourceID: entry.sourceID,
                    surnameTokens: surnameTokens,
                    yearRange: yearRange,
                    placeTokens: placeTokens,
                    limit: limit
                )
                allHits.append(contentsOf: rows)
            } catch {
                Self.logger.error("Prose corpus search failed for \(entry.sourceID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Global top-K — score DESC, then deterministic tie-break
        // on (sourceID, pageHash) so AC-R3 holds.
        let sorted = allHits.sorted { (a, b) in
            if a.score != b.score { return a.score > b.score }
            if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
            return a.pageHash < b.pageHash
        }
        let topK = Array(sorted.prefix(limit))
        await ResearchActivityBus.shared.publish(
            .sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: topK.count, strictness: query.strictness)
        )
        return topK
    }

    /// One-line activity-feed label. Mirrors the shape used by the
    /// structured sources ("FreeBMD Belper marriages: Cauldwell ×
    /// Holmes 1946-1977") so all events read consistently.
    nonisolated static func activitySummary(surname: String, query: RecordQuery) -> String {
        var parts: [String] = ["Prose corpora"]
        if let given = query.givenName, !given.isEmpty {
            parts.append("\(given) \(surname)")
        } else {
            parts.append(surname)
        }
        if let yr = Self.yearRange(from: query) {
            parts.append("\(yr.lowerBound)-\(yr.upperBound)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - SQL

    /// Per-corpus index query. Spec §9.2 CTE: surname is the gate
    /// (INNER JOIN), year and place are LEFT JOINs that contribute
    /// to score. Sort by `(sc * 3 + yc * 2 + pc) DESC` plus a
    /// `page_hash` tie-breaker so the per-corpus top-K is itself
    /// deterministic (the dispatcher merges them deterministically
    /// in `searchCandidates`).
    nonisolated private static func queryIndex(
        index: ProseCorpusIndex,
        sourceID: String,
        surnameTokens: [String],
        yearRange: ClosedRange<Int>?,
        placeTokens: [String],
        limit: Int
    ) throws -> [ProseCandidate] {
        // Surname IN clause — placeholders only.
        let surnamePlaceholders = Array(repeating: "?", count: surnameTokens.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = surnameTokens

        // Conditionally include year/place CTEs based on whether the
        // query has them — the LEFT JOIN means absent ones don't
        // gate, but the placeholder-substitution must match.
        let yearCTE: String
        if let yearRange {
            yearCTE = """
            year_hits AS (
                SELECT page_hash, COUNT(*) AS year_count
                FROM page_years
                WHERE year BETWEEN ? AND ?
                GROUP BY page_hash
            ),
            """
            arguments.append(yearRange.lowerBound)
            arguments.append(yearRange.upperBound)
        } else {
            // Empty CTE that returns no rows; LEFT JOIN keeps it
            // permissive (year_count comes back NULL → 0).
            yearCTE = """
            year_hits AS (SELECT NULL AS page_hash, 0 AS year_count WHERE 0),
            """
        }

        let placeCTE: String
        if !placeTokens.isEmpty {
            let placePlaceholders = Array(repeating: "?", count: placeTokens.count).joined(separator: ", ")
            placeCTE = """
            place_hits AS (
                SELECT page_hash, COUNT(*) AS place_count
                FROM page_places
                WHERE place_lower IN (\(placePlaceholders))
                GROUP BY page_hash
            )
            """
            arguments.append(contentsOf: placeTokens.map { $0 as DatabaseValueConvertible })
        } else {
            placeCTE = """
            place_hits AS (SELECT NULL AS page_hash, 0 AS place_count WHERE 0)
            """
        }

        arguments.append(limit)

        let sql = """
        WITH surname_hits AS (
            SELECT page_hash, SUM(mention_count) AS surname_count
            FROM page_surnames
            WHERE surname_upper IN (\(surnamePlaceholders))
            GROUP BY page_hash
        ),
        \(yearCTE)
        \(placeCTE)
        SELECT
            p.page_hash, p.source_url, p.title,
            COALESCE(s.surname_count, 0) AS sc,
            COALESCE(y.year_count, 0)    AS yc,
            COALESCE(pl.place_count, 0)  AS pc
        FROM pages p
        INNER JOIN surname_hits s ON s.page_hash = p.page_hash
        LEFT JOIN year_hits y    ON y.page_hash = p.page_hash
        LEFT JOIN place_hits pl  ON pl.page_hash = p.page_hash
        ORDER BY (sc * 3 + yc * 2 + pc) DESC, p.page_hash ASC
        LIMIT ?
        """

        return try index.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                ProseCandidate(
                    sourceID: sourceID,
                    pageHash: row["page_hash"],
                    sourceURL: row["source_url"],
                    title: row["title"],
                    surnameHits: row["sc"],
                    yearHits: row["yc"],
                    placeHits: row["pc"]
                )
            }
        }
    }

    // MARK: - Query → parameter helpers

    /// Surname token set: the surname itself plus any known variants,
    /// all uppercased to match `page_surnames.surname_upper`.
    nonisolated static func surnameTokens(for surname: String, variants: SurnameVariants) -> [String] {
        var set: Set<String> = [surname.uppercased()]
        for variant in variants.variants(of: surname) {
            set.insert(variant.uppercased())
        }
        // Sort so the placeholder order is deterministic — keeps
        // SQL prepared-statement caches efficient and makes test
        // output stable.
        return set.sorted()
    }

    /// Year range derived from `yearFrom`/`yearTo`. nil if neither
    /// is set (no year constraint).
    nonisolated static func yearRange(from query: RecordQuery) -> ClosedRange<Int>? {
        switch (query.yearFrom, query.yearTo) {
        case (let f?, let t?): return f...t
        case (let f?, nil): return f...1999  // open-upper → corpus ceiling
        case (nil, let t?): return 1500...t  // open-lower → corpus floor
        case (nil, nil): return nil
        }
    }

    /// Translate a `Region` into the gazetteer's lowercased name
    /// tokens that intersect it. Returns an empty array when no
    /// region is given or no entries match — the caller treats that
    /// as "no place constraint" (LEFT JOIN, place_count = 0).
    ///
    /// Inlines a small subset of `Region.overlaps(_:)` semantics
    /// rather than calling it: under the project's Swift 6.2 default
    /// isolation, `Region.overlaps` is MainActor-isolated, but this
    /// helper needs to run from the actor's nonisolated context.
    /// The behaviour we need is narrower — match gazetteer entries
    /// by county name (broad UK regions match everything, parish
    /// regions match same-county entries) — so duplicating the
    /// county-string comparison directly is cleaner than introducing
    /// a MainActor hop just for one boolean.
    nonisolated static func placeTokens(for region: Region?, gazetteer: [GazetteerEntry]) -> [String] {
        guard let region else { return [] }
        var tokens: Set<String> = []
        for entry in gazetteer {
            let matches: Bool
            switch region {
            case .englandAndWales, .scotland, .ireland, .commonwealthMilitary:
                // Broad regions — every gazetteer entry counts as a
                // candidate place. The corpus itself is the
                // filtering — only pages with these tokens will hit.
                matches = true
            case .county(let county):
                matches = entry.county.caseInsensitiveCompare(county) == .orderedSame
            case .parish(_, let county):
                // Parish-within-county — pull every entry sharing
                // that county. Narrower parish matching would
                // require a parish-aware gazetteer; the v1
                // gazetteer is town/parish-level without explicit
                // parish containment so county is the practical
                // join key.
                matches = entry.county.caseInsensitiveCompare(county) == .orderedSame
            }
            if matches {
                tokens.insert(entry.name.lowercased())
            }
        }
        return tokens.sorted()
    }
}

// MARK: - ProseCandidate

/// One row in the prose-corpus search result. Carries everything a
/// downstream consumer (activity-log entry, P6 MLX extractor) needs
/// to find the page on disk: the corpus's `sourceID`, the
/// `page_hash` (filename stem under `pages/`), the canonical
/// `sourceURL` (also stored in the markdown frontmatter), the
/// page title (best-effort), and the three pivot-table hit counts
/// that drove its score.
///
/// Distinct from `SourceRecord` on purpose — prose candidates are
/// not structured records and shouldn't flow through the same
/// scorer/convergence pipeline. P6 promotes them through the
/// Evidence Firewall as `pending_facts` after MLX extraction.
nonisolated struct ProseCandidate: Identifiable, Sendable, Equatable {
    let sourceID: String      // corpus source_id, e.g. "wirksworth-org-uk"
    let pageHash: String      // 16-hex stem; locates the .md file on disk
    let sourceURL: String     // original URL of the page
    let title: String?
    let surnameHits: Int
    let yearHits: Int
    let placeHits: Int

    var id: String { "\(sourceID):\(pageHash)" }

    /// Spec §9.2 weighting. Surname is the gate so this can be
    /// zero only when surnameHits is non-zero but matched on a
    /// page that scored zero on year/place (rare but legitimate).
    var score: Int { surnameHits * 3 + yearHits * 2 + placeHits }
}
