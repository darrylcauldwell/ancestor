import Foundation

/// Global registry of user-added prose corpora.
///
/// Lives at `<baseDirectory>/corpora/registry.json` and lists every
/// corpus the user has added on this machine. The registry is the
/// dispatcher's source of truth for which prose corpora exist; the
/// per-corpus `manifest.json` (see `ProseCorpusManifest`) carries the
/// full detail.
///
/// Spec §3.3 — the registry is the only data structure the rest of the
/// app needs to consult to enumerate corpora. Adding a corpus appends
/// an entry; removing deletes the entire `<source_id>/` directory and
/// the registry row.
///
/// Concurrency model: a single instance is shared across the app
/// (registered on `AppState` in P3 commit #3). All mutations go through
/// `add(...)` / `remove(...)` which read-modify-write atomically. The
/// underlying file is written via temp-file + rename so a crashed app
/// never leaves a half-written registry visible.
nonisolated struct ProseCorpusRegistry {
    let baseDirectory: URL

    /// Bumped when the on-disk shape of `registry.json` changes in a
    /// way callers can't ignore. v1 is the initial schema.
    static let schemaVersion: Int = 1

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Default initializer using the app's sandboxed Application Support
    /// directory. Mirrors `ProseCorpusStorage.init(sourceID:)`.
    init() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.baseDirectory = appSupport.appendingPathComponent("AncestorResearch", isDirectory: true)
    }

    // MARK: - Paths

    var corporaDirectory: URL {
        baseDirectory.appendingPathComponent("corpora", isDirectory: true)
    }

    var registryURL: URL {
        corporaDirectory.appendingPathComponent("registry.json")
    }

    /// Directory for a specific corpus. Combine with `ProseCorpusStorage`
    /// to read/write pages and manifest.
    func corpusDirectory(forSourceID sourceID: String) -> URL {
        corporaDirectory.appendingPathComponent(sourceID, isDirectory: true)
    }

    // MARK: - Load / save

    /// Read the registry from disk. Returns an empty document when the
    /// file is missing (a fresh install hasn't added anything yet).
    /// Throws on malformed JSON or unsupported schema.
    func load() throws -> ProseCorpusRegistryDocument {
        let fm = FileManager.default
        guard fm.fileExists(atPath: registryURL.path) else {
            return ProseCorpusRegistryDocument(schemaVersion: Self.schemaVersion, corpora: [])
        }
        let data = try Data(contentsOf: registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(ProseCorpusRegistryDocument.self, from: data)
        guard doc.schemaVersion == Self.schemaVersion else {
            throw RegistryError.unsupportedSchemaVersion(doc.schemaVersion)
        }
        return doc
    }

    /// Write the registry atomically (temp-file + rename) so concurrent
    /// readers never see a half-written file.
    func save(_ document: ProseCorpusRegistryDocument) throws {
        try FileManager.default.createDirectory(
            at: corporaDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let tempURL = registryURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: registryURL.path) {
            _ = try FileManager.default.replaceItemAt(registryURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: registryURL)
        }
    }

    // MARK: - Mutation

    /// Append a corpus to the registry. Throws `.duplicateSourceID` if
    /// the source_id is already present — callers should derive a new
    /// id via `availableSourceID(for:)` before calling.
    @discardableResult
    func add(_ entry: ProseCorpusRegistryEntry) throws -> ProseCorpusRegistryDocument {
        var doc = try load()
        if doc.corpora.contains(where: { $0.sourceID == entry.sourceID }) {
            throw RegistryError.duplicateSourceID(entry.sourceID)
        }
        doc.corpora.append(entry)
        try save(doc)
        return doc
    }

    /// Remove a corpus by `sourceID`. Returns the new document state.
    /// Idempotent: missing IDs are a no-op. The caller is responsible
    /// for deleting the `<source_id>/` directory tree separately via
    /// `removeCorpusDirectory(...)` — registry mutation and filesystem
    /// teardown are split so a crash between them doesn't lose the
    /// content (the registry row is the last thing to go, so partial
    /// failures leave the corpus addressable).
    @discardableResult
    func remove(sourceID: String) throws -> ProseCorpusRegistryDocument {
        var doc = try load()
        doc.corpora.removeAll(where: { $0.sourceID == sourceID })
        try save(doc)
        return doc
    }

    /// Delete the `<source_id>/` directory tree (pages, manifest, logs,
    /// crawl-state). Called by the *Remove* action in the Settings UI
    /// after the registry entry has been removed.
    func removeCorpusDirectory(sourceID: String) throws {
        let dir = corpusDirectory(forSourceID: sourceID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - source_id derivation

    /// Derive a `source_id` from a seed URL per spec §3.3:
    /// hostname-with-dots-replaced-by-hyphens, plus the first path
    /// segment if non-empty, lowercased. Stripped of `www.` prefix
    /// because every volunteer site that uses `www` also serves at the
    /// bare apex; we'd rather collapse the trivial duplicate than carry
    /// a `www-` prefix forever.
    ///
    /// The result is always filesystem-safe (lowercase ASCII + hyphens
    /// + digits + dots). Non-ASCII or unusual characters in the URL are
    /// replaced with hyphens.
    static func deriveSourceID(from url: URL) -> String {
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let hostSlug = sanitiseSlug(host.replacingOccurrences(of: ".", with: "-"))

        // First non-empty path segment. URL.pathComponents includes the
        // leading "/" as one component, so drop it.
        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let pathSlug = pathComponents.first.map { sanitiseSlug($0.lowercased()) } ?? ""

        if pathSlug.isEmpty { return hostSlug }
        return "\(hostSlug)-\(pathSlug)"
    }

    /// Replace anything that isn't lowercase a-z / 0-9 / `.` / `-` with
    /// `-`, collapse runs of `-`, trim leading/trailing `-`. The
    /// resulting string is safe to use as a directory name on every
    /// filesystem we care about (APFS, ext4, NTFS).
    private static func sanitiseSlug(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "." {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        // Collapse runs of consecutive `-`.
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Resolve a candidate `source_id` against the live registry,
    /// returning the first non-colliding form. Spec §3.3 — collisions
    /// get a numeric suffix (`-2`, `-3`, …).
    ///
    /// Returns the base id unchanged when it doesn't collide.
    func availableSourceID(for url: URL) throws -> String {
        let base = Self.deriveSourceID(from: url)
        let doc = try load()
        let used = Set(doc.corpora.map(\.sourceID))
        if !used.contains(base) { return base }
        var n = 2
        while used.contains("\(base)-\(n)") {
            n += 1
            if n > 9999 {
                // Pathological case — registry is full of clones. Bail.
                throw RegistryError.sourceIDExhausted(base: base)
            }
        }
        return "\(base)-\(n)"
    }

    // MARK: - Errors

    enum RegistryError: Error, CustomStringConvertible {
        case unsupportedSchemaVersion(Int)
        case duplicateSourceID(String)
        case sourceIDExhausted(base: String)

        var description: String {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "Unsupported registry schema version: \(v)"
            case .duplicateSourceID(let id):
                return "Source ID already present in registry: \(id)"
            case .sourceIDExhausted(let base):
                return "Could not allocate a non-colliding source ID derived from base \(base)"
            }
        }
    }
}

// MARK: - Registry document shape

/// On-disk shape of `corpora/registry.json` (spec §3.3). Decoded with
/// snake_case JSON keys to match the spec's literal schema.
nonisolated struct ProseCorpusRegistryDocument: Codable, Equatable {
    let schemaVersion: Int
    var corpora: [ProseCorpusRegistryEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpora
    }
}

/// One row in the registry — pointer to a corpus, no operational state.
/// Operational fields (page count, last synced, partial-crawl warnings)
/// live in the per-corpus `manifest.json`.
nonisolated struct ProseCorpusRegistryEntry: Codable, Equatable, Identifiable, Sendable {
    let sourceID: String
    let displayTitle: String
    let addedAt: Date

    var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case displayTitle = "display_title"
        case addedAt = "added_at"
    }
}

// MARK: - Per-corpus manifest

/// Per-corpus `manifest.json` shape (spec §3.1). Written by the crawler
/// at the end of every successful run, read on app boot to surface
/// corpus state in the Settings UI.
///
/// Immutable fields (`sourceID`, `displayTitle`, `seedURL`, etc.) are
/// set at add-time and never change for the corpus's lifetime — re-add
/// under a different seed creates a new source_id. Mutable fields
/// (`lastSyncedAt`, `pageCount`, `totalBytes`) update on every sync.
nonisolated struct ProseCorpusManifest: Codable, Equatable, Sendable {
    let sourceID: String
    let displayTitle: String
    let seedURL: URL
    let addedByUserAt: Date
    let schemaVersion: Int
    let crawlerVersion: String
    let crawlDepth: Int
    /// Glob or regex serialised as a string; `null` means "follow
    /// everything that passes same-host + depth". Format matches the
    /// `ProseCorpusCrawler.LinkFilter` cases via a `kind:body` encoding
    /// (e.g. `"glob:*/PEDIGREE.htm"`, `"regex:\\.htm$"`).
    let linkFilter: String?
    let pageBudget: Int
    var firstBuiltAt: Date?
    var lastSyncedAt: Date?
    var pageCount: Int
    var totalBytes: Int
    let robotsTxtURL: URL
    var robotsTxtFetchedAt: Date?
    let userAgent: String
    /// Stop reason from the most recent crawl, persisted so partial-
    /// crawl warnings survive app restart. `nil` means "never synced"
    /// or "pre-P7 manifest, no record" — UI treats those the same as
    /// "no warning". Stored as the rawValue from `CrawlStopReason`
    /// so we don't bake the enum into the manifest schema.
    var lastSyncStopReason: String?

    /// Has this corpus produced at least one successful crawl? Drives
    /// the Settings UI's "Sync" vs "Build" affordance.
    var hasBeenBuilt: Bool { firstBuiltAt != nil }

    /// `true` when the last crawl stopped for a reason that left the
    /// corpus only partially populated. Surfaces a warning chip in
    /// the Settings UI so the user knows the corpus isn't authoritative.
    var lastSyncWasPartial: Bool {
        guard let reason = lastSyncStopReason else { return false }
        return CrawlStopReason(rawValue: reason)?.isPartial == true
    }

    static let currentSchemaVersion: Int = 1

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case displayTitle = "display_title"
        case seedURL = "seed_url"
        case addedByUserAt = "added_by_user_at"
        case schemaVersion = "schema_version"
        case crawlerVersion = "crawler_version"
        case crawlDepth = "crawl_depth"
        case linkFilter = "link_filter"
        case pageBudget = "page_budget"
        case firstBuiltAt = "first_built_at"
        case lastSyncedAt = "last_synced_at"
        case pageCount = "page_count"
        case totalBytes = "total_bytes"
        case robotsTxtURL = "robots_txt_url"
        case robotsTxtFetchedAt = "robots_txt_fetched_at"
        case userAgent = "user_agent"
        case lastSyncStopReason = "last_sync_stop_reason"
    }
}

/// String-keyed projection of `ProseCorpusCrawler.CrawlReport.StopReason`
/// used to persist a partial-crawl warning across app launches. The
/// enum's `seedFailed(String)` case stores the underlying reason as
/// the rawValue's suffix (`"seed_failed:<reason>"`) — UI surfaces the
/// suffix verbatim when warning about a failed seed so the user
/// doesn't have to dig into logs.
nonisolated enum CrawlStopReason: Sendable, Equatable {
    case complete
    case budgetExhausted
    case circuitBreakerExhausted
    case seedFailed(reason: String)

    var rawValue: String {
        switch self {
        case .complete: return "complete"
        case .budgetExhausted: return "budget_exhausted"
        case .circuitBreakerExhausted: return "circuit_breaker_exhausted"
        case .seedFailed(let reason): return "seed_failed:\(reason)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "complete": self = .complete
        case "budget_exhausted": self = .budgetExhausted
        case "circuit_breaker_exhausted": self = .circuitBreakerExhausted
        default:
            if rawValue.hasPrefix("seed_failed:") {
                self = .seedFailed(reason: String(rawValue.dropFirst("seed_failed:".count)))
            } else {
                return nil
            }
        }
    }

    /// Whether this stop reason should surface a partial-crawl
    /// warning. Only `.complete` is clean; everything else means
    /// the user should know the corpus is incomplete.
    var isPartial: Bool {
        if case .complete = self { return false }
        return true
    }

    /// One-line label for the Settings UI chip. Distinct from
    /// `rawValue` (which is the on-disk encoding).
    var displayLabel: String {
        switch self {
        case .complete: return "Crawl complete"
        case .budgetExhausted: return "Page budget reached — partial corpus"
        case .circuitBreakerExhausted: return "Host throttled — partial corpus"
        case .seedFailed(let reason): return "Seed failed: \(reason)"
        }
    }
}

// MARK: - Manifest I/O on ProseCorpusStorage

/// `nonisolated` so callers in non-MainActor contexts (e.g. the
/// `ProseCorpusAdder` orchestrator and the `ProseCorpusCrawler` actor)
/// can invoke these. Without the annotation, the project's Swift 6.2
/// default-isolation setting would make every extension method
/// implicitly MainActor and lock the manifest behind UI threading.
nonisolated extension ProseCorpusStorage {
    /// Read `manifest.json`. Returns `nil` for a corpus that has been
    /// added but never crawled (the manifest is written by the crawler,
    /// not at add-time — though P3 wires add-time to write an initial
    /// manifest with `firstBuiltAt: nil`).
    func readManifest() throws -> ProseCorpusManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProseCorpusManifest.self, from: data)
    }

    /// Write `manifest.json` atomically. Creates intermediate
    /// directories if missing.
    func writeManifest(_ manifest: ProseCorpusManifest) throws {
        try FileManager.default.createDirectory(
            at: corpusDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let tempURL = manifestURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: manifestURL)
        }
    }
}
