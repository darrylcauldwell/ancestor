# Ancestor Research — Detailed Design Specification

**App name:** Ancestor Research
**Internal codename:** AncestorApp (display name is a single `AppConstants.displayName` constant for easy renaming)
**Repo:** Same repo as existing Python backend (`/Users/darrylcauldwell/Development/ancestor/AncestorApp/`)
**Version:** MVP v1.0

---

## 1. Context

The genealogy research agent is currently CLI-only. FamilySearch API access was rejected for personal use — a proper macOS app qualifies for approval. Beyond unlocking FamilySearch, the app provides a proper UI for the research workflow: visualising the tree, spotting gaps, and reviewing findings.

This spec covers **MVP only** — building a strong foundation around the digital twin with one eye on the full enrichment pipeline that follows. Timeline is not a constraint — the goal is to build the right thing so the foundation is still sound in two years when enrichment, FamilySearch, leads, facts, and the research pipeline are layered on.

---

## 2. Tech Stack

- **Swift 6.2+** with strict concurrency (macOS 26 deployment target)
- **SwiftUI** with Liquid Glass design language (WWDC25)
- **@Observable** (not ObservableObject)
- **async/await** (no Combine)
- **Swift Testing** (`@Test`, `#expect`, not XCTest)
- **GRDB** for SQLite persistence
- **No AppKit** — pure SwiftUI

---

## 3. MVP Capabilities

| # | Capability | Description |
|---|-----------|-------------|
| 1 | **Multi-project management** | Create, switch, and delete independent family trees |
| 2 | **GEDCOM import** | Parse .ged files from any genealogy platform into the graph |
| 3 | **GEDCOM export** | Round-trip: export tree back to .ged. Validates internal representation — if it round-trips losslessly, the model is sound |
| 4 | **WikiTree API import** | Authenticate and fetch watchlist profiles via read-only API |
| 5 | **Manual refresh with diff** | User-controlled re-sync with visual diff of changes before committing |
| 6 | **Tree diff view** | After WikiTree refresh, show what changed — visual diff, not just a log. User reviews before accepting |
| 7 | **In-memory family graph** | Profiles and relationships with traversal, backed by SQLite via GRDB |
| 8 | **Source provenance** | Multiple corroborating sources per field. Every field tracks all sources that support it |
| 9 | **Per-profile audit trail** | Append-only history of every field change. Supports undo/time-travel |
| 10 | **Conflict resolution UI** | When sources disagree, field becomes "disputed". UI prompts user to resolve |
| 11 | **Undo / time-travel** | Reverse any change via the audit trail. Snapshot-based — fits concurrency model |
| 12 | **Interactive tree graph** | Hierarchical layout (pedigree/descendant), pan, zoom, click-to-select, completeness colouring |
| 13 | **Profile detail inspector** | Dates, locations, relationships, source badges, history timeline |
| 14 | **Deterministic audit engine** | 12 rules operating on date ranges, with formal fire conditions |
| 15 | **Gaps view** | Profiles missing parents, dates, locations, or bios |
| 16 | **Audit rules in Settings** | Read-only: invariant, fire condition, worked example for each rule |
| 17 | **Liquid Glass design** | macOS 26 native styling throughout |
| 18 | **App Store reservation** | Placeholder build to secure "Ancestor Research" name |

**Out of MVP scope:** Leads, facts, research pipeline, FamilySearch OAuth, LLM investigation, Python API server, enrichment from external sources, configurable audit rules.

---

## 4. Architecture

**Pure Swift** — no Python server dependency for MVP.

```
Ancestor Research (macOS SwiftUI, Liquid Glass)
  ├── Project Manager (create, switch, delete trees)
  ├── GEDCOM Parser + Exporter (Swift, custom)
  ├── WikiTree API Client (Swift, read-only)
  ├── SQLite (GRDB) per project
  │     └── Immutable FamilyGraphSnapshot for views
  ├── Audit Engine (deterministic rules — Swift is source of truth)
  ├── Conflict Resolver (multi-source field disagreement)
  └── Views: Project Picker, Tree Graph, Profile Detail,
             Profile History, Tree Diff, Conflict Resolution,
             Audit, Gaps, Settings
```

### 4.1 Rule Ownership: Swift is Source of Truth

**Decision: Option A.** The audit rules live in Swift only. When the Python enrichment pipeline arrives post-MVP, the Python `rules.py` will be deleted. The Python server will handle only enrichment (LLM calls, source fetching) and call back to the Swift app via IPC for audit validation. This keeps a single source of truth and avoids two implementations drifting apart.

### 4.2 Storage: SQLite (GRDB) + Immutable Snapshots

Persistence is SQLite via GRDB — one database per project. Transactional safety, incremental writes, scales to 10,000+ profiles.

SwiftData is not used — graph traversal doesn't suit relational ORM patterns. SwiftData may be introduced post-MVP for flat data (leads, facts).

### 4.3 Concurrency Model: Immutable Snapshots

**Decision: Immutable `FamilyGraphSnapshot` + mutation through `ProjectStore`.**

```swift
/// Immutable snapshot of the family graph. Natively Sendable.
/// Views receive snapshots, never the live mutable state.
/// Any mutation produces a new snapshot.
struct FamilyGraphSnapshot: Sendable {
    let profiles: [String: Profile]
    let relationships: [Relationship]

    // Pre-computed caches — built once at snapshot creation, O(1) lookup
    let completenessCache: [String: ProfileCompleteness]
    let siblingCache: [String: [String]]    // profileID → sibling IDs

    // Traversal methods on the immutable snapshot
    func parentsOf(_ id: String) -> [Profile]
    func childrenOf(_ id: String) -> [Profile]
    func spousesOf(_ id: String) -> [Profile]
    func siblingsOf(_ id: String) -> [Profile]  // From siblingCache, derived from shared parents
    func ancestorsOf(_ id: String, depth: Int) -> [Profile]
    func descendantsOf(_ id: String, depth: Int) -> [Profile]
    func completeness(for id: String) -> ProfileCompleteness
}

/// Completeness as a struct, not an Int — answers "why is this 5/7?"
/// Denominator is dynamic: living people aren't penalised for missing death date.
struct ProfileCompleteness: Sendable {
    let score: Int                          // e.g. 5
    let maximum: Int                        // 7 for dead, 6 for living
    let missing: [CompletenessCheck]        // Which checks failed
    let potentiallyLiving: Bool             // Heuristic: birthDate.latest + 110 >= currentYear
}

/// Aligned with ProfileField where possible. Structural checks are explicit.
enum CompletenessCheck: Sendable {
    case field(ProfileField)                // .field(.firstName), .field(.birthDate), etc.
    case hasParents                         // Derived from graph — not a ProfileField
}

// Applied checks:
//   .field(.firstName), .field(.birthDate), .field(.birthLocation),
//   .field(.deathLocation), .field(.bio), .hasParents
//   .field(.deathDate) — only if NOT potentiallyLiving
// This means living people max at 6/6 (100%), not 6/7 (86%).
```

**`ProjectStore` — owns mutable state, transaction-based mutations:**

```swift
@MainActor @Observable
final class ProjectStore {
    private(set) var snapshot: FamilyGraphSnapshot
    private let database: ProjectDatabase

    /// All mutations go through transactions
    func execute(_ kind: TransactionKind, changes: (inout TransactionBuilder) -> Void) {
        // 1. Create Transaction record
        // 2. Execute changes — each writes FieldChange with transactionID
        // 3. Write to SQLite in one GRDB transaction
        // 4. Rebuild snapshot
    }

    /// Undo a transaction — checks for subsequent modifications first
    func undo(_ transactionID: UUID) throws {
        // 1. Check each field: is current value still what this transaction produced?
        // 2. If any field was modified since → throw UndoConflict (UI shows dialog)
        // 3. If safe → reverse all FieldChanges, record undo as its own Transaction
        // 4. Restore any disputes that the transaction had resolved
        // 5. Rebuild snapshot
    }
}
```

**Why snapshots:**
- Natively `Sendable` under Swift 6 strict concurrency — no actor or async needed for reads
- SwiftUI views consume snapshots naturally via `@Observable`
- Import/refresh work off-main, hand a new snapshot to main on completion
- Completeness and siblings cached at build time — O(1) per lookup, cost paid once
- Known ceiling: at 10k profiles, snapshot rebuild copies entire dictionary. Fine for MVP scaling target. Persistent data structures (HAMT) would help at 100k+ but not needed now.

### 4.4 Custom GEDCOM Parser

GEDCOM 5.5.1 is a line-based text format. Real-world exports from different platforms have subtle differences (encoding, date formats, non-standard tags). A custom parser gives full control. GEDCOM export validates the model — if a file round-trips losslessly (or with explicit lossy conversion logged), the internal representation is sound.

---

## 5. Data Model

### 5.1 Project

```swift
struct Project: Codable, Identifiable {
    let id: UUID
    var name: String                    // "Cauldwell Family"
    var source: DataSource              // .gedcom(path) | .wikitree(email)
    var createdAt: Date
    var lastRefreshed: Date?
}

enum DataSource: Codable {
    case gedcom(path: String)
    case wikitree(email: String)
}
```

Storage: `~/Library/Application Support/AncestorResearch/projects/{uuid}.sqlite`

### 5.2 Profile

```swift
/// Hashable on `id` only — history/sources/disputes change frequently
/// and must not affect hash identity.
struct Profile: Codable, Identifiable {
    let id: String                      // Internal graph ID
    var externalIDs: [String: String]   // All external mappings:
                                        //   "wikitree": "Cauldwell-171"
                                        //   "gedcom": "@I001@"
                                        // No separate wtID — avoids duplication.
                                        // Access WikiTree ID via externalIDs["wikitree"]

    var firstName: String?
    var lastName: String?               // LastNameAtBirth
    var gender: Gender?

    var birthDate: GenealogicalDate?
    var birthLocation: String?
    var deathDate: GenealogicalDate?
    var deathLocation: String?
    var bio: String?

    // Source provenance — multiple corroborating sources per field
    var sources: [ProfileField: [FieldSource]]

    // Conflict state — fields where sources disagree
    var disputes: [ProfileField: FieldDispute]

    // NOTE: completeness is NOT on Profile — it's on FamilyGraphSnapshot
    // (needs parent edge lookup). See §4.3 ProfileCompleteness.
    // NOTE: history is NOT on Profile — it's in the field_changes table,
    // queried via ProjectDatabase. Keeps Profile lightweight for snapshots.
}

extension Profile: Hashable {
    static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

### 5.3 ProfileField (type-safe, not stringly-typed)

```swift
enum ProfileField: String, Codable, CaseIterable, Hashable {
    case firstName, lastName, gender
    case birthDate, birthLocation
    case deathDate, deathLocation
    case bio
}
```

### 5.4 GenealogicalDate

```swift
/// Preserves original string, exposes parsed range for comparison.
/// Audit rules compare ranges, not points — fires only when violation
/// is certain across all plausible values.
///
/// Tolerances:
///   ABT = ±5 years (genealogists mean "roughly this decade")
///   EST = ±10 years (genealogists mean "I really don't know")
///   CAL = ±1 year (derived from arithmetic on other records — typically precise)
///   BEF/AFT = unbounded on one side
///   BET = explicit range
///   Exact = ±0
///   yearOnly = ±0 for year arithmetic ("1887" means "sometime in 1887",
///              semantically year-bounded, but ±0 is correct for audit
///              comparisons which operate at year granularity)
struct GenealogicalDate: Codable, Hashable {
    let original: String                // "ABT 1887", "1 JAN 1887", "BET 1885 AND 1890"
    let earliest: Int?                  // Earliest possible year (nil = unbounded)
    let latest: Int?                    // Latest possible year (nil = unbounded)
    let isApproximate: Bool
    let qualifier: DateQualifier

    var bestYear: Int? {
        switch (earliest, latest) {
        case let (e?, l?): return (e + l) / 2
        case let (e?, nil): return e
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    init(parsing raw: String) { ... }
}

enum DateQualifier: String, Codable {
    case exact          // "1 JAN 1887"      → ±0
    case about          // "ABT 1887"        → ±5
    case before         // "BEF 1890"        → (nil, 1890)
    case after          // "AFT 1880"        → (1880, nil)
    case between        // "BET 1885 AND 1890" → (1885, 1890)
    case estimated      // "EST 1887"        → ±10
    case calculated     // "CAL 1887"        → ±1 (derived from arithmetic, typically precise)
    case yearOnly       // "1887"            → ±0 (year-bounded; see tolerance notes)
}
```

### 5.5 FieldSource, Transaction, and FieldChange

```swift
struct FieldSource: Codable, Hashable {
    let origin: SourceOrigin
    let raw: String                     // Original value as received
    let addedAt: Date
}

/// Source origin as a struct with static constants — no hybrid-enum ambiguity.
/// Adding a new source is one line. No schema migration. No Hashable trap.
struct SourceOrigin: Codable, Hashable, Sendable {
    let identifier: String

    static let gedcom = SourceOrigin(identifier: "gedcom")
    static let wikitree = SourceOrigin(identifier: "wikitree")
    static let freebmd = SourceOrigin(identifier: "freebmd")
    static let freecen = SourceOrigin(identifier: "freecen")
    static let freereg = SourceOrigin(identifier: "freereg")
    static let familysearch = SourceOrigin(identifier: "familysearch")
    static let cwgc = SourceOrigin(identifier: "cwgc")
    static let manual = SourceOrigin(identifier: "manual")
    // Future: static let findmypast = SourceOrigin(identifier: "findmypast")
}

/// First-class transaction — groups related changes for atomic undo.
/// Stored in the `transactions` SQLite table.
struct Transaction: Codable, Identifiable {
    let id: UUID
    let kind: TransactionKind
    let undoStrategy: UndoStrategy      // How to reverse this transaction
    let startedAt: Date
    let completedAt: Date
    let changeCount: Int                // Denormalised for quick display
    let profileCount: Int               // Profiles affected (for import)

    // Summary is COMPUTED at display time from kind + counts — not stored.
    // Avoids stale strings when locale or format changes.
    var summary: String {
        switch kind {
        case .importGEDCOM(let path):
            return "Imported \(URL(fileURLWithPath: path).lastPathComponent) (\(profileCount) profiles)"
        case .refreshWikiTree:
            return "WikiTree refresh (\(changeCount) changes)"
        case .manualEdit:
            return "Manual edit (\(changeCount) fields)"
        case .resolveDispute(let field, _):
            return "Resolved \(field.rawValue) dispute"
        case .undo(let txID):
            return "Undo (transaction \(txID.uuidString.prefix(8)))"
        }
    }
}

enum TransactionKind: Codable {
    case importGEDCOM(path: String)
    case refreshWikiTree
    case manualEdit
    case resolveDispute(field: ProfileField, profileID: String)
    case undo(ofTransactionID: UUID)    // Undo is itself a transaction
    // Post-MVP: .enrichmentRun, .factApproved, .sourceContributed, .mergeProfiles
}

/// How to reverse a transaction — import vs everything else.
enum UndoStrategy: String, Codable {
    case structural     // Import: delete all entities created by this transaction
    case replay         // Edit/refresh/resolve: reverse each FieldChange's newValue → oldValue
}

// Derived from TransactionKind:
//   .importGEDCOM → .structural
//   everything else → .replay

/// Individual entity change — always belongs to a Transaction.
/// Covers both profile fields AND relationship changes.
struct FieldChange: Codable, Identifiable {
    let id: UUID
    let transactionID: UUID             // FK to Transaction
    let entityID: String                // Profile ID or Relationship UUID string
    let entityKind: EntityKind
    let field: ChangeField              // Type-safe across both entity kinds
    let oldValue: String?
    let newValue: String
    let source: SourceOrigin
    let reason: String?
    // No timestamp — use Transaction.completedAt + ordering within transaction
}

enum EntityKind: String, Codable {
    case profile
    case relationship
}

/// Separate field enums per entity kind — no mixing.
enum ChangeField: Codable, Hashable {
    case profile(ProfileField)
    case relationship(RelationshipField)
}

enum RelationshipField: String, Codable {
    case marriageDate, divorceDate, subtype, role
}

enum Gender: String, Codable {
    case male, female, unknown
}
```

**Transaction design notes:**
- **Import creates one Transaction** (kind `.importGEDCOM`, undoStrategy `.structural`). No individual FieldChange rows — provenance tracked via `field_sources`. Import undo deletes all entities created by this transaction.
- **Refresh/edit/resolve create one Transaction** (undoStrategy `.replay`) with N FieldChange rows. Undo reverses each change.
- **Undo is itself a Transaction** (kind `.undo`). Undoing an undo = redo. The system always knows what the last operation was.
- **Undo safety** (replay strategy): before reversing, check every affected field: is the current value still what this transaction produced? If modified since → dialog: "This operation has been built upon — undo would discard N later changes. Proceed?"
- **Undo safety** (structural strategy): check if any profiles created by this import have FieldChange rows from later transactions. If so → same dialog.
- **Undo persists across restarts.** Transactions live in SQLite. The undo stack is "transactions ordered by completedAt DESC" — always available.
- **Dispute resolution undo:** `FieldDispute.competingSources` is preserved in SQLite. Undoing a resolution restores the dispute with its original competing sources.
- **Ordering guarantee:** transactions are ordered by `completedAt`. Single-user `@MainActor` ensures no concurrent transactions.

### 5.6 Conflict Resolution

```swift
/// When sources disagree on a field value, the field is disputed
/// until the user resolves it. Preserves all competing sources
/// so undo can restore the dispute.
struct FieldDispute: Codable, Hashable {
    let field: ProfileField
    let reason: DisputeReason
    let competingSources: [FieldSource] // All sources, ordered by addedAt
    let detectedAt: Date
    var resolution: DisputeResolution?
}

/// Why the dispute was created — affects how the UI presents it.
enum DisputeReason: String, Codable {
    case noOverlap              // Date ranges don't overlap at all
    case approximateOverlap     // Both approximate, partial overlap — false precision risk
    case valueMismatch          // Non-date string values differ
}

enum DisputeResolution: Codable, Hashable {
    case accepted(FieldSource)  // User chose this source
    case manual(String)         // User entered their own value
    case deferred               // User chose to decide later
}
```

### 5.7 Data Merge Policy

**When a new source provides a value for a field that already has a value:**

**Date fields (GenealogicalDate):**

1. Parse both values as ranges
2. **If normalised ranges are identical:** add source, no dispute. Two sources agreeing is corroboration.
3. **If ranges are complementary (one unbounded, intersection produces new information):** auto-intersect. E.g. existing "AFT 1870" (1870, nil) + new "BEF 1890" (nil, 1890) → (1870, 1890). The sources don't contradict — they complement. Test: intersection bounds a previously unbounded side.
4. **If at least one source is exact or narrow (±0 or ±1) and ranges overlap:** auto-intersect. New source added to `sources[field]`. No dispute. Note: the original wider source is preserved in `sources[]` — the user can see the narrowing occurred.
5. **If both sources are approximate and overlap only partially:** dispute with reason `.approximateOverlap`. Auto-intersection would create false precision.
6. **If ranges don't overlap:** dispute with reason `.noOverlap`.

**Non-date fields (strings):**

1. Normalise both values: trim whitespace, collapse multiple spaces, case-insensitive compare
2. **If normalised values match:** add source, no dispute
3. **If values differ:** field becomes **disputed**
4. **Known equivalences:** "Robert"/"Bob", "London, England"/"London, UK" are common false disputes. For MVP, these are disputes the user resolves. Post-MVP: equivalence learning (user marks two values as equivalent, system remembers) and location gazetteer normalisation.

**Resolution options:** accept one source, enter manual value, or defer.

**Last-writer-wins is never used.** The losing value is always preserved in `sources`.

**Audit during disputes:** When a field is disputed (e.g. birthDate has two non-overlapping ranges), audit rules use the **union range** (earliest of all sources' earliest, latest of all sources' latest). This is conservative — it may suppress real errors, but it never fires false positives on disputed data. When the user resolves the dispute, audit re-runs with the resolved value.

### 5.8 Relationships

```swift
struct Relationship: Codable, Hashable, Identifiable {
    let id: UUID                        // Required: FieldChange.entityID references this for relationship changes
    let from: String                    // Profile ID
    let to: String                      // Profile ID
    let type: RelationshipType
    let role: ParentRole?               // For parent relationships: father/mother/unspecified
    let subtype: RelationshipSubtype
    let marriageDate: GenealogicalDate? // For spouse relationships
    let divorceDate: GenealogicalDate?  // For spouse relationships
}

enum RelationshipType: String, Codable {
    case parent     // from is parent of to
    case spouse
    // No sibling — derived from shared parents
}

enum ParentRole: String, Codable {
    case father
    case mother
    case unspecified    // When GEDCOM doesn't distinguish
}

enum RelationshipSubtype: String, Codable {
    case biological
    case adoptive
    case step
    case unknown        // Default when GEDCOM doesn't specify PEDI tag
}
```

**Design notes:**
- **Siblings derived, not stored.** Two people are siblings if they share a parent. No sibling edges.
- **Parent role (father/mother/unspecified)** stored on the relationship — many audit and display decisions need gendered parenthood. **GEDCOM derivation:** parser reads FAM record HUSB/WIFE tags. Parent appearing as HUSB → `.father`, WIFE → `.mother`. Falls back to parent profile's gender field. Falls back to `.unspecified`.
- **Subtypes affect audit:** step-parents don't fire `parentAgeGap`. Adoptive relationships may have different temporal constraints.
- **Marriage/divorce dates on spouse edges:** each spouse relationship independently auditable for `noMarriageAfterDeath` across remarriages.

### 5.9 Storage Schema — SQLite via GRDB

```
SQLite database per project:
  ~/Library/Application Support/AncestorResearch/projects/{uuid}.sqlite

Tables:
  project_meta      — name, source, created_at, last_refreshed
  profiles          — one row per person, FK created_by_transaction_id
  relationships     — one row per edge, FK created_by_transaction_id
  field_sources     — multiple rows per entity×field, FK created_by_transaction_id
  transactions      — first-class operation log (import, refresh, edit, undo)
  field_changes     — audit trail, FK transaction_id, append-only
  field_disputes    — unresolved conflicts, FK created_by_transaction_id
```

**`created_by_transaction_id` on profiles, relationships, field_sources, field_disputes** enables structural undo: "delete everything this import created" is a single query per table. Also enables the undo safety check: "do any profiles from this import have field_changes from later transactions?"

**Snapshot population:** on project load, each Profile is populated by eagerly joining `profiles` + `field_sources` + `field_disputes`. At 10k profiles × ~2 sources per field, this is ~140k rows — fast in SQLite but the join pattern should be optimised (single query with GROUP BY, not N+1).

### 5.10 Export and Backup Strategy

**Two export paths with different guarantees:**

| Format | Purpose | Fidelity |
|--------|---------|----------|
| **SQLite file copy** | Backup, restore, share between Ancestor Research users | **Lossless.** The project IS the `.sqlite` file. Copy it. All disputes, history, transactions, sources preserved. |
| **GEDCOM export** | Interop with other genealogy tools (Ancestry, MacFamilyTree, etc.) | **Lossy.** Standard GEDCOM 5.5.1 only. App-specific data dropped with log. |

**GEDCOM export — what is preserved:**
- All INDI records (names, dates, places, gender)
- All FAM records (relationships, marriage dates)
- PEDI tags (biological/adoptive/step)
- Standard date formats (all `DateQualifier` cases)
- Character encoding: always UTF-8

**GEDCOM export — what is dropped (with log):**
- Disputes, resolution history — no GEDCOM representation
- Source provenance beyond the first source per field
- Audit trail / transaction history
- Comments (NOTE nodes) from original import — not preserved in MVP
- Non-standard tags from Ancestry/MyHeritage

**GEDCOM round-trip test:** semantic diff. Parse both files into `FamilyGraphSnapshot`, compare graph structures. Equivalence defined as: same profiles, same relationships, same date values (original strings). Not textual identity — line ordering and whitespace don't matter.

**Warning to users:** GEDCOM export is for sharing, not backup. Re-importing your own export loses dispute history and source provenance. Use "Export Project" (SQLite copy) for backup.

---

## 6. Audit Rules

Ported from `agent/rules.py`. **Swift is the sole source of truth** — Python `rules.py` will be deleted when the enrichment pipeline migrates post-MVP.

### 6.1 Two Severity Tiers

Without a warning tier, most temporal rules rarely fire on real data (virtually no genealogical dates are exact). Two tiers prevent the audit from appearing uselessly clean:

- **Error (certain violation):** fires when even the most generous interpretation of date ranges is impossible. Uses range arithmetic (`earliest`/`latest`).
- **Warning (probable violation):** fires when the likely interpretation is violated. Uses `bestYear` midpoints. Users see both but understand the difference.

**When a required field is missing:** temporal rules **silently skip** (correct — can't check what doesn't exist). This is documented per-rule in the "missing field" column below.

**Disputed fields:** audit uses the **union range** of all competing sources (see §5.7). Conservative — may suppress errors, never fires false positives.

### 6.2 Formal Rule Table

| Rule | Invariant | Error fire condition | Warning fire condition | Missing field behaviour | Worked example |
|------|-----------|---------------------|----------------------|------------------------|----------------|
| `birthBeforeDeath` | birth ≤ death | `birth.earliest > death.latest` | `birth.bestYear > death.bestYear` | Skip if either missing | Birth "AFT 1920" (e=1920), Death "BEF 1668" (l=1668): 1920>1668 → **ERROR** |
| `parentAgeGap` | biological parent born ≥14y before child | `parent.latest + 14 > child.earliest` | `parent.bestYear + 14 > child.bestYear` | Skip if either missing. Skip if subtype ≠ biological. | Parent "1874" (l=1874), Child "1887" (e=1887): 1874+14=1888>1887 → **ERROR** (gap is 13, certain violation). Parent "1870" (l=1870): 1870+14=1884<1887 → ok |
| `marriageAge` | married ≥16y after birth | `marriage.earliest < birth.latest + 16` | `marriage.bestYear < birth.bestYear + 16` | Skip if either missing | Birth "ABT 1870" (l=1875), Marriage "1884": 1884<1891 → ok. But bestYear=1870, 1884<1886 → ok. Marriage "1880": 1880<1886 → **WARNING** |
| `lifespan` | death − birth ≤ 110 | `death.earliest - birth.latest > 110` | `death.bestYear - birth.bestYear > 110` | Skip if either missing | Birth "1800" (l=1800), Death "AFT 1920" (e=1920): 120>110 → **ERROR** |
| `noMarriageAfterDeath` | marriage ≤ death (per spouse edge) | `marriage.earliest > death.latest` | `marriage.bestYear > death.bestYear` | Skip if either missing | Marriage "1890", Death "BEF 1885" (l=1885): 1890>1885 → **ERROR** |
| `missingParents` | has ≥1 parent link | No parent edges | — | Always evaluable | — |
| `missingBirthDate` | has birth date | `birthDate == nil` | — | Always evaluable | — |
| `missingDeathDate` | has death date | `deathDate == nil` | — | Info severity — may be living | — |
| `missingBirthLocation` | has birth location | `birthLocation == nil` | — | Always evaluable | — |
| `missingBio` | has biography | `bio` is nil or empty | — | Always evaluable | — |
| `duplicateDetection` | unique person | See §6.3 | — | Skip if name missing | — |
| `completenessScore` | N/A | See §4.3 `ProfileCompleteness` | — | Always evaluable | — |

### 6.3 Duplicate Detection

`duplicateDetection` is a **candidate suggestion tool**, not a strict rule. It produces "candidate duplicates" with a similarity score; the user decides whether to merge.

**Matching algorithm:**
1. **Normalise names:** trim, collapse whitespace, uppercase
2. **Nickname expansion:** check against a lookup table (Bill↔William, Peggy↔Margaret, Bob↔Robert, etc. — ported from Python `rules.py` `name_similarity_score`)
3. **Fuzzy surname matching:** handle Caldwell/Cauldwell (AU↔A swap), Smyth/Smith, Katherine/Catherine — single character difference = candidate
4. **Birth year overlap:** both profiles' `GenealogicalDate` ranges must overlap
5. **Similarity score:** 0.0–1.0 combining name similarity + date overlap + location match
6. **Threshold:** score ≥ 0.7 = candidate duplicate. Presented as a merge suggestion, not an error.
7. **Maiden vs married name:** compare against `lastName` (LastNameAtBirth). Married name comparison is post-MVP.

### 6.4 AuditRule Architecture

**One struct per rule, protocol-based.** Each rule is independently testable, lives in its own file, and plugs into a registry. Post-MVP user-defined rules use the same protocol.

```swift
/// Protocol — all rules (built-in and future user-defined) conform to this.
protocol AuditRuleDefinition {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }         // Invariant in plain English
    var fireCondition: String { get }       // When this raises an error
    var warningCondition: String? { get }   // When this raises a warning
    var workedExample: String { get }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [AuditResult]
}

/// Each built-in rule is its own struct:
struct BirthBeforeDeathRule: AuditRuleDefinition { ... }
struct ParentAgeGapRule: AuditRuleDefinition { ... }
struct MarriageAgeRule: AuditRuleDefinition { ... }
// ... one file per rule

/// Registry — the audit engine iterates this.
enum AuditRules {
    static let builtIn: [AuditRuleDefinition] = [
        BirthBeforeDeathRule(),
        ParentAgeGapRule(),
        MarriageAgeRule(),
        LifespanRule(),
        NoMarriageAfterDeathRule(),
        MissingParentsRule(),
        MissingBirthDateRule(),
        MissingDeathDateRule(),
        MissingBirthLocationRule(),
        MissingBioRule(),
        DuplicateDetectionRule(),
        CompletenessScoreRule(),
    ]
}
```

**Unbounded range handling:** When a date has `earliest` or `latest` as nil (e.g. "AFT 1870" has latest=nil), temporal rules:
- **Error tier:** skip — can't establish certain violation without both bounds. This applies to both "missing field" (nil date) AND "partially bounded" (date with one nil bound). If either operand in the fire condition formula is nil, the error tier does not fire.
- **Warning tier:** use `bestYear` if available, skip if `bestYear` is also nil
- Each rule struct guards against nil arithmetic in its `evaluate()` method
- Documented in each rule's `fireCondition` text shown in Settings

Displayed read-only in Settings (`AuditRulesView`) with invariant, fire condition, warning condition, and worked example.

---

## 7. WikiTree API Compliance

Per [WikiTree App Policies](https://www.wikitree.com/wiki/Help:App_Policies):

- **`appId=AncestorResearch`** on all API calls
- **Rate limits:** 200/min, 4,000/hour — use `getPeople` batch endpoint
- **Images:** 75px thumbnails only, linking to WikiTree profile page
- **Bios:** not displayed on external websites (desktop app for personal use is acceptable)
- **Refresh:** user-initiated only via button, no background sync

---

## 8. Project Structure

```
ancestor/
├── <existing Python unchanged>
│
└── AncestorApp/
    ├── Package.swift                      # GRDB dependency
    ├── AncestorApp/
    │   ├── AncestorApp.swift              # @main, WindowGroup
    │   ├── AppConstants.swift             # Display name, appId, version
    │   │
    │   ├── Models/
    │   │   ├── Project.swift              # Top-level container
    │   │   ├── FamilyGraphSnapshot.swift  # Immutable graph snapshot (Sendable)
    │   │   ├── Profile.swift              # Person node with sources + history + disputes
    │   │   ├── Relationship.swift         # Graph edge with role/subtype/dates
    │   │   ├── GenealogicalDate.swift     # Range-based date with qualifier
    │   │   ├── FieldTypes.swift           # ProfileField, FieldSource, FieldChange, FieldDispute
    │   │   ├── AuditResult.swift          # Error/warning from audit
    │   │   └── AuditRule.swift            # Rule definitions with invariant/fire/example
    │   │
    │   ├── Services/
    │   │   ├── ProjectStore.swift         # @MainActor, owns snapshot, writes to DB, undo
    │   │   ├── ProjectDatabase.swift      # GRDB schema and queries
    │   │   ├── GEDCOMParser.swift         # Import .ged → FamilyGraphSnapshot
    │   │   ├── GEDCOMExporter.swift       # Export FamilyGraphSnapshot → .ged
    │   │   ├── WikiTreeClient.swift       # Read-only API client (async/await)
    │   │   ├── AuditEngine.swift          # Run rules against snapshot
    │   │   ├── MergeEngine.swift          # Data merge policy, conflict detection
    │   │   └── DiffEngine.swift           # Compare two snapshots, produce visual diff
    │   │
    │   ├── Views/
    │   │   ├── ContentView.swift          # NavigationSplitView shell
    │   │   ├── ProjectPicker/
    │   │   │   ├── ProjectPickerView.swift
    │   │   │   └── NewProjectView.swift
    │   │   ├── Sidebar/
    │   │   │   └── SidebarView.swift
    │   │   ├── Tree/
    │   │   │   ├── TreeGraphView.swift     # Hierarchical layout (pedigree/descendant)
    │   │   │   ├── ProfileDetailView.swift # Inspector with source badges
    │   │   │   └── ProfileHistoryView.swift # Audit trail timeline
    │   │   ├── Diff/
    │   │   │   └── TreeDiffView.swift      # Visual diff after refresh
    │   │   ├── Conflicts/
    │   │   │   └── ConflictResolutionView.swift # Resolve disputed fields
    │   │   ├── Audit/
    │   │   │   ├── AuditView.swift
    │   │   │   └── GapsView.swift
    │   │   └── Settings/
    │   │       ├── SettingsView.swift
    │   │       └── AuditRulesView.swift    # Invariant + fire condition + example per rule
    │   │
    │   └── ViewModels/
    │       ├── AppState.swift             # Root @Observable — current project
    │       ├── ProjectViewModel.swift     # Project CRUD, switching
    │       ├── TreeViewModel.swift        # Graph layout, selection, zoom
    │       ├── DiffViewModel.swift        # Refresh diffing state
    │       ├── ConflictViewModel.swift    # Dispute resolution state
    │       └── AuditViewModel.swift       # Run audit, filter results
    │
    └── Tests/
        └── AncestorAppTests/
            ├── GEDCOMParserTests.swift
            ├── GEDCOMRoundTripTests.swift  # Semantic diff: parse both, compare graphs
            ├── GenealogicalDateTests.swift  # All qualifiers, tolerances, edge cases
            ├── AuditEngineTests.swift      # Every rule: error tier + warning tier + missing field + subtype exemptions
            ├── MergeEngineTests.swift       # Overlap, partial overlap, disjoint, approximate+approximate
            ├── DuplicateCandidateTests.swift # Similarity scores, nicknames, fuzzy surname
            ├── TransactionTests.swift       # Grouped undo, undo safety, undo-of-undo
            ├── FamilyGraphSnapshotTests.swift # Traversal, sibling derivation, completeness cache
            ├── ProfileTests.swift
            ├── RefreshIdempotenceTests.swift # No changes → no field_changes
            ├── DisputePersistenceTests.swift # Survive save/reload
            └── WikiTreeClientTests.swift
```

---

## 9. Key Files to Reference (Python originals)

| Swift Target | Python Source | Purpose |
|-------------|-------------|---------|
| `AuditEngine.swift` | `agent/rules.py` (lines 24-78) | Hard rules — **port then delete Python version post-MVP** |
| `AuditEngine.swift` | `agent/audit.py` | Audit orchestration, completeness, duplicates |
| `FamilyGraphSnapshot.swift` | `wikitree/twin.py` | Graph structure, traversal methods |
| `WikiTreeClient.swift` | `wikitree/api.py` | API endpoints, auth flow, rate limiting |
| `Profile.swift` | `wikitree/twin.py` node attributes | Profile fields and structure |

---

## 10. Milestones

### M1: Data Model + Storage
- Xcode project with GRDB dependency
- All model types: `Project`, `FamilyGraphSnapshot` (with completeness + sibling caches), `Profile`, `GenealogicalDate`, `ProfileField`, `Relationship` (with `ParentRole`, `RelationshipSubtype`), `FieldSource`, `Transaction`, `FieldChange`, `FieldDispute`, `AuditResult`, audit rule protocol
- `ProjectDatabase` — GRDB schema (all tables including `transactions`)
- `ProjectStore` — `@MainActor`, transaction-based mutations, snapshot management, undo with safety checks
- `GenealogicalDate` parser with full GEDCOM qualifier support and tolerance tests
- `ContentView`, `ProjectPickerView`, `NewProjectView`

### M2: GEDCOM Import + Export
- `GEDCOMParser` — parse INDI, FAM, names, dates (→ `GenealogicalDate`), places, relationships (with PEDI tags → subtype, parent role)
- Source provenance: all fields tagged `SourceOrigin.gedcom` via `field_sources` table
- Import creates one `Transaction` (kind: `.importGEDCOM`). No individual `FieldChange` rows on initial import — provenance tracked via `field_sources`, changes tracked from M4 onwards
- `GEDCOMExporter` — export snapshot back to `.ged`
- **Round-trip test:** semantic diff (parse both files → compare graph structures). Lossless for standard data; explicit logged drops for NOTE, non-standard tags, app-specific fields
- Tests: multiple GEDCOM sources (WikiTree, Ancestry), edge cases, date parsing, round-trip

### M3: Tree Visualisation
- `TreeGraphView` — **hierarchical layout** (Reingold-Tilford for pedigree, Sugiyama for descendants with spouses). Not force-directed.
- Nodes coloured by completeness. Disputed fields flagged visually.
- Pan, zoom, node selection
- `ProfileDetailView` — fields with source badges, dispute indicators
- `ProfileHistoryView` — audit trail timeline with undo button
- `SidebarView` with tree stats

### M4: WikiTree API + Refresh Diffing
- `WikiTreeClient` — login, watchlist, batch profiles, relatives
- `appId=AncestorResearch`, rate limiting
- Parent role mapping from WikiTree gender data
- `MergeEngine` — apply data merge policy (range intersection or dispute)
- `DiffEngine` — compare old vs new snapshot
- `TreeDiffView` — visual diff before committing refresh
- `ConflictResolutionView` — resolve disputed fields
- Tests: mock API, diff generation, merge conflicts

### M5: Audit Engine
- `AuditEngine` — all 12 rules with **two tiers**: error (range arithmetic) + warning (bestYear midpoints)
- Biological-only gate on `parentAgeGap` (check `RelationshipSubtype`)
- Per-spouse-edge checking for `noMarriageAfterDeath`
- Disputed fields: audit uses union range (see §5.7)
- Missing fields: temporal rules silently skip (documented per-rule)
- `duplicateDetection` as candidate suggestion tool with similarity score (see §6.3)
- `AuditView`, `GapsView`
- `AuditRulesView` — invariant, fire condition, warning condition, worked example per rule
- Completeness scores on tree nodes (from snapshot cache)
- Tests: every rule — error tier, warning tier, missing field behaviour, subtype exemptions, disputed field handling

### M6: Polish + App Store
- Liquid Glass styling pass
- Error handling, empty states, loading indicators
- Undo integrated throughout (menu item, keyboard shortcut)
- App icon and metadata
- Fastlane setup
- Archive and submit to reserve "Ancestor Research"

---

## 10.5 Navigation Architecture

The app has many distinct views. Not all belong in the sidebar — that would be crowded. Navigation is layered:

| Level | Views | Pattern |
|-------|-------|---------|
| **Window** | `ProjectPickerView` | Shown when no project is open. Replaced by main view on project open. |
| **Sidebar** | Tree, Audit, Gaps, Settings | Primary navigation. Always visible. 4 items max. |
| **Inspector** | `ProfileDetailView`, `ProfileHistoryView` | Right panel, appears on node selection in tree. |
| **Sheet/Modal** | `NewProjectView`, `ConflictResolutionView`, `TreeDiffView` | Presented modally for focused tasks. |
| **Settings tab** | `AuditRulesView`, WikiTree credentials | Tabs within Settings. |

---

## 11. Verification

| # | Test | Expected Result |
|---|------|----------------|
| 1 | **Projects** | Create → appears in picker → switch → delete |
| 2 | **GEDCOM import** | Drop `.ged` → profiles in tree → detail shows data with "GEDCOM" badges |
| 3 | **GEDCOM round-trip** | Import → export → diff original vs exported → lossless or explicit logged conversions |
| 4 | **WikiTree sync** | Enter creds → Connect → profiles load → `wtID` populated |
| 5 | **Refresh diff** | Refresh → diff view shows changes → user accepts → graph updated |
| 6 | **Conflict resolution** | Two sources disagree → field flagged disputed → user resolves in UI → dispute cleared |
| 7 | **Tree graph** | 450 nodes render smoothly → hierarchical layout → pan/zoom → completeness colouring |
| 8 | **Audit** | Run → errors (e.g. "birth after death") → gaps listed → rules visible in Settings with examples |
| 9 | **Source tracking** | Import GEDCOM → all "GEDCOM" → sync WikiTree → overlapping fields show both sources |
| 10 | **Audit trail** | Import → history entries → refresh changes a field → old+new recorded → undo reverses |
| 11 | **Undo** | Change a field → undo → previous value restored → undo recorded as its own transaction |
| 12 | **Undo safety** | Import → edit 3 profiles → undo import → dialog warns "3 later changes would be lost" |
| 13 | **Undo across restart** | Edit → quit → relaunch → undo still available (transactions in SQLite) |
| 14 | **Persistence** | Quit → relaunch → project loads from SQLite without re-importing |
| 15 | **Refresh idempotence** | Refresh twice with no server-side changes → no FieldChange entries generated |
| 16 | **Dispute persistence** | Create dispute → quit → relaunch → dispute still present |

---

## 12. Critical Analysis

### Strengths
- **Snapshot concurrency model** — natively Sendable, undo for free, clean SwiftUI consumption
- **Range-based dates** — prevents false positive audit errors on approximate dates
- **Formal audit rule table** — invariants + fire conditions + examples eliminate ambiguity
- **Multi-source provenance** — corroboration preserved, not just last-writer
- **Conflict resolution from day one** — multi-source means multi-source disagreement. Handling it now prevents painful retrofit
- **GEDCOM round-trip** — validates the data model. If it round-trips, the model is sound
- **Swift owns rules** — no two-engine drift. Single source of truth
- **SQLite via GRDB** — transactional, incremental, scalable. No JSON bottleneck
- **Hierarchical layout** — matches genealogical conventions, much better than force-directed for family trees

### Risks
1. **Hierarchical graph layout is hard** — Reingold-Tilford and Sugiyama are non-trivial algorithms. May need a library or significant implementation effort. Most likely milestone to overrun.
2. **Liquid Glass is brand new** — WWDC25 APIs may have bugs. Mitigation: standard SwiftUI first, Liquid Glass pass at M6.
3. **GEDCOM parsing edge cases** — real exports are messy. `GenealogicalDate` parser is critical path. Test with actual exports from WikiTree and Ancestry early in M2.
4. **GRDB learning curve** — well-maintained but new dependency. Schema design needs to support the snapshot + transaction pattern efficiently.
5. **Conflict resolution UX** — `TreeDiffView` and `ConflictResolutionView` are the trust-building views. They deserve design attention (mockups, UX flow) disproportionate to their code complexity.
6. **FamilySearch assumption** — post-MVP roadmap assumes FS will approve the app. An email to FS DevRel is free insurance. Decision: build first, but this risk is acknowledged.

### Known Ceilings (acceptable for MVP, document for post-MVP)
- **Snapshot copy cost** — at 10k profiles, snapshot rebuild copies entire dictionary. Persistent data structures (HAMT) would help at 100k+ but not needed now.
- **Transaction table growth** — unbounded over years of active use. Post-MVP: "compact history" operation that collapses old transactions into a baseline.
- **Location field disputes** — "London, England" vs "London, UK" will generate false disputes. Post-MVP: location gazetteer normalisation + user-defined equivalences.

---

## 13. Future Milestones (Post-MVP, out of scope)

- **FamilySearch OAuth** — token management, record hints, deep links
- **Python API server** — enrichment pipeline only (LLM, sources). Calls Swift for audit via IPC. Delete Python `rules.py`.
- **Leads & Facts UI** — SwiftData for flat data
- **Research pipeline** — SSE progress streaming
- **Source contribution** — write sources back to FamilySearch
- **Configurable audit rules** — enable/disable, adjust tolerances
- **Unresolved contradictions panel** — fields where sources disagree, separate from audit. Enrichment investigates these.
