# Source Plugin Architecture — Specification

**Status:** Proposed (v2 — revised after critique)  
**Scope:** How external data sources are structured, registered, configured, and extended  
**Date:** 2026-04-25  

---

## 1. Design Goal

Every external genealogical data source is a self-contained plugin conforming to a single protocol. Adding a new source means:

1. Create one new file in `Services/Sources/`
2. Implement the `RecordSource` protocol (and optionally `DetailFetchingSource`)
3. Register it in `SourceBootstrap.swift`

No changes to the pipeline, scorer, UI, or any other source. The plugin boundary is the `RecordSource` protocol — everything inside the plugin is private; everything outside sees only the protocol.

---

## 2. File Structure

```
Ancestor Research/
├── Services/
│   ├── Research/               ← Pipeline infrastructure (exists)
│   │   ├── RecordSource.swift          ← Protocol definition
│   │   ├── RecordTypes.swift           ← SourceRecord enum, typed records
│   │   ├── RecordScorer.swift          ← 4-gate classifier
│   │   ├── ScoringRules.swift          ← Shared scoring primitives
│   │   ├── SourceHTTPClient.swift      ← Shared HTTP with retry
│   │   ├── SourceRegistry.swift        ← Registration + enable/disable
│   │   ├── QueryCache.swift            ← Intra-run dedup
│   │   └── RegionConfig.swift          ← Region data
│   │
│   └── Sources/                ← One file per source plugin
│       ├── SourceBootstrap.swift       ← Registers all sources at app launch
│       ├── FreeBMDSource.swift         ← FreeBMD plugin
│       ├── FreeCenSource.swift         ← FreeCen plugin
│       ├── FindAGraveSource.swift      ← Find a Grave plugin
│       ├── CWGCSource.swift            ← CWGC plugin
│       ├── ProbateSource.swift         ← Probate Calendar plugin
│       ├── WirksworthSource.swift      ← Wirksworth.org.uk plugin
│       ├── FreeREGSource.swift         ← FreeREG plugin
│       └── FamilySearchSource.swift    ← FamilySearch plugin
```

Each source file contains:
- One `actor` conforming to `RecordSource`
- All private parsing, session management, and URL construction
- No imports from other source files — sources are independent

---

## 3. Plugin Template

Every source follows the same structure. This is the template — copy it to create a new source.

```swift
// Services/Sources/ExampleSource.swift

import Foundation
import os

/// [Source Name] — [one-line description of what it provides]
/// [URL of the source]
/// Access: [API type — JSON API / POST form / HTML scraping / CSV export]
/// Auth: [None / CSRF token / Cookie-based]
/// Coverage: [date range and geographic scope]
actor ExampleSource: RecordSource {

    // MARK: - RecordSource Protocol (nonisolated metadata)

    nonisolated let sourceID = "example"
    nonisolated let displayName = "Example Source"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1837...1983

    // MARK: - State

    private let http = SourceHTTPClient.shared  // stateless — retry logic only
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Example")

    // Rate limiting — owned by this actor, not the shared HTTP client
    private var lastRequestTime: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(300)

    // Source health tracking
    private(set) var lastSuccessfulSearch: Date?
    private(set) var lastError: String?

    // MARK: - Readiness

    var readiness: SourceReadiness { .ready }
    // For auth-required sources: check cookie validity, return .needsAuth if expired

    // MARK: - Search

    func search(_ query: RecordQuery) async throws -> [SourceRecord] {
        // 1. Validate query — does this source support the requested record type?
        guard recordTypes.contains(query.recordType) else { return [] }

        do {
            // 2. Build source-specific request (URL, form fields, headers)
            // 3. Execute with rate limiting (owned by this actor)
            // let data = try await rateLimitedRequest { try await http.get(url: ...) }
            // 4. Parse response into [SourceRecord]
            // 5. Track success
            lastSuccessfulSearch = Date()
            lastError = nil
            return []
        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            return []  // graceful degradation
        }
    }

    // MARK: - Rate Limiting (per-source, actor-isolated)

    /// Wait for rate limit, then execute. No cross-actor hop for timing.
    private func rateLimitedRequest(_ operation: () async throws -> Data) async throws -> Data {
        if let lastTime = lastRequestTime {
            let elapsed = ContinuousClock.now - lastTime
            if elapsed < requestDelay {
                try await Task.sleep(for: requestDelay - elapsed)
            }
        }
        lastRequestTime = .now
        return try await operation()
    }

    // MARK: - Private Parsing

    // All parsing logic is private to this actor.
    // Response format documentation goes here as comments.
    // init() must be lightweight — no network calls, no large allocations.
    // Heavy setup happens lazily on first search() call.
}

// If this source supports detail fetching:
extension ExampleSource: DetailFetchingSource {
    func fetchDetail(recordID: String) async throws -> SourceRecord? {
        // Fetch and parse detail page for a specific record
        return nil
    }
}
```

---

## 4. Source Bootstrap

A single function registers all sources at app launch. This is the only place where concrete source types are referenced — the rest of the app works through the `RecordSource` protocol.

```swift
// Services/Sources/SourceBootstrap.swift

import Foundation

/// Register all available record sources.
/// Called once at app launch. Each source is an independent actor.
@MainActor
func bootstrapSources(registry: SourceRegistry) {
    registry.register(FreeBMDSource())
    registry.register(FreeCenSource())
    registry.register(FindAGraveSource())
    registry.register(CWGCSource())
    registry.register(ProbateSource())
    registry.register(WirksworthSource())
    registry.register(FreeREGSource())
    registry.register(FamilySearchSource())
}
```

**Adding a new source:**
1. Create `NewSource.swift` in `Services/Sources/`
2. Add `registry.register(NewSource())` to `bootstrapSources()`
3. Done. The pipeline, scorer, UI, and all other sources are unchanged.

**Init must be lightweight:** All source `init()` methods must complete instantly — no network calls, no large allocations, no file I/O. Heavy setup (session tokens, form discovery) happens lazily on the first `search()` call. This ensures app launch isn't blocked by 8 sources each making HTTP requests.

**Removing a source:**
1. Delete the source file
2. Remove the `registry.register(...)` line
3. Done.

---

## 5. Integration with App Lifecycle

```swift
// Ancestor_ResearchApp.swift

@main
struct Ancestor_ResearchApp: App {
    @State private var appState = AppState()
    @State private var sourceRegistry: SourceRegistry = {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return registry
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(sourceRegistry)
        }
    }
}
```

Sources are registered once at `@State` initialisation — not in `onAppear` (which fires every time the window appears). The `SourceRegistry` is injected into the environment. Any view or service that needs sources reads `@Environment(SourceRegistry.self)`.

---

## 6. Source Complexity Tiers

Sources fall into three tiers by how they handle authentication and session state. The protocol is the same for all — the complexity is internal to each plugin.

### Tier 1: Stateless (no auth, no session)

The simplest plugins. Each request is independent — no cookies, no tokens, no session state.

| Source | HTTP method | Response format | Notes |
|--------|------------|-----------------|-------|
| **CWGC** | GET | CSV | URL params, parse CSV rows |
| **Probate** | GET | JSON | Nuxeo API, pagination via pageSize/pageIndex |
| **Find a Grave** | GET | JSON + HTML | Search returns JSON; detail page is HTML scrape |
| **Wirksworth** | GET | HTML | Two parsing modes: structured PRE + narrative prose |

**Pattern:** Build URL → `rateLimitedRequest { http.get(url:) }` → parse response → return `[SourceRecord]`.

No session management. No teardown. Rate-limiting state (last-request timestamp) is owned by the source actor itself, not the shared HTTP client.

### Tier 2: CSRF Token (session per search batch)

These sources require fetching a page to extract a token before searching.

| Source | Token flow | Notes |
|--------|-----------|-------|
| **FreeBMD** | GET search page → extract cookie + hidden fields (`db`, `v`) → POST search | Token is per-session, refreshed on first search |
| **FreeCen** | GET form page → extract CSRF token → POST search | Token per session, Chapman code for county |
| **FreeREG** | GET form page → extract CSRF token + radio values → POST search | Dynamic form discovery, experimental |

**Pattern:**

```swift
actor FreeBMDSource: RecordSource {
    private var sessionCookie: String?
    private var formTokenDB: String?
    private var formTokenV: String?

    /// Ensure we have a valid session before searching.
    private func ensureSession() async throws {
        guard sessionCookie == nil else { return }
        // GET the search form page
        let data = try await http.get(url: searchFormURL, headers: userAgentHeaders)
        let html = String(data: data, encoding: .utf8) ?? ""
        // Extract cookie and hidden form tokens
        sessionCookie = extractCookie(from: html)
        formTokenDB = extractFormToken(named: "db", from: html)
        formTokenV = extractFormToken(named: "v", from: html)
    }

    func search(_ query: RecordQuery) async throws -> [SourceRecord] {
        try await ensureSession()
        // POST with session cookie and tokens
        ...
    }
}
```

The session state is private to the actor. If a session expires (HTTP 403 or empty results), the actor clears its tokens and `ensureSession()` fetches fresh ones on the next search.

### Tier 3: Manual Auth (external credentials)

These sources require credentials the user provides outside the app.

| Source | Auth method | Lifecycle |
|--------|-----------|-----------|
| **FamilySearch** | Cookie string pasted from browser DevTools | Expires every ~2 hours. User re-pastes in Settings. |

**Pattern:**

```swift
actor FamilySearchSource: RecordSource {
    private var cookies: String = ""

    var readiness: SourceReadiness {
        cookies.isEmpty ? .needsAuth(message: "Paste FamilySearch cookies in Settings") : .ready
    }

    /// Called from Settings UI when user pastes new cookies.
    func setCookies(_ newCookies: String) {
        cookies = newCookies
    }

    func search(_ query: RecordQuery) async throws -> [SourceRecord] {
        guard !cookies.isEmpty else { return [] }
        // GET with Cookie header
        let data = try await http.rateLimited(sourceID: sourceID) {
            try await http.get(url: searchURL, headers: ["Cookie": cookies])
        }
        // If 401/403 → cookies expired, clear and return empty
        ...
    }
}
```

**Settings UI integration:** The Settings view checks `sourceRegistry.source(for: "familysearch")` and casts to `FamilySearchSource` to call `setCookies(_:)`. This is the ONE place where a concrete source type is referenced outside `SourceBootstrap` — acceptable for auth configuration.

Alternatively, add an optional auth protocol:

```swift
/// Sources that accept external credentials.
protocol AuthenticatingSource: RecordSource {
    /// Human-readable label for the credential (e.g., "Session Cookie", "API Key").
    nonisolated var credentialLabel: String { get }
    
    /// Set the credential value. Single string — most auth is one token/cookie.
    func setCredential(_ value: String) async
}
```

Then Settings iterates `registry.allSources().compactMap { $0 as? AuthenticatingSource }` and renders a text field for each with its `credentialLabel`. No concrete type references needed. Single `String` parameter covers cookies, API keys, and tokens without an untyped dictionary.

---

## 7. Source Metadata for UI

The `RecordSource` protocol provides enough metadata for the UI to render source cards in Settings and the Source Explorer without knowing the concrete type:

| Property | Used for |
|----------|---------|
| `sourceID` | Internal key, enable/disable persistence |
| `displayName` | Display in Settings, Source Explorer, search results |
| `recordTypes` | Filter: "which sources can search for births?" |
| `coverageYearRange` | Display: "FreeBMD covers 1837–1983" |
| `readiness` | Display: ready / needs auth / unavailable |

**Source health tracking:** Each source tracks its own health state, accessible from the UI:

```swift
/// Added to RecordSource protocol:
protocol RecordSource: Actor {
    // ... existing properties ...
    
    /// When this source last returned results successfully.
    var lastSuccessfulSearch: Date? { get }
    
    /// Last error message, if any (nil = no recent errors).
    var lastError: String? { get }
}
```

The Settings UI reads these to show source status:
- **Green:** "Last worked 2 minutes ago"
- **Amber:** "Last worked 3 days ago" (stale — may be broken)
- **Red:** "Last error: parsing failure — site may have changed"
- **Grey:** "Never searched" (no history)

This makes a broken parser distinguishable from "no results" — the user sees the source is broken, not that their ancestor doesn't exist.

---

## 8. Error Handling Within Plugins

Each source handles its own errors privately. The protocol's `search()` throws — but sources should prefer returning empty results over throwing for expected failures (site down, no results, expired auth).

**When to return `[]`:**
- No results found (normal)
- Auth expired (graceful degradation — log warning, return empty)
- Source temporarily unavailable (site down, rate limited after retries)

**When to throw:**
- Permanent configuration error (invalid source setup)
- Unexpected response format (parsing failure — indicates site changed, needs code update)

**Error logging:** Each source logs errors via `os.Logger` with its own subsystem category:

```swift
import os

actor FreeBMDSource: RecordSource {
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FreeBMD")

    func search(_ query: RecordQuery) async throws -> [SourceRecord] {
        do {
            ...
        } catch {
            logger.warning("FreeBMD search failed: \(error.localizedDescription)")
            return []  // graceful degradation
        }
    }
}
```

---

## 9. Testing Sources

Each source is independently testable because it's an actor with no dependencies on other sources.

**Integration test pattern** (hits real server — use for validation, not CI):

```swift
@Test func freeBMDSearchReturnsResults() async throws {
    let source = FreeBMDSource()
    let query = RecordQuery(
        surname: "Land", givenName: "Thomas",
        birthYear: 1834, deathYear: nil,
        gender: .male, location: "Derbyshire",
        recordType: .birth, yearFrom: 1832, yearTo: 1836,
        additionalParams: [:]
    )
    let results = try await source.search(query)
    #expect(!results.isEmpty)
    #expect(results.allSatisfy { $0.sourceID == "freebmd" })
}
```

**Unit test pattern** (canned response, no network):

```swift
@Test func freeBMDParserExtractsRecords() {
    let html = """
    var searchData = new Array ("...canned response data...");
    """
    let records = FreeBMDSource.parseSearchResults(html)  // static, testable
    #expect(records.count == 3)
    #expect(records[0].surname == "LAND")
}
```

Sources should expose parsing logic as `static` functions where practical, so parsing can be unit-tested with canned HTML/JSON without network access.

**Mock source for pipeline testing:**

```swift
actor MockSource: RecordSource {
    nonisolated let sourceID = "mock"
    nonisolated let displayName = "Mock Source"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death, .census]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil

    var readiness: SourceReadiness { .ready }
    var cannedResults: [SourceRecord] = []

    func search(_ query: RecordQuery) async throws -> [SourceRecord] {
        cannedResults
    }
}
```

Register `MockSource` instead of real sources to test the pipeline without network access.

---

## 10. Source Configuration

Some sources need per-region configuration (FreeBMD district codes, FreeCen Chapman codes). This comes from `RegionConfig`, not from the source itself.

**Pattern:** The dispatcher builds **one `RecordQuery` per source**, not one shared query broadcast to all. Each query's `additionalParams` carries source-specific parameters with source-prefixed keys to avoid collisions.

```swift
// In SearchDispatcher, when building a FreeBMD query:
let districtCodes = regionConfig.districts  // ["Belper": "722", "Ashbourne": "418", ...]
for (name, code) in districtCodes {
    let query = RecordQuery(
        surname: subject.surname,
        givenName: subject.givenName,
        ...
        additionalParams: ["freebmd_district": code]
    )
    results += try await freeBMDSource.search(query)
}

// FreeCen uses a different key:
let query = RecordQuery(
    ...
    additionalParams: ["freecen_chapman_code": "DBY"]
)
```

**Key convention:** `additionalParams` keys are prefixed with the source ID: `"freebmd_district"`, `"freecen_chapman_code"`, `"familysearch_collection"`. This prevents two sources accidentally using the same key name for different values.

The source reads its own prefixed keys and ignores others. Sources don't know about `RegionConfig` — they just receive strings. This keeps sources region-agnostic: the same `FreeBMDSource` works for Derbyshire, Lancashire, or any English county.

---

## 11. Source-Level Caching

`QueryCache` exists at the pipeline level for intra-run deduplication. Individual sources may also cache responses internally — this is private to each actor and not managed by the pipeline.

**When useful:** FreeBMD session tokens (valid for the whole search batch), Find a Grave detail pages (don't change between searches), CSRF tokens (reusable until expired).

**Convention:** Source-level caches are actor-isolated state. They are never shared between sources. No persistence — caches clear when the actor is deallocated (app restart).

---

## 12. Response Parsing Conventions

Each source parses its response format privately. To maintain consistency:

1. **`RecordCommon.id`** — use a source + type prefixed format: `"freebmd_birth_\(vol)_\(page)"`, `"cwgc_\(casualtyID)"`, `"findagrave_\(memorialID)"`. Include record type where the same source can return different types from the same index (e.g., FreeBMD births vs deaths may share volume/page). Globally unique, traceable to source.

2. **`RecordCommon.sourceID`** — always set to `self.sourceID` (`"freebmd"`, `"cwgc"`, etc.).

3. **`RecordCommon.rawFields`** — store the original key-value pairs from the source response. Used for debugging and LLM context. Keys are source-specific (no normalisation).

4. **Name splitting** — sources that return a combined name should split into `surname` and `givenName` in `RecordCommon`. Sources that return pre-split names use them directly. The scorer works with split names.

5. **Year extraction** — if the source returns a date string ("12 Mar 1845"), extract the year into the typed record's `birthYear`/`deathYear` field AND keep the original string in `birthDate`/`deathDate`. The scorer uses the year; the UI shows the original.

---

## 12. The 8 Source Plugins — Implementation Priority

| Priority | Source | Tier | Why this order |
|----------|--------|------|---------------|
| 1 | **Find a Grave** | 1 (stateless) | Simplest source — JSON API, no auth, no session. Validates the plugin template end-to-end with minimum risk. |
| 2 | **FreeBMD** | 2 (CSRF) | Most important data — birth/death/marriage for 1837+. First CSRF source, establishes the session pattern. |
| 3 | **FreeCen** | 2 (CSRF) | Census + household — reveals whole families. Reuses the CSRF pattern from FreeBMD. |
| 4 | **CWGC** | 1 (stateless) | Military dead — CSV export, quick to port. |
| 5 | **Probate** | 1 (stateless) | Wills/grants — JSON API, straightforward. |
| 6 | **Wirksworth** | 1 (stateless) | Regional pedigrees — HTML scraping, Derbyshire-specific. |
| 7 | **FreeREG** | 2 (CSRF) | Parish registers — experimental in Python, same in Swift. |
| 8 | **FamilySearch** | 3 (manual auth) | Richest source but fragile auth. Build last, test most. |

**Build the simplest source first** (Find a Grave, Tier 1) to validate the plugin template. Then the most important sources (FreeBMD + FreeCen, Tier 2). Phase 2 delivers sources 1-3 — enough for a working pipeline covering burial, civil registration, and census.

---

## 14. Adding a New Source — Checklist

When adding a new source to the app:

- [ ] Create `Services/Sources/NewSource.swift`
- [ ] Implement `RecordSource` protocol (and `DetailFetchingSource` if applicable)
- [ ] Set `sourceID`, `displayName`, `recordTypes`, `coverageYearRange`
- [ ] Implement `search(_:)` with rate limiting via `SourceHTTPClient.shared`
- [ ] Parse responses into appropriate `SourceRecord` cases
- [ ] Use `RecordCommon.id` with source prefix (e.g., `"newsource_\(id)"`)
- [ ] Store raw fields in `RecordCommon.rawFields`
- [ ] Add graceful error handling (return `[]` for expected failures, throw for unexpected)
- [ ] Add `os.Logger` for diagnostics
- [ ] Register in `SourceBootstrap.swift`
- [ ] Add a unit test that searches for a known person
- [ ] If auth required: implement `AuthenticatingSource` and add Settings UI
- [ ] If detail fetching supported: implement `DetailFetchingSource`

---

## 15. What This Spec Does NOT Cover

- **Source Explorer UI** — how the UI renders source results. Separate from the plugin architecture.
- **Pipeline dispatcher** — how the pipeline decides which sources to query for a given subject. Uses `RecordQuery.additionalParams` for source-specific params.
- **Result caching beyond QueryCache** — persistent cross-session caching of source results. Future work.
- **Source health monitoring** — tracking source uptime, response times, error rates. Future work.
