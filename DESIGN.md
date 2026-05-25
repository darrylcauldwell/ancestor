# Ancestor Research — Detailed Design Specification

**App name:** Ancestor Research
**Internal codename:** AncestorApp (display name is a single `AppConstants.displayName` constant for easy renaming)
**Repo:** Same repo as existing Python backend (`/Users/darrylcauldwell/Development/ancestor/AncestorApp/`)
**Version:** MVP v1.0

---

## 1. Context

The genealogy research agent is currently CLI-only. FamilySearch API access was rejected for personal use — a proper macOS app qualifies for approval. Beyond unlocking FamilySearch, the app provides a proper UI for the research workflow: visualising the tree, spotting gaps, and reviewing findings.

This spec describes the **end-state product vision** — the complete product as it should exist when all milestones are shipped. Timeline is not a constraint — the goal is to build the right thing so the foundation is still sound in two years when enrichment, FamilySearch, leads, facts, and the research pipeline are layered on. Implementation is phased via milestones (§10), but the data model and architecture are designed for the full vision from day one.

### 1.5 Differentiation — Why This Product Exists

Existing genealogy software treats research as data entry. You type facts into boxes, the software stores them, and you get a tree diagram. The hard part of genealogy — the uncertainty, the dead ends, the tentative connections, the months-long investigations — happens outside the software, in notebooks and spreadsheets and the researcher's head.

**This product treats genealogy as research, not data entry.** Three differences make this concrete:

1. **Tentative claims have a first-class home.** Hypotheses are not workarounds or to-do items — they're structured claims with evidence, confidence levels, and promotion/dismissal flows. The tree itself shows uncertainty visually: dashed lines for hypothetical relationships, ghost nodes for hypothetical people, italic text for tentative values. No mainstream genealogy software has this.

2. **Session-to-session continuity is automatic.** The workbench remembers what you were investigating, what questions are open, what sources you've already checked, and where you left off. The session resume screen means you never start a research session by trying to remember where you were. Research happens in stolen hours over months — the product respects that rhythm.

3. **Evidence quality is tracked, not assumed.** Every fact knows where it came from (oral history, family document, official record, estimate), how confident the user is in it, and whether it's corroborated by multiple sources. The merge policy makes explicit rules for what happens when sources disagree, rather than silently overwriting.

Together, these mean users spend less time reconstructing what they were doing and more time figuring things out. The product's value proposition is not "a better tree editor" — it's "the only genealogy tool where your thinking is preserved alongside your data."

**Who this is for:** Serious hobbyist genealogists who research actively over years. People who have a stack of census transcripts, a folder of family photos, and a notebook of questions they haven't answered yet. The product replaces both their tree software and their research journal.

**Who this is not for:** Casual users who want to quickly see a family tree diagram (they should use Ancestry.com). Professional genealogists who need client-facing case management (different product category). Users who need real-time collaboration with relatives (this is single-user by design — see §7.14).

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
| 19 | **Manual tree entry** | Start a tree from scratch — add/edit people and relationships without importing from any external source |
| 20 | **Research Workbench** | Sidebar peer — focus sets, open questions, hypotheses, notes, and session log. Where research-in-progress lives between actions |
| 21 | **Uncertainty layer** | Tree visualisation shows hypothetical relationships (dashed lines), hypothetical people (ghost nodes), and research indicators (questions, notes) |
| 22 | **Session resume** | On launch, shows what you were working on, what's still open, and offers to continue — the app remembers your research context |
| 23 | **Profile timeline** | Chronological life events view per profile — birth, baptism, censuses, marriage, death — with sources and workbench items inline |
| 24 | **Formal citations** | Structured source citations per field (not just origin tags) — repository, title, page, date accessed. Renders to standard genealogical citation format |
| 25 | **Keyboard-driven workflow** | Full keyboard navigation — Cmd+N add person, Cmd+Shift+F add family, arrow keys in tree, Cmd+F search, tab through forms |
| 26 | **Reports and narrative output** | Pedigree charts, family group sheets, narrative biographical summaries, research reports — the presentation layer that gives the tree a destination |

**Beyond end-state (platform extensions):** Leads, research pipeline, FamilySearch OAuth, Geni.com API, LLM investigation, Python API server, enrichment from external sources, configurable/user-defined audit rules, map view, mobile companion, multi-window, cloud sync. See §13.

---

## 4. Architecture

**Pure Swift** — no Python server dependency for MVP.

```
Ancestor Research (macOS SwiftUI, Liquid Glass)
  ├── Project Manager (create, switch, delete trees)
  ├── GEDCOM Parser + Exporter (Swift, custom)
  ├── WikiTree API Client (Swift, read-only)
  ├── SQLite (GRDB) per project
  │     ├── Immutable FamilyGraphSnapshot for views
  │     └── Research Workbench tables (focus, questions, hypotheses, notes, sessions)
  ├── Audit Engine (deterministic rules — Swift is source of truth)
  ├── Conflict Resolver (multi-source field disagreement)
  ├── Research Workbench (focus sets, open questions, hypotheses, notes, session log)
  └── Views: Project Picker, Tree Graph (with uncertainty layer),
             Profile Detail, Profile History, Tree Diff,
             Conflict Resolution, Audit, Gaps, Workbench, Settings
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
    let potentiallyLiving: Bool             // Heuristic: deathDate == nil AND (birthDate is nil OR birthDate.latest + 110 >= currentYear)
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
    var source: DataSource              // .gedcom(path) | .wikitree(email) | .manual
    var homePersonID: String?           // Anchor profile — the person whose tree this is.
                                        // Set during onboarding wizard or first manual add.
                                        // Tree views default to "ancestors of home person."
                                        // Can be changed in Settings.
    var createdAt: Date
    var lastRefreshed: Date?
}

enum DataSource: Codable {
    case gedcom(path: String)
    case wikitree(email: String)
    case manual                      // Started from scratch — no external source
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
    var attributes: PersonAttributes    // Three orthogonal axes: name status, life status, privacy

    var birthDate: GenealogicalDate?
    var birthLocation: String?
    var deathDate: GenealogicalDate?
    var deathLocation: String?
    var bio: String?

    var isDeleted: Bool                 // Soft delete — hidden from tree, preserved in DB. See §7.5.6.

    // Source provenance — multiple corroborating sources per field
    var sources: [ProfileField: [FieldSource]]

    // Conflict state — fields where sources disagree
    var disputes: [ProfileField: FieldDispute]

    // NOTE: completeness is NOT on Profile — it's on FamilyGraphSnapshot
    // (needs parent edge lookup). See §4.3 ProfileCompleteness.
    // NOTE: history is NOT on Profile — it's in the field_changes table,
    // queried via ProjectDatabase. Keeps Profile lightweight for snapshots.
}

/// Three orthogonal axes — a profile can be unknownName AND infantDeath AND livingPrivate
/// simultaneously. The previous single-pick PersonStatus enum forced false either/or choices.
struct PersonAttributes: Codable, Hashable {
    var nameStatus: NameStatus = .known     // Do we know who this person is?
    var lifeStatus: LifeStatus = .normal    // Any special life-event category?
    var privacy: Privacy = .normal          // Should this person's data be restricted?
}

enum NameStatus: String, Codable {
    case known              // Default — normal profile
    case unknown            // "The daughter who married a Smith" — display as "?"
    case placeholder        // Temporary name, will be replaced (e.g. sibling shortcut parents)
}

enum LifeStatus: String, Codable {
    case normal             // Default
    case infantDeath        // Died young, often unnamed — italic/muted display, exempt from completeness
    case stillborn          // Recorded for family completeness, exempt from most audit
}

enum Privacy: String, Codable {
    case normal             // Default — visible everywhere
    case livingPrivate      // Name withheld in export/sharing — display as "[Living]"
}

/// Gender: "unknown" = not yet recorded (distinct from "other" = recorded as non-binary/intersex).
/// For historical profiles, .unknown is the typical default. For modern profiles, .other covers
/// non-binary and intersex — genealogy records rarely need finer distinction.

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
    let citation: Citation?             // Formal citation, if available. See §5.12.
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
    static let manual = SourceOrigin(identifier: "manual")              // Generic fallback
    static let manualMemory = SourceOrigin(identifier: "manual.memory") // "I remember this" / oral history
    static let manualDocument = SourceOrigin(identifier: "manual.document") // Family bible, photo, letter
    static let manualRecord = SourceOrigin(identifier: "manual.record")   // Official document the user has
    static let manualEstimate = SourceOrigin(identifier: "manual.estimate") // Best guess / calculated
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
        case .addProfile:
            return "Added person"
        case .addFamily:
            return "Added family (\(profileCount) people)"
        case .addRelationship:
            return "Added relationship"
        case .removeRelationship:
            return "Removed relationship"
        case .softDelete:
            return "Removed person"
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
    case addProfile(profileID: String)              // Manual: created a new person
    case addFamily(profileIDs: [String])            // Manual: created a family group (parents + children + relationships)
    case addRelationship(relationshipID: UUID)       // Manual: linked two people
    case removeRelationship(relationshipID: UUID)    // Manual: unlinked two people
    case softDelete(profileIDs: [String])            // Manual: hid one or more profiles in a single transaction (reversible)
    case manualEdit                                  // Manual: edited existing fields
    case resolveDispute(field: ProfileField, profileID: String)
    case undo(ofTransactionID: UUID)    // Undo is itself a transaction
    // Post-MVP: .enrichmentRun, .factApproved, .sourceContributed, .mergeProfiles, .deleteProfile
}

/// How to reverse a transaction — import vs everything else.
enum UndoStrategy: String, Codable {
    case structural     // Import: delete all entities created by this transaction
    case replay         // Edit/refresh/resolve: reverse each FieldChange's newValue → oldValue
}

// Derived from TransactionKind:
//   .importGEDCOM, .addProfile, .addFamily, .addRelationship → .structural
//   .removeRelationship, .softDelete, .manualEdit, .refreshWikiTree, .resolveDispute, .undo → .replay

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
    case marriageDate, marriageLocation, divorceDate, subtype, role
}

enum Gender: String, Codable {
    case male, female, other, unknown   // "unknown" = not yet recorded (distinct from "other")
}
```

**Transaction design notes:**
- **Import creates one Transaction** (kind `.importGEDCOM`, undoStrategy `.structural`). No individual FieldChange rows — provenance tracked via `field_sources`. Import undo deletes all entities created by this transaction.
- **Add profile/relationship creates one Transaction** (kind `.addProfile`/`.addRelationship`, undoStrategy `.structural`). Undo deletes the entity. All fields tagged with specific manual source origin (`.manualMemory`, `.manualDocument`, `.manualRecord`, or `.manualEstimate`).
- **Add family creates one Transaction** (kind `.addFamily`, undoStrategy `.structural`). Creates multiple profiles + relationships atomically. Undo removes everything created. Used by onboarding wizard and family group entry.
- **Bulk soft-delete creates one Transaction** (kind `.softDelete(profileIDs:)`, undoStrategy `.replay`) carrying every affected profile ID. Sets `isDeleted = true` on each profile; relationships preserved but hidden. Undoing it restores all of them in a single operation, so a "remove this person and all their descendants" branch delete is one undoable unit.
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
    let marriageLocation: String?       // For spouse relationships — distinct from spouses' birth places
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
  project_meta      — name, source, home_person_id, created_at, last_refreshed
  profiles          — one row per person, FK created_by_transaction_id, is_deleted, attributes JSON
  relationships     — one row per edge, FK created_by_transaction_id, marriage_location
  field_sources     — multiple rows per entity×field, FK created_by_transaction_id
  transactions      — first-class operation log (import, refresh, edit, undo)
  field_changes     — audit trail, FK transaction_id, append-only
  field_disputes    — unresolved conflicts, FK created_by_transaction_id

  life_events       — one row per event, FK profile_id, FK created_by_transaction_id,
                      type, date, end_date, location, description, sources JSON, confidence

  -- Research Workbench (§5.11, §7.7)
  focus_sets        — id, title, profile_ids JSON, created_at, last_active_at
  open_questions    — id, text, profile_ids JSON, priority, status, tried_sources, promoted_from JSON,
                      created_at, resolved_at, resolution
  hypotheses        — id, claim JSON (keyed by claim_kind), confidence, reasoning,
                      supporting_evidence JSON, contradicting_evidence JSON, status,
                      created_at, resolved_at, dismissal_reason
  workbench_notes   — id, content, tag, attached_to JSON, created_at, updated_at
  workbench_notes_fts — FTS5 virtual table on workbench_notes.content for full-text search
  sessions          — id, started_at, ended_at, focus_set_id, denormalised counters, transaction_ids JSON
  research_goals    — id, title, description, status, progress, question_ids JSON,
                      hypothesis_ids JSON, focus_set_id, created_at, completed_at
  attachments       — id, filename, media_type, caption, date_taken, location_taken,
                      relative_path, attached_to JSON, added_at
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

### 5.11 Research Workbench Data Model

The workbench stores the user's research-in-progress — everything between "I noticed a gap" and "I committed a fact." Five entity types, all in the same per-project SQLite database.

```swift
// MARK: - Focus Set

/// A named working set of profiles the user is currently investigating.
/// Persists across sessions. Typically 3–10 profiles.
struct FocusSet: Codable, Identifiable {
    let id: UUID
    var title: String?                      // "Maternal grandmother's siblings", optional
    var profileIDs: [String]                // Pinned manually or auto-included from recent activity
    var createdAt: Date
    var lastActiveAt: Date
}

// MARK: - Open Question

/// A structured todo — something the user is trying to figure out.
/// The crucial field is triedSources: recording dead ends turns wasted
/// effort into useful information.
struct OpenQuestion: Codable, Identifiable {
    let id: UUID
    var text: String                        // "Who were William Land's parents?"
    var profileIDs: [String]                // Profiles this question relates to
    var priority: QuestionPriority
    var status: QuestionStatus
    var triedSources: String?               // "FreeBMD 1810-1820, nothing. Wirksworth parish 1815, no match."
    var promotedFrom: QuestionOrigin?       // Where this question came from
    var createdAt: Date
    var resolvedAt: Date?
    var resolution: String?                 // How it was answered, if resolved
}

enum QuestionPriority: String, Codable {
    case low, medium, high
}

enum QuestionStatus: String, Codable {
    case open, inProgress, blocked, resolved
}

/// Where a question originated — for provenance, not enforcement.
enum QuestionOrigin: Codable {
    case manual                             // User created it directly
    case fromAudit(ruleID: String)          // Promoted from an audit issue
    case fromGap(profileID: String, field: ProfileField) // Promoted from gaps view
    case fromResearch(hypothesisID: UUID)   // Spawned from a hypothesis investigation
}

// MARK: - Hypothesis

/// A tentative claim — something the user believes but hasn't committed as a fact.
/// The current data model has no representation for this; every claim is either
/// confirmed (in the tree) or absent. Real research lives in the middle.
struct Hypothesis: Codable, Identifiable {
    let id: UUID
    var claim: HypothesisClaim              // What is being claimed
    var confidence: HypothesisConfidence
    var reasoning: String                   // Why the user believes this
    var supportingEvidence: [String]         // Free-text list of supporting evidence
    var contradictingEvidence: [String]      // Free-text list of contradicting evidence
    var status: HypothesisStatus
    var createdAt: Date
    var resolvedAt: Date?
    var dismissalReason: String?            // If dismissed — preserved so the same claim isn't re-hypothesised
}

/// Four claim types cover the shapes of genealogical guessing.
enum HypothesisClaim: Codable {
    case relationship(fromID: String, toID: String, type: RelationshipType, role: ParentRole?)
        // "I think Thomas Land was the son of William Land"
    case fieldValue(profileID: String, field: ProfileField, value: String)
        // "Mary's birth year was probably 1812 not 1815"
    case identityMatch(profileID1: String, profileID2: String)
        // "The Thomas Land in 1851 Belper might be the same as the one in 1861 Heanor"
    case existence(description: String, relatedProfileIDs: [String])
        // "I think there was another sibling who died young — family bible mentions a James"
}

enum HypothesisConfidence: String, Codable {
    case speculation       // "Maybe" — just an idea worth tracking
    case working           // "Probably" — actively investigating, partial evidence
    case strong            // "Almost certain" — ready to promote to fact
}

enum HypothesisStatus: String, Codable {
    case active            // Under investigation
    case promoted          // Resolved → committed as fact in the tree
    case dismissed         // Resolved → rejected, with reason preserved
    case superseded        // Replaced by a better hypothesis
}

// MARK: - Workbench Note

/// Free-text markdown attached to anything — a profile, a relationship,
/// a hypothesis, a question, or just the project. Notes are where most
/// thinking starts; some of it later gets promoted to questions or hypotheses.
struct WorkbenchNote: Codable, Identifiable {
    let id: UUID
    var content: String                     // Markdown. Intra-tree links: [[Thomas Land]] → clickable
    var tag: NoteTag
    var attachedTo: NoteAttachment          // What this note is about
    var createdAt: Date
    var updatedAt: Date
}

enum NoteTag: String, Codable {
    case observation        // "Noticed that..."
    case todo               // "Need to check..."
    case insight            // "This means that..."
    case sourceLog          // "Searched FreeBMD for..."
    case meta               // Notes about the research process itself
}

enum NoteAttachment: Codable {
    case project                            // Project-level note
    case profile(id: String)
    case relationship(id: UUID)
    case hypothesis(id: UUID)
    case question(id: UUID)
}

// MARK: - Session

/// Auto-generated from transactions and Workbench activity.
/// A session starts when the app opens and ends after 30 minutes of closure.
struct ResearchSession: Codable, Identifiable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var focusSetID: UUID?                   // Which focus set was active (if any)
    var profilesAdded: Int                  // Denormalised for quick summary
    var profilesEdited: Int
    var disputesResolved: Int
    var hypothesesCreated: Int
    var hypothesesPromoted: Int
    var questionsCreated: Int
    var questionsResolved: Int
    var notesCreated: Int
    var transactionIDs: [UUID]              // All transactions in this session

    /// Plain-English summary, computed at display time.
    var summary: String {
        // "1 hour. Worked on Land family. Added 4 profiles, resolved 2 disputes,
        //  created 3 hypotheses (1 promoted to fact). Open: 2 new questions
        //  about William Land's parents."
        ...
    }
}
```

**Hypothesis promotion flow:**
1. User marks hypothesis confidence as `.strong`
2. "Promote to fact" button appears
3. On promote:
   - `.relationship` claim → creates Relationship via standard `addRelationship` transaction, with hypothesis ID recorded in `FieldChange.reason`
   - `.fieldValue` claim → applies value via `manualEdit` transaction, source origin set to the hypothesis's underlying evidence type
   - `.identityMatch` claim → triggers merge flow (§6.3 duplicate detection, but with user pre-confirmation)
   - `.existence` claim → creates profile via `addProfile` with data from the hypothesis description
4. Hypothesis status set to `.promoted`
5. The hypothesis record is preserved — the tree fact links back to the reasoning that produced it

**Hypothesis dismissal:** On dismiss, user enters reason ("Census confirms Thomas was born 1834, too late to be William's son"). Reason is preserved so the same claim isn't re-hypothesised in a future session. Dismissed hypotheses remain searchable.

**Design principle:** The workbench is purely a place for human thought. No AI involvement. Future research features (Field Researcher, Deep Research) integrate by contributing findings to the workbench, but the workbench itself doesn't generate, suggest, or analyse.

### 5.12 Citations

Source provenance (§5.5 `FieldSource`) tracks *where* a value came from. A citation formally describes the source so others can verify it. Citations are the difference between a personal hobby tree and a tree someone else can build on.

```swift
/// A formal genealogical citation, structured for rendering.
/// Based on Evidence Explained citation model (Mills).
/// Optional on FieldSource — not all sources have formal citations.
struct Citation: Codable, Hashable {
    var repository: String?             // "The National Archives", "Derbyshire Record Office"
    var collection: String?             // "FreeBMD Birth Index", "1851 Census of England and Wales"
    var title: String?                  // Document/record title
    var page: String?                   // "Volume 7b, page 213"
    var url: String?                    // For online sources
    var dateAccessed: Date?             // When the source was last consulted
    var notes: String?                  // Free text for anything that doesn't fit above

    /// Rendered citation string — standard genealogical format.
    /// "FreeBMD, Birth Index, Belper registration district, March quarter 1834,
    ///  volume 7b, page 213, accessed 25 Apr 2026."
    var formatted: String { ... }
}

/// Quality of evidence — maps to GEDCOM QUAY tag.
/// Stored alongside the citation, not on FieldSource (a source can exist without quality rating).
enum EvidenceQuality: Int, Codable {
    case unreliable = 0     // Questionable reliability (estimated, hearsay)
    case secondary = 1      // Secondary evidence (derivative, not original)
    case primary = 2        // Primary evidence (original record, participant)
    case direct = 3         // Direct, proven (multiple independent primary sources agree)
}
```

**Citation in GEDCOM export:** When exporting, citations render to standard GEDCOM `SOUR` + `PAGE` + `QUAY` tags. This is what makes the exported tree usable by other genealogists — they can see *exactly* where each fact came from and verify it independently.

**Citation entry UI:** In `AddPersonView` and `EditPersonView`, the source picker (§7.5.9) gains an expandable "Add citation details" section per field. Most manual-entry users won't fill this in initially — the source picker alone is sufficient. But users who have a birth certificate in hand can enter the full citation immediately. The citation fields auto-suggest from previously used repositories and collections.

**Citation in reports:** The report generator (§7.9) uses citations to produce footnotes and source lists. A narrative report without citations is a story; with citations, it's evidence.

### 5.13 Life Events — Time-Bounded Facts

Genealogy is fundamentally about people moving through time. Thomas Land was a framework knitter in Belper in 1851, a publican in Heanor in 1861, and a labourer in Sheffield in 1881. The current model captures birth/death/marriage as profile/relationship fields, but everything else — occupations, residences, census appearances, baptisms, military service — has no first-class home.

Without life events, census transcription mode (§7.5.4) captures point-in-time data that has nowhere to go: an occupation overwrites the previous one, a residence has no date range, and the timeline (§7.8) can only show the three lifecycle endpoints. **Life events are the most common kind of fact in genealogy after birth/marriage/death**, and the data model must support them from day one.

```swift
/// A first-class life event with date range, location, sources, and citations.
/// Stored in the `life_events` table — not derived, not embedded in bio text.
struct LifeEvent: Codable, Identifiable {
    let id: UUID
    let profileID: String               // The person this event belongs to
    let type: LifeEventType
    var date: GenealogicalDate?          // When (can be a range: "1851-1861")
    var endDate: GenealogicalDate?       // For duration events: residence, occupation, military
    var location: String?
    var description: String?             // "Framework knitter", "42 King Street", "Royal Navy"
    var sources: [FieldSource]           // With citations
    var confidence: FactConfidence       // User-asserted confidence (see §5.14)
    let createdByTransactionID: UUID
}

enum LifeEventType: String, Codable, CaseIterable {
    // Lifecycle (point-in-time)
    case baptism, burial, probate

    // Census (point-in-time, links to household)
    case census

    // Duration events (date → endDate range)
    case residence                       // Where they lived
    case occupation                      // What they did for work
    case education                       // Schooling
    case militaryService                 // Service periods
    case religion                        // Religious affiliation (can change)

    // Movement (point-in-time)
    case immigration, emigration

    // Other
    case other                           // Free text for anything that doesn't fit
}
```

**Relationship to Profile fields:** Birth and death remain on Profile (they're identity-defining, used by audit rules, and affect completeness scoring). Marriage remains on Relationship (it's a relationship attribute). All other life events use the `LifeEvent` model. This avoids the "occupation field that gets overwritten" problem — each occupation is its own event with its own date range.

**Census transcription integration:** Census mode in AddFamilyView (§7.5.4) creates `LifeEvent` records: one `census` event per person (with year, address, relationship to head), plus `occupation` and `residence` events with the census year as their date. Source auto-set to `.manualRecord` with census citation.

**Timeline integration:** The timeline view (§7.8) reads both Profile fields (birth, death) and `LifeEvent` records to produce a unified chronological view. Life events are the primary content of the timeline — they transform it from "three dots on a line" to "a story of a person."

**Merge policy for life events:** Life events don't conflict the way profile fields do. Two sources giving different occupations in the same year are not a dispute — they're different points in time (or a second job). Duplicate detection applies: if two life events have the same type, date, and location, they're likely the same event and the merge engine flags them for user review.

### 5.14 Fact Confidence

User-asserted confidence on committed facts. Distinct from hypothesis confidence (which is for uncommitted claims) and distinct from disputes (which are between sources). This is the user saying "I committed this, but I'm not fully sure."

```swift
/// How confident the user is in a committed fact.
/// Not auto-calculated — this is the user's own assessment.
enum FactConfidence: String, Codable {
    case tentative          // "Committed but watching" — needs more evidence
    case standard           // Default — no special assertion
    case wellEvidenced      // Multiple independent sources agree — high confidence
}
```

**Applied to:** `FieldSource` (per field on a profile) and `LifeEvent` (per event). Default is `.standard` — users only change it when they want to signal something.

**Visual treatment:**
- `.tentative` — subtle dashed underline on the value in the inspector. Tree node gains a small "~" indicator if any field is tentative. Purpose: the user can see at a glance which facts need strengthening.
- `.standard` — no special treatment (the default).
- `.wellEvidenced` — subtle checkmark indicator in the inspector. No tree-level indicator (well-evidenced is the goal, not the exception).

**Interaction with audit:** The sourcing integrity view (§M11) can filter by confidence — "show all tentative facts" is a natural research task. The Gaps view can frame tentative facts as "needs more evidence" alongside missing fields.

**Why this isn't just EvidenceQuality:** `EvidenceQuality` (§5.12) rates the *source* — primary, secondary, unreliable. `FactConfidence` rates the *user's overall assessment* of the committed value, which may integrate multiple sources, personal knowledge, and contextual reasoning that the source ratings alone don't capture.

### 5.15 Source Attachments

Genealogy is about evidence. The spec stores claims and URLs to evidence. A complete product stores the evidence itself — photos, scanned certificates, transcriptions, family documents.

```swift
/// A file attached to a profile, life event, or source.
/// Stored in the project's media directory alongside the SQLite file.
struct Attachment: Codable, Identifiable {
    let id: UUID
    var filename: String                    // Original filename
    var mediaType: AttachmentType
    var caption: String?                    // User description
    var dateTaken: Date?                    // From EXIF or user-entered
    var locationTaken: String?              // From EXIF or user-entered
    let relativePath: String               // Path relative to project media directory
    let attachedTo: AttachmentTarget
    let addedAt: Date
}

enum AttachmentType: String, Codable {
    case photo              // JPEG, HEIC, PNG — family photos, gravestones, buildings
    case document           // PDF — scanned certificates, wills, legal documents
    case transcription      // Plain text — transcribed record the user typed out
}

enum AttachmentTarget: Codable {
    case profile(id: String)                // Family photo, portrait
    case lifeEvent(id: UUID)                // Scan of the certificate that documents this event
    case fieldSource(entityID: String, field: ProfileField) // The actual evidence behind a specific fact
}
```

**Storage:** Per-project media directory: `~/Library/Application Support/AncestorResearch/projects/{uuid}/media/`. The SQLite database stores metadata and relative paths; actual files live alongside. Project export ("Export Project") bundles the SQLite file plus the media directory into a `.ancestor` archive (zip).

**Thumbnails:** Generated on import for gallery views. Stored in `{uuid}/thumbnails/`. Regenerated if missing.

**EXIF extraction:** On photo import, extract date and GPS location from EXIF metadata. Offer to auto-populate `dateTaken` and `locationTaken`. GPS coordinates reverse-geocoded to place name if possible.

**Viewer:** Photos display inline in the profile inspector and timeline. PDFs open in a built-in viewer (PDFKit). Transcriptions display as formatted text.

**GEDCOM export:** Attachments export as GEDCOM `OBJE` tags. GEDCOM 5.5.1 uses file references; GEDCOM 7.0 uses GEDZip (bundled archive with media). Both supported.

**Reports:** Photos included in narrative reports (§7.9.4) and family group sheets (§7.9.3). Document scans included as appendices in research reports (§7.9.5).

### 5.16 Research Goals

Higher-level than workbench questions — research goals organise the user's work over months and years. They're the answer to "where am I trying to get to?"

```swift
/// A long-term research objective that groups workbench items.
struct ResearchGoal: Codable, Identifiable {
    let id: UUID
    var title: String                       // "Trace maternal line to the 1700s"
    var description: String?                // Context, motivation
    var status: GoalStatus
    var progress: Int                       // 0-100, user-assessed (not auto-calculated)
    var questionIDs: [UUID]                 // Open questions in service of this goal
    var hypothesisIDs: [UUID]               // Hypotheses related to this goal
    var focusSetID: UUID?                   // Focus set used when working on this goal
    var createdAt: Date
    var completedAt: Date?
}

enum GoalStatus: String, Codable {
    case active, paused, completed, abandoned
}
```

**Relationship to workbench:** Goals appear as a section at the top of the Workbench view. Each goal shows its progress bar, attached questions (with counts by status), and active hypotheses. Clicking a goal filters the workbench to show only items related to that goal and activates the associated focus set.

**Session resume integration:** The resume screen shows active goals and their progress: "You're 60% through 'Trace maternal line to 1700s' — 3 questions still open."

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

## 7.5 Manual Tree Entry

Users without a GEDCOM file or WikiTree account can start a tree from scratch. This is the lowest-barrier entry point — but "lowest barrier" does not mean "blank canvas with an Add button." For the user this feature targets, manual entry is their first-time onboarding experience. The design must guide them from "I know some things about my family" to "I have a tree that looks like a family tree" in a single session.

**First-session success metric:** A new user should be able to enter themselves, both parents, and all four grandparents (with whatever incomplete information they have) in under 10 minutes, and end with a visible 3-generation pedigree. If they achieve that, they'll come back. If they end with two disconnected profiles and a screen full of warnings, they won't.

### 7.5.1 Onboarding Wizard

`NewProjectView` gains a third source option: **"Start from scratch"**.

**Flow:**
1. User selects "Start from scratch" in `NewProjectView`, enters project name
2. `AppState` creates project with `DataSource.manual`, database initialised empty
3. Instead of a blank canvas, the app launches the **Onboarding Wizard** — a guided multi-step flow:

**Step 0 — "Before we start" (structural question)**
- "Is there anything unusual about your immediate family?" with options:
  - **No, straightforward** — proceed with standard wizard
  - **I was adopted** — Step 2 adapts: "Tell us about your adoptive parents" + optional "Do you know your biological parents?"
  - **My parents divorced/remarried** — Step 2 supports two parent couples (biological + step)
  - **Other / it's complicated** — skip wizard, go directly to manual entry (the flexible Add Family flow handles complex structures better than a wizard can)
- This costs one screen and makes the wizard work for the 20–30% of users who don't fit the assumed structure.

**Step 1 — "Let's start with you"**
- First name, last name, gender (optional), birth date (optional)
- Subtitle: "This will be the person your tree is centred on"
- Sets `Project.homePersonID` to this profile
- Source: automatically set to `.manualMemory` (personal knowledge)

**Step 2 — "Now your parents"**
- Two-column form: Father (left) and Mother (right)
- Each: first name, last name, birth date, birth location (all optional)
- Marriage date and location between them (optional, skippable — parents may never have married, or may be separated, or one parent unknown)
- "Add stepparent" button — creates additional parent edge with subtype `.step`
- For adopted users (from Step 0): labels change to "Adoptive father / mother" with optional "Biological father / mother" section below
- Skip button: "I'll add parents later"
- Source: automatically set to `.manualMemory` (most users know their parents directly)

**Step 3a — "Your father's parents"**
- Two-column form: paternal grandfather (left) and paternal grandmother (right)
- Each: first name, last name, birth date (all optional)
- Skip button: "I don't know / I'll add later" — skipping this does not skip Step 3b

**Step 3b — "Your mother's parents"**
- Same layout as 3a for maternal grandparents
- Independent skip — users often know one set of grandparents better than the other
- Source for Steps 3a/3b: automatically set to `.manualMemory` with "from whom?" defaulting to the relevant parent entered in Step 2 (e.g. "Family member told me" → "from: William Land")

**Step 4 — "Your family" (optional)**
- "Do you have a spouse or children?" — skip if not applicable
- Spouse: first name, last name, marriage date (optional)
- Children: repeating row with first name, gender, birth date
- This step exists because many users think of their tree as "my family" (spouse + kids), not just ancestors. Currently the wizard assumes ancestor-only research.

**On completion:**
- Creates all entered profiles and relationships as a single `TransactionKind.addFamily` transaction
- Shows a brief **completion toast**: "Wizard complete — N people added. [Undo wizard] [Continue]" — makes the bulk transaction visible at exactly the moment the user might want to reverse it
- The tree view opens showing the pedigree — the user immediately sees their family tree shape
- Skipped entries leave gaps that the Gaps view highlights as next steps
- The Gaps view's first item is contextually generated: "Continue building: add [grandparent name]'s parents (your great-grandparents)." One click extends the tree — progressive disclosure of the manual entry pattern

**The wizard is optional but default.** Users who dismiss it land on the empty-canvas state (§7.5.15). The wizard can be re-invoked from Settings if dismissed accidentally.

**Why a wizard, not a blank canvas:** Established genealogy software (Family Tree Maker, MyHeritage, Ancestry's tree builder) all start with the user as seed person, then prompt outward generationally. An empty canvas with "Add Person" works for power users adding a stray cousin — it's the wrong mental model for someone who has never built a tree before.

### 7.5.2 Home Person

`Project.homePersonID` anchors the tree. Without it, the tree has no orientation — "ancestors of whom?"

- Set automatically during onboarding wizard (Step 1)
- Set to the first manually added profile if wizard is skipped
- Changeable in Settings ("Set as home person" also available in profile context menu) — requires confirmation ("Change the home person? The tree view will re-orient around [name].")
- Tree views default to "ancestors of home person" when first opened
- Navigation commands like "Show ancestors" / "Show descendants" are relative to home person unless another profile is selected

**On change:** Home person is just a pointer — all data is preserved, no relationships change. Tree views re-orient on next render to show the new person's perspective. The previous home person retains all its data and relationships; it simply loses the "anchor" role. Changing home person does not affect the wizard data — profiles created during the wizard remain as they are.

For GEDCOM and WikiTree projects, `homePersonID` is nil by default (the tree has no natural anchor). Users can set it manually in Settings. This is backwards-compatible — existing projects work unchanged.

### 7.5.3 Add Person

Accessible from three paths, each with different connection behaviour:

| Path | Connection | Notes |
|------|-----------|-------|
| **Context menu** ("Add Parent", "Add Child", "Add Spouse") | Implicit — relationship to context person is pre-set | No "Related to" picker needed |
| **Toolbar "Add Person"** (tree has 1+ profiles) | Required — user must specify relationship | Override: "Add as unconnected person" (secondary action) |
| **Toolbar "Add Person"** (empty tree) | Not applicable — this is the first profile | Becomes home person if wizard was skipped |

**AddPersonView** — presented as a sheet:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| First name | `String` | See below | At least one identifying field required |
| Last name | `String` | See below | LastNameAtBirth |
| Gender | `Gender` picker | See below | Male / Female / Other / Unknown |
| Birth date | `String` | No | Free text with live parse preview (see §7.5.8) |
| Birth location | `String` | No | Free text, auto-suggests from previously used locations |
| Death date | `String` | No | Free text with live parse preview |
| Death location | `String` | No | Free text, auto-suggests from previously used locations |
| Source | Source picker | No | Where this information came from (see §7.5.9) |
| Related to | Profile picker | Conditional | See connection table above |

**Advanced section** (collapsed by default, revealed via disclosure triangle):

| Field | Type | Notes |
|-------|------|-------|
| Name status | `NameStatus` | Known (default) / Unknown / Placeholder |
| Life status | `LifeStatus` | Normal (default) / Infant death / Stillborn |
| Privacy | `Privacy` | Normal (default) / Living (private) |

Most first-time users never need the advanced section. The defaults are correct for the common case.

**Minimum data requirement:** At least one identifying field must be set — first name, last name, gender, or name status other than `.known`. A profile with literally no information is junk data. If the user taps "Save" with everything blank, prompt: "You haven't entered any information about this person. Would you like to add something?" with cancel as default.

**"Add as unconnected person" override:** Available when the toolbar path requires connection. Legitimate use cases: preparing a family group to connect later, adding a person of interest before knowing the link, collaborative research where the connection isn't yet established. The tree view shows disconnected components as separate islands with a visible "Connect these?" affordance (§7.5.14).

**Person attributes affect display and audit:**
- `NameStatus.unknown` — tree node shows "?" instead of blank
- `NameStatus.placeholder` — tree node shows "?" in italic, flagged for replacement
- `LifeStatus.infantDeath` — italic/muted display, exempt from completeness scoring
- `LifeStatus.stillborn` — similar to infant death, recorded for family completeness
- `Privacy.livingPrivate` — full name in desktop app, "[Living]" in export (see §7.5.13)

**Auto-suggestions:** After the first few profiles, surname and location fields auto-suggest from values already used in this project. Suggestions are context-aware:
- **Surnames:** when adding a sibling, suggest the existing sibling's surname first. When adding a spouse, suggest the most common surnames in the project but not the current person's surname (spouses usually bring different surnames). When adding a maternal grandmother, suggest surnames previously entered as maiden names.
- **Locations:** when adding a child, suggest the parents' locations. If the project's profiles cluster geographically (e.g. all Derbyshire), prioritise those locations. By profile 20–30, the user is barely typing.

**Name normalisation on save:** trim leading/trailing whitespace, collapse multiple internal spaces. Reject pure-whitespace names. Soft warning at 100 characters, hard limit at 500.

**Design decisions:**
- **Date input is free text**, not a date picker. Genealogical dates are fuzzy ("ABT 1887", "BEF 1900") — a calendar widget can't express this. See §7.5.8 for the live parse preview.
- **No external IDs.** Manual profiles have no `externalIDs` entries. They can gain them later if matched during a WikiTree sync or future FamilySearch integration.
- **Profile ID** is a generated UUID string.

**Transaction:** `TransactionKind.addProfile(profileID:)` with `UndoStrategy.structural`. All fields tagged with the selected source origin (§7.5.9). Undo deletes the profile and any relationships that reference it.

### 7.5.4 Family Group Entry

Once past the onboarding wizard, the primary "Add" action for building out the tree is **"Add a family"** — a parent couple plus their children, entered together. This matches how genealogical records work: a census shows a household, a marriage entry shows bride and groom with their fathers, a baptism register lists the child with both parents.

**AddFamilyView** — presented as a sheet:

| Section | Fields |
|---------|--------|
| **Father** | First name, last name, birth date, birth location, death date (all optional). Existing person (picker) or new. |
| **Mother** | Same as father. Existing person (picker) or new. |
| **Marriage** | Date, location (both optional, skippable) |
| **Children** | Repeating row: first name, last name, gender, birth date (add more with "+" button). Each child can be existing person (picker) or new. |

Parents and children can all be existing people — this handles "add this couple as parents of these existing children" (e.g. the user entered themselves and siblings first, now adds parents as a family group).

**Connection requirement for Add Family:** When the tree already has profiles, at least one person in the family group must be linked to an existing tree member (either by picking an existing person or by being added from a context menu). Override available for power users adding a separate family to connect later.

**Example:** Transcribing a census household:
> Father: William Land, b. ~1810 Belper, d. 1875 Belper
> Mother: Mary Slater, b. ~1812, m. 1832 Belper
> Children: Thomas (b. 1834), Sarah (b. 1836), John (b. 1838)

This produces 5 profiles + 1 spouse relationship + 6 parent relationships in one `TransactionKind.addFamily` transaction. Single undo removes everything.

**Census transcription mode:** A "Transcribing a record?" toggle on the form exposes additional fields optimised for transcribing a specific historical record:

| Field | Per-person | Notes |
|-------|-----------|-------|
| Record type | Form-level | Census / Baptism register / Marriage register / Other |
| Record year | Form-level | e.g. 1881 — used to compute birth years from ages |
| Address | Form-level | Household address (shared across family) |
| Age | Per-person | Integer — form computes birth year as `recordYear - age` with ±1 tolerance, shown as preview |
| Birthplace | Per-person | Often differs from current residence (e.g. "Ireland" for migrants) |
| Occupation | Per-person | Stored in bio or a future structured field |
| Relation to head | Per-person | Head / Wife / Son / Daughter / Servant / Lodger / etc. — auto-sets relationship type |

When census mode is on, the source is automatically set to `.manualRecord` and the record details (year, type) are stored in the `FieldSource.raw` metadata.

This is the highest-leverage move for genealogical productivity. A user transcribing one 1881 census household captures 8 profiles + relationships + birthplaces + occupations in one transaction.

**Accessible from:**
- Tree toolbar — "Add Family" button (alongside "Add Person")
- Context menu — "Add family around this person" (pre-populates them as parent or child)

### 7.5.5 Edit Person

Accessible from:
- **Profile detail inspector** — "Edit" button
- **Context menu on tree node** — "Edit Person"

**EditPersonView** — presented as a sheet, pre-populated with current values. Same fields as AddPersonView, plus a source picker per changed field.

**Source indicators per field:** Each field in the edit form shows a small source badge (icon) indicating where the current value came from (GEDCOM, WikiTree, manual-memory, etc.). Clicking the badge reveals the full source list for that field — all sources that have contributed a value, with timestamps. The user can directly accept a different source's value, trigger dispute resolution, or enter a correction, all from within the edit flow. This avoids the back-and-forth of leaving the form to check sources, then returning to edit.

**Edit behaviour depends on context:**

**A. Editing a manual-only profile** (no imported sources): The edit replaces the value directly. No dispute. This is the common case for manual-entry users — they're correcting their own input.

**B. Editing a field that has an imported source** (GEDCOM, WikiTree, etc.): The user sees an explicit choice:
- **"Correct this value"** — replaces the imported value. The old value is preserved in source history but the field now shows the manual value. For typo fixes, transcription errors, or "I have better information than what was imported."
- **"Record an alternative"** — creates a dispute (§5.7). Both values coexist until the user resolves the dispute. For genuine disagreements between sources.

This distinction prevents the UX trap where every correction creates a dispute requiring resolution. The user's intent ("fix a typo" vs "record conflicting evidence") determines the downstream behaviour.

Each changed field creates a `FieldChange` record within a single `TransactionKind.manualEdit` transaction. The source picker applies per field — a user might correct a birth date (from a certificate they found) while estimating a death date, yielding `.manualRecord` for one and `.manualEstimate` for the other within the same transaction.

### 7.5.6 Soft Delete

Accessible from context menu or profile inspector: "Remove this person."

**Behaviour:** Sets `Profile.isDeleted = true`. The profile is hidden from the tree view and snapshot queries. Relationships are preserved but hidden (they still point to the deleted profile in the database). The profile does not appear in audit or gaps.

**Undo:** `TransactionKind.softDelete(profileIDs:)` with `UndoStrategy.replay`. Undo sets `isDeleted = false` on every profile in the bulk transaction, restoring them and their relationships in a single operation.

**Why soft delete, not hard delete:** Hard deletion cascades — orphaned relationships, broken audit history, snapshot integrity issues. Soft delete is one boolean column on `profiles`, one extra `WHERE isDeleted = false` filter on the snapshot query, and fully reversible. The database schema gains one column, not a cascade of foreign key cleanup.

**Why in MVP, not post-MVP:** The user this feature targets will make mistakes — wrong person, wrong name, accidental duplicate. The only current alternative is undoing the `addProfile` transaction, which is sequential — undoing a profile created 50 actions ago requires undoing everything since. That's catastrophically worse than no delete at all. Soft delete is low cost, high value.

**Restore:** Deleted profiles are listed in Settings → "Deleted People" with a "Restore" button. Restore is another transaction (undo of the soft delete).

**Branch delete:** "Remove this person and all ancestors" / "Remove this person and all descendants" — multi-profile soft delete for the case where an entire branch was added in error (e.g. wrong family with the same surname). Single transaction with `profileCount` set to the number of affected profiles. Single undo restores the entire branch.

### 7.5.7 Add Relationship

Accessible from:
- **Context menu on tree node** — "Add Parent", "Add Child", "Add Spouse"
- **Profile detail inspector** — "Add Relationship" section

**Two flows:**

**A. Create person + relationship together** (most common):
User right-clicks a person → "Add Father" → `AddPersonView` opens (with "Related to" pre-set) → on save, both the new profile and the parent relationship are created as a single `addFamily` transaction. Single undo removes both.

**B. Link existing people:**
User selects "Add Relationship" → picks relationship type → searches/selects existing person from the tree → relationship created. The profile picker supports search and filter (critical for trees with 5000+ imported profiles — must handle large result sets with type-ahead search, not a flat list).

**AddRelationshipView** fields:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Type | `RelationshipType` | Yes | Parent or Spouse |
| Role | `ParentRole` | If parent | Father / Mother / Unspecified |
| Subtype | `RelationshipSubtype` | Yes | Biological (default) / Adoptive / Step / Unknown |
| Marriage date | `String` | No | Spouse only. Parsed by `GenealogicalDate` with live preview |
| Marriage location | `String` | No | Spouse only. Distinct from spouses' birth places |
| Divorce date | `String` | No | Spouse only |
| Target person | Profile picker | Yes | Search existing people or "Create new person" |

**Validation:**
- Cannot create duplicate relationships (same from/to/type)
- Parent role auto-inferred from target person's gender if set (male → father, female → mother), user can override

**Third parent handling:** When adding a parent to a person who already has two parents, the flow does not merely confirm — it asks "What's the relationship?" with options: step-parent, adoptive parent, biological parent (rediscovered), foster parent. The subtype is set explicitly. Without this, users click through with the default "biological" and produce polyparental trees that the audit engine flags for valid reasons.

**Replace parent:** The flow also offers "Replace existing parent" for the case where the user added the wrong person first and wants to correct, not add a third. Replace removes the old parent edge and creates a new one in a single transaction.

**Sibling shortcut:** "Add Sibling" on a profile's context menu creates a new profile linked via shared parents. If the profile has no parents yet, a placeholder parent pair is created to establish the sibling link. Placeholder parents are flagged `NameStatus.placeholder` and display as "?" in italic — they're replaced when real parents are identified. This avoids the 3-step friction of "create parent, then create sibling, then link sibling to parent" for what the user thinks of as one piece of information.

**Placeholder resolution:** When the user later adds real parents to a profile that has placeholder parents, the app detects the placeholders and prompts: "Replace the placeholder parents with these real parents? The sibling links will transfer to the new parents." On accept: placeholder profiles are soft-deleted, all child edges are re-pointed to the new parents. On decline: placeholders remain (the user may intend a different family structure). This prevents placeholder accumulation.

### 7.5.8 Date Parsing with Live Preview

`GenealogicalDate(parsing:)` must be liberal — users will type what they know, not what GEDCOM accepts.

**Parser accepts (case-insensitive):**
- GEDCOM standard: `1887`, `ABT 1887`, `BEF 1900`, `AFT 1880`, `BET 1885 AND 1890`, `1 JAN 1887`, `MAR 1887`, `CAL 1887`, `EST 1887`
- Common synonyms: `circa 1890` → ABT, `around 1890` → ABT, `before 1900` → BEF, `after 1880` → AFT, `approximately 1890` → ABT, `about 1890` → ABT
- Natural date formats: `March 1887`, `3 March 1887`, `1887/3` → parsed to year+month
- Partial: `1880s` → `BET 1880 AND 1889`
- Unknown marker: `?` → treated as nil (distinct from blank — signals "I looked and don't know")

**Live parse preview:** As the user types, a line below the field shows the parsed interpretation:

| User types | Preview shows |
|------------|---------------|
| `1887` | 1887 |
| `circa 1890` | Approximately 1890 (range: 1885–1895) |
| `before 1900` | Before 1900 |
| `March 1887` | March 1887 |
| `1880s` | Between 1880 and 1889 |
| `hello` | Could not parse — try "1887" or "about 1890" |

The preview both validates input and educates the user about the range model. If the date cannot be parsed, the save button remains enabled but the field is flagged with a warning — the user can choose to fix it or leave it as a raw string note.

### 7.5.9 Source-Aware Manual Entry

Every manual entry prompts: **"Where did this information come from?"** — a single picker, not a mandatory form.

| Option | Maps to | Meaning |
|--------|---------|---------|
| I remember this | `.manualMemory` | Oral history, personal knowledge |
| Family member told me | `.manualMemory` | With optional "who?" note field |
| Family document | `.manualDocument` | Bible record, photo, letter, diary |
| Official document I have | `.manualRecord` | Birth cert, marriage cert, census transcript |
| Estimated / best guess | `.manualEstimate` | Calculated, inferred, placeholder |

**Context-aware defaults:** The picker is a single segmented control or dropdown — one click, not a form. The default adapts to context:
- **Home person / immediate family** (parents, siblings): `.manualMemory` — the user likely knows these people directly
- **Adding a parent of someone** (i.e. grandparent generation and beyond): `.manualMemory` with "from whom?" defaulting to the child's profile name — most people learn about grandparents from their parents, not direct knowledge
- **Census transcription mode**: `.manualRecord` automatically
- **Adding a sibling of an existing person**: same source as the existing person's most recent source — if the user sourced one sibling from a family document, the next sibling likely came from the same document
- **Fallback**: `.manualMemory` (lowest friction)

**Why this matters:**
- The audit engine can flag "this entire profile is based on estimates" differently from "backed by official documents"
- When imported data later arrives, merge policy can weight by source tier: a manual entry sourced from "official document" that matches an import is strong corroboration; a "best guess" that matches is weaker
- The user's own future self benefits — coming back 6 months later, "where did I get this?" is answered

### 7.5.10 Remove Relationship

Accessible from context menu or profile inspector. Removes the edge, not the person. Creates `TransactionKind.removeRelationship(relationshipID:)` with `UndoStrategy.replay` (undo re-creates the edge with its original data).

### 7.5.11 Import-After-Manual Reconciliation

A real workflow: user starts manually (no GEDCOM available), later obtains a GEDCOM from a relative, imports it. The GEDCOM contains profiles for people the user already entered manually.

**Current import flow treats the database as empty.** After manual entry, it isn't. The import must handle collisions:

1. **During GEDCOM import**, run duplicate detection (§6.3) between incoming profiles and existing manual profiles
2. **For each potential match** (similarity score ≥ 0.7), present a merge dialog:
   - "William Land (imported) looks like William Land (your entry). Same person?"
   - Options: **Merge** (combine sources, apply merge policy §5.7 per field), **Keep separate** (both remain), **Skip import** (don't import this profile)
3. **On merge:** manual-entry fields gain the GEDCOM source as corroboration (happy path — two sources agreeing). Where values differ, standard merge policy applies (dispute if incompatible). The manual source tier (§7.5.9) affects weighting: a `.manualRecord` value is trusted more than a `.manualEstimate` during merge resolution.
4. **Unmatched imported profiles** are added normally.

This flow also applies to WikiTree sync — if the user has manually entered people who also exist on WikiTree, the sync should detect and offer to merge rather than creating duplicates.

### 7.5.12 Audit in Manual-Entry Mode

Manually entered profiles are fully integrated with the audit engine. But for manual-entry users, the audit framing shifts from **error detection** to **guidance**.

**Same data, different presentation:** When a project's source is `.manual` (or has fewer than ~50 profiles), the Gaps view uses guidance-flavoured language:

| Standard framing | Manual-entry framing |
|-----------------|----------------------|
| "Missing birth date" (error) | "What you might add next: birth year for William Land" (suggestion) |
| "Missing parents" (error) | "Do you know William's parents? Adding them extends your tree" (prompt) |
| "Completeness: 2/7" (score) | "You've recorded name and birth date — 5 more details to discover" (progress) |

**Contextual hints:** The gaps view includes discovery hints, routed by the profile's date range and missing fields. Each profile's `birthDate.bestYear` selects from a mapping table of relevant sources:

| Date range | Relevant sources hint |
|-----------|----------------------|
| 1538–1837 | "Parish registers (baptism, marriage, burial) are the main source for this period" |
| 1837–1911 | "Civil registration began in 1837 — birth, marriage and death certificates may exist. Census records (1841–1911) often show whole households" |
| 1911–1939 | "The 1911 and 1921 censuses and the 1939 register may include this person" |
| 1939–1990 | "Electoral rolls, obituaries, and civil registration are the main sources for this period" |
| 1990+ | "Living memory and family documents are your best sources for recent generations" |

Additional hints tied to specific missing fields:
- Missing parents: "Marriage records usually list the father's name — that might help"
- Missing birth location: "Census records list birthplace — often different from where they lived"
- Missing bio: "A biography doesn't need to be long — even 'farmer in Belper' helps future research"
- Name unknown: "You can mark this as an unknown sibling for now and fill in the name later"

These are static text — not AI-generated, just domain knowledge. They teach genealogy methodology alongside data entry. The date ranges are UK-centric for now; post-MVP, hints could be region-aware based on the locations already in the tree.

**Audit rules still fire normally** — `birthBeforeDeath`, `parentAgeGap`, etc. run as soon as sufficient data exists. These are presented as "Possible issues" rather than "Errors" in the manual-entry context, but the underlying engine is identical.

### 7.5.13 Privacy for Living People

Living people have privacy concerns that affect display, export, and sharing.

**Determination:** A profile is considered potentially living if:
- `Privacy` is `.livingPrivate` (explicit user choice), OR
- `deathDate == nil` AND (`birthDate` is nil OR `birthDate.latest + 110 >= currentYear`)

A profile with no birth date and no death date is assumed potentially living — this is conservative but correct. The heuristic aligns with `ProfileCompleteness.potentiallyLiving`.

**Behaviour:**
- **Desktop app display:** Always shows full names and details — the user is the project owner viewing their own data. "[Living]" never appears in the user's own desktop view. The privacy filter applies only to export and any future sharing features.
- **GEDCOM export:** "Exclude living people" checkbox (default: on). When on, living profiles are exported with the GEDCOM standard `1 RESN privacy` tag, relationship edges preserved, and "[Living]" substituted for the name. Other genealogy software (Family Tree Maker, RootsMagic, Gramps) respects `RESN privacy` and will hide these profiles automatically.
- **Data model:** `Privacy.livingPrivate` is an explicit user choice. The computed `potentiallyLiving` heuristic is for audit (don't penalise missing death date) and export defaults. Both coexist — a user can mark someone as `.livingPrivate` regardless of birth date, and the heuristic catches people the user forgot to mark.

**GEDCOM export is the primary collaboration mechanism.** The exported file can be shared via email, cloud drive, or any file transfer. The privacy filter ensures living relatives' data isn't inadvertently shared.

### 7.5.14 Disconnected Tree Detection

When the tree contains disconnected components (profiles with no path between them):

- **Tree view:** each component renders as a separate island, visually separated
- **Banner:** "Your tree has 2 separate groups. Connect them?" with a button that opens the relationship picker between the closest profiles in each component
- **This is informational, not blocking.** Users may legitimately maintain separate branches they haven't connected yet. But the UI makes the disconnection visible rather than silently hiding it.

### 7.5.15 Empty State UX

When a project has `DataSource.manual` and zero profiles (wizard dismissed or not yet started):

- **Tree view:** centred prompt — "Start with yourself. Your tree grows from here." with a prominent "Begin" button that launches the onboarding wizard
- **Sidebar stats:** "0 people · 0 relationships" — neutral, no error states
- **Audit/Gaps views:** "Add people to your tree to see what to research next" — not "No issues found" (which implies completeness)

When the tree has 1+ profiles but is small:
- **Tree view:** renders normally, toolbar shows "Add Person" and "Add Family" buttons
- **Gaps view:** populated immediately with guidance-flavoured suggestions (§7.5.12)

**Save indicator:** The app saves continuously to SQLite — but first-time users may not know this. After the first few actions in a new project, show a subtle "Your progress is saved automatically" indicator that fades after a few seconds. Power users never see it; first-time users are reassured.

### 7.5.16 Deliberately Deferred

The following are explicitly out of scope for M7 (manual tree entry), with rationale:

| Feature | Rationale for deferral |
|---------|----------------------|
| **Photo/document attachment** | Storage management, format support (HEIC, JPEG, PDF, TIFF), EXIF metadata extraction, thumbnail generation. High value but orthogonal to tree-building — the tree works without it. Post-MVP. |
| **Occupation as structured field** | Currently captured in bio or census transcription notes. A dedicated `occupation` field per profile with date ranges (people change jobs) is useful but adds schema complexity. Post-MVP. |
| **Region-aware research hints** | Current hints are UK-centric (civil registration 1837, censuses 1841–1911). US, Irish, Scottish, and other jurisdictions have different record sets and date ranges. Post-MVP: detect from locations in the tree. |
| **Name equivalence learning** | "Bob = Robert", "Peggy = Margaret" — currently handled by duplicate detection nicknames. User-taught equivalences ("in this family, 'Polly' always means 'Mary'") are post-MVP. |

---

## 7.7 Research Workbench

The workbench is a sidebar peer to Tree, Audit, Gaps, and Settings. It's the surface where research-in-progress lives — between "I noticed a gap" and "I committed a fact." Without it, every research session is throwaway: findings either commit immediately (if perfect) or vanish (if uncertain). Real genealogy is full of partial findings, and they need somewhere to accumulate.

### 7.7.1 Workbench View

**WorkbenchView** — sidebar navigation item, structured as a tabbed view with five sections:

| Tab | Purpose | Primary action |
|-----|---------|---------------|
| **Focus** | Profiles you're currently investigating | Pin/unpin profiles, set working title |
| **Questions** | What you're trying to figure out | Create, prioritise, record tried sources |
| **Hypotheses** | What you believe but haven't confirmed | Create, add evidence, promote to fact or dismiss |
| **Notes** | Free-text thinking attached to anything | Create, tag, link to profiles/hypotheses |
| **Sessions** | Auto-generated research log | Review past sessions, resume context |

### 7.7.2 Focus

A named working set of 3–10 profiles the user is currently investigating. Persists across sessions.

- **Manual pin:** right-click profile in tree → "Add to Focus" / "Remove from Focus"
- **Auto-include:** profiles touched in the last 30 minutes of activity are auto-suggested for the focus set (not auto-added — the user confirms)
- **Working title:** optional, e.g. "Maternal grandmother's siblings" — helps the session resume screen describe what the user was doing
- **Tree filter:** the Tree view gains a "Focus only" toggle that filters to focused profiles plus their immediate connections (parents, children, spouses). This declutters the tree during deep investigation of one branch.
- **Multiple focus sets:** a project can have multiple focus sets (e.g. "Land family" and "Slater family"), but only one is active at a time. Switching focus sets updates the Tree filter.

### 7.7.3 Open Questions

Structured research todos. The crucial field is `triedSources` — recording dead ends turns wasted effort into useful information. Genealogists waste enormous time re-searching sources they've already checked.

**Creating questions:**
- Manually in the Workbench
- **Promoted from Audit:** one-click promotion from any audit issue ("Missing parents for William Land" → becomes a question with priority)
- **Promoted from Gaps:** one-click promotion from any gap item
- **Spawned from research:** a hypothesis investigation that raises new questions

**Question list view:** sorted by priority, grouped by status (open → in-progress → blocked → resolved). Each question shows its related profiles (clickable) and tried sources.

**Three views surface "things to do" but with different framings:**
- **Audit:** "Is my data internally consistent?" — deterministic, errors and warnings
- **Gaps:** "What's missing that I could fill in?" — missing field detection, suggestions
- **Questions:** "What am I trying to figure out?" — user-curated working agenda

They don't duplicate. Audit and Gaps items can be promoted to Questions with one click — the user moves things onto their working agenda when they care about them.

### 7.7.4 Hypotheses

The most important workbench element. A hypothesis is a tentative claim — something the user believes but hasn't committed as a fact. The tree data model currently has no representation for this; every claim is either a confirmed fact or absent. Real research lives in the middle.

**Hypothesis list view:** grouped by confidence (strong → working → speculation), showing claim summary, reasoning preview, and evidence counts.

**Creating hypotheses:**
- Manually in the Workbench
- From a research finding: "FreeBMD found two possible matches — which is yours?" becomes a hypothesis per candidate
- From tree context menu: "Hypothesise relationship" on a profile
- Future: research features (Field Researcher, Deep Research) contribute findings as hypotheses

**Hypothesis detail view:**
- Claim summary (human-readable: "Thomas Land was the son of William Land")
- Confidence level with reasoning
- Supporting evidence list (free text, expandable)
- Contradicting evidence list
- Related profiles (clickable)
- Action buttons: Promote to Fact / Dismiss / Change Confidence

**Promotion and dismissal:** See §5.11 for the promotion flow. On dismissal, the reason is preserved so the same claim isn't re-hypothesised in a future session. Dismissed hypotheses remain searchable — "didn't I already rule this out?"

### 7.7.5 Notes

Free-text markdown attached to anything — a profile, a relationship, a hypothesis, a question, or just the project. Notes are where most thinking starts; some of it later gets promoted to questions or hypotheses, much of it stays as notes.

**Intra-tree links:** `[[Thomas Land]]` in a note becomes a clickable reference to that profile. Ambiguous matches (multiple Thomas Lands) show a disambiguation picker on first use.

**Tags:** observation, todo, insight, source log, meta. Tags are for lightweight filtering, not rigid categorisation — a note can have one tag or none.

**Full-text search:** notes are FTS-indexed in SQLite. "Search notes for 'Wirksworth'" finds all notes mentioning that parish.

**Notes in profile inspector:** the profile detail inspector shows a "Notes" section listing all notes attached to this profile, with a "New note" button. This surfaces thinking in context without requiring the user to navigate to the Workbench.

### 7.7.6 Session Log and Resume

**Session log:** auto-generated from transactions and Workbench activity. A session starts when the app opens and ends after 30 minutes of closure. No user UI to create sessions — they're automatic.

Each session records: duration, active focus set, profiles added/edited, disputes resolved, hypotheses created/promoted, questions created/resolved, notes created, all transaction IDs.

The session summary is plain English, computed at display time:
> "1 hour. Worked on Land family. Added 4 profiles, resolved 2 disputes, created 3 hypotheses (1 promoted to fact). Open: 2 new questions about William Land's parents."

**Session resume screen:** This is the single feature that turns the app from a tree editor into a research tool you can return to.

When the app opens and there's a recent session (within 7 days), the launch flow shows:

> Welcome back. Last session you worked on the Land family. You added William Land, Mary Land, Sarah Land, and resolved a dispute about Thomas's birth year.
>
> **Still open:**
> - Who were William Land's parents? (high priority)
> - Was Mary born 1812 or 1815?
> - Hypothesis: the 1851 and 1861 Thomas Lands are the same person
>
> [Continue from where you left off]  [Just open the tree]

"Continue from where you left off" restores the active focus set, opens the Tree view filtered to focused profiles, and shows the Workbench sidebar. The user doesn't reconstruct context — the app shows it to them.

**This is what genealogy hobbyists need most and what no consumer genealogy software does well.** Research happens in stolen hours over months. Without session resume, every session starts with "where was I?"

### 7.7.7 Uncertainty Layer in Tree Visualisation

The tree gains visual representation of hypothetical and research state. This layers on top of the existing completeness colouring.

| State | Visual treatment |
|-------|-----------------|
| Confirmed relationship | Solid line |
| Hypothetical relationship | Dashed line, muted colour |
| Confirmed field value | Normal text in inspector |
| Hypothetical field value | Italic, muted text in inspector |
| Hypothetical person (existence claim) | Ghost node: dotted outline, semi-transparent |
| Profile in current focus | Subtle ring or background highlight |
| Profile with attached note | Small note icon in corner |
| Profile with open question | "?" indicator in corner |
| Hypothetical + in focus + has question | All three indicators visible without clutter |

**Research overlay toggle:** Settings → "Show research indicators" (default: on). Turning it off gives a clean tree view for printing, demos, and sharing. The uncertainty layer is purely visual — hypotheses exist in the Workbench regardless of the toggle.

**Interaction:** Clicking a dashed (hypothetical) relationship shows the hypothesis detail in a popover. Clicking a "?" indicator jumps to the related question in the Workbench. Clicking a note icon shows attached notes inline.

### 7.7.8 Third Destination for Research Findings

Currently, research buttons produce findings that must be committed (as facts) or discarded. With the workbench, there's a third path: **capture as hypothesis/note/question.**

A Field Researcher session that produces 8 candidate parents for William doesn't force a binary choice — all 8 become hypotheses ranked by confidence, the user investigates over weeks. Future research features integrate cleanly because they all contribute to the same surface.

| Research result | Without workbench | With workbench |
|----------------|-------------------|----------------|
| Strong match (1 candidate) | Commit or discard | Commit, or capture as strong hypothesis |
| Multiple candidates | Pick one or discard all | All become hypotheses, user investigates |
| Partial finding ("born in Belper but year unclear") | Lose it or commit incomplete data | Capture as note or field-value hypothesis |
| Dead end ("searched FreeBMD, nothing") | Lost entirely | Record as tried source on open question |
| New question raised | Remember it or forget | Create open question linked to profile |

---

## 7.8 Profile Timeline

A chronological view of one person's life — the single view that turns "a database of facts" into "a story of a person."

### 7.8.1 Timeline View

**ProfileTimelineView** — accessible from the profile inspector as a tab alongside the existing detail and history views.

The timeline assembles events from existing data (§5.13 `TimelineEvent`) into a vertical chronological layout:

```
1834 ─── Born, Belper, Derbyshire
         ⌊ FreeBMD birth index, vol 7b p213 ⌋
         📝 "Family bible confirms January"

1841 ─── Census: age 7, with parents William & Mary, Belper
         ⌊ 1841 Census HO107/198 ⌋

1851 ─── Census: age 17, framework knitter, Belper
         ⌊ 1851 Census HO107/2147 ⌋

1858 ─── Married Mary Slater, Belper
         ⌊ FreeBMD marriage index ⌋
         ❓ "Was this at St Peter's or All Saints?"

1875 ─── Died, Belper
         ⌊ FreeBMD death index ⌋
```

Each event shows:
- **Date** (with range indicator if approximate)
- **Event type and description**
- **Sources** with formatted citations (§5.12) — expandable
- **Workbench items** inline: notes (📝), open questions (❓), hypotheses (italic/dashed)
- **Hypothetical events** — rendered in italic with dashed timeline connector

**Events are derived, not stored** (§5.13). The timeline reads:
- Profile fields: birth date/location, death date/location
- Relationship fields: marriage date/location, divorce date
- Workbench notes attached to the profile (shown at their date if one is mentioned, otherwise at the bottom)
- Hypotheses with field-value claims on this profile

**Post-MVP:** Structured life events (census appearances, occupations, residences, baptisms) replace the current bio-field-or-note approach. The timeline view adapts without UI changes.

### 7.8.2 Relationship to Other Views

| View | What it answers | Framing |
|------|----------------|---------|
| **Profile Detail** | What do we know about this person? | Current state |
| **Profile History** | What changed and when? (audit trail) | System changes |
| **Profile Timeline** | What happened in this person's life? | Human story |

These three views are tabs in the inspector panel. They don't duplicate — Detail shows current values, History shows the app's change log, Timeline shows the person's chronological life.

---

## 7.9 Reports and Narrative Output

Reports are the missing endpoint of the user journey. Without output, the app is a research tool with no destination. With it, the tree becomes something the user finishes and shares.

### 7.9.1 Report Types

Four report types, each serving a different audience:

| Report | Audience | Content | Format |
|--------|----------|---------|--------|
| **Pedigree chart** | Family members, wall display | Ancestors of home person in traditional layout | PDF (4-gen, 5-gen, fan chart) |
| **Family group sheet** | Genealogists, researchers | One family unit: parents + children with dates, locations, sources | PDF |
| **Narrative report** | Family members, publication | Biographical summaries with citations — "Thomas Land was born in Belper in 1834..." | PDF, Markdown |
| **Research report** | Future self, other researchers | What was searched, what was found, what's still open — the workbench as narrative | PDF, Markdown |

### 7.9.2 Pedigree Charts

Standard genealogical chart layouts. Generated from the tree data.

- **4-generation chart** — home person + parents + grandparents + great-grandparents (15 people). The classic "family tree" people expect.
- **5-generation chart** — extends to great-great-grandparents (31 people). Standard professional format.
- **Fan chart** — semicircular layout radiating from home person. Compact, visually appealing for sharing.
- **Hourglass chart** — ancestors above, descendants below the selected person.

Each chart shows: name, birth/death dates, birth/death locations. Completeness indicators optional (toggleable — some users want clean charts for framing).

**Export:** PDF with configurable paper size (A4, Letter, A3 for large charts). Print-ready at 300 DPI.

### 7.9.3 Family Group Sheets

One page per family unit. The format used by professional genealogists worldwide.

- **Parents section:** name, birth date/location, marriage date/location, death date/location, sources
- **Children section:** name, gender, birth date, death date, spouse (if married)
- **Source list:** all citations for this family, formatted per §5.12
- **Notes:** workbench notes attached to any member of this family

**Batch generation:** "Export all family group sheets" produces one PDF with all families in the tree.

### 7.9.4 Narrative Reports

Biographical summaries in plain English. This is where the workbench earns its investment — questions answered become narrative, hypotheses promoted become reasoning, notes become context.

**Per-profile narrative:**
> Thomas Land was born in Belper, Derbyshire in 1834 (FreeBMD birth index, vol 7b p213). He was the son of William Land and Mary Slater, who married in Belper in 1832. By the 1851 census he was working as a framework knitter, still living with his parents. He married Mary Slater in 1858 in Belper. He died in Belper in 1875.

**Generation:** The narrative renderer reads profile fields, relationships, timeline events, and workbench notes to produce structured prose. Not AI-generated — template-based with conditional sections (if marriage exists, include marriage paragraph; if workbench has notes, include research context).

**Citations as footnotes:** Each fact in the narrative has a footnote reference to its source citation. The source list appears at the end.

**Export:** PDF and Markdown. Markdown is useful for users who want to edit the narrative further in a word processor.

### 7.9.5 Research Reports

The workbench as a shareable document — what was investigated, what was found, what's still open.

**Sections:**
1. **Scope** — profiles investigated (from focus set), time period, geographic area
2. **Questions investigated** — each open question with its tried sources and outcome
3. **Hypotheses** — active and resolved, with reasoning and evidence
4. **Findings** — facts committed to the tree during this research, with citations
5. **Still open** — unresolved questions and active hypotheses
6. **Sources consulted** — all sources searched, including dead ends

**This is the report that prevents work duplication.** A researcher who shares their research report with a cousin is saying "here's what I've already checked — don't re-search these sources."

**Export:** PDF and Markdown.

### 7.9.6 Report Generation Architecture

Reports are read-only projections of existing data — no new state, no side effects. A `ReportGenerator` service takes a report type + parameters (home person, scope, options) and produces a document.

```swift
@MainActor @Observable
final class ReportGenerator {
    func generatePedigreeChart(
        homePerson: String, generations: Int, snapshot: FamilyGraphSnapshot
    ) async -> PDFDocument

    func generateFamilyGroupSheet(
        familyID: UUID, snapshot: FamilyGraphSnapshot
    ) async -> PDFDocument

    func generateNarrative(
        profileID: String, snapshot: FamilyGraphSnapshot, workbench: WorkbenchData
    ) async -> MarkdownDocument

    func generateResearchReport(
        focusSetID: UUID, workbench: WorkbenchData
    ) async -> MarkdownDocument
}
```

**PDF rendering:** SwiftUI views rendered to PDF via `ImageRenderer` (macOS 13+) or Core Graphics. Chart layouts are purpose-built views (not the interactive tree graph re-rendered).

---

## 7.10 Keyboard and Professional Workflow

A mature desktop app supports keyboard-driven workflows. Power users add 100 profiles in a session via keyboard alone.

### 7.10.1 Global Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | Add Person |
| `Cmd+Shift+N` | Add Family |
| `Cmd+E` | Edit selected person |
| `Cmd+F` | Search tree (name, location, date range) |
| `Cmd+Z` | Undo |
| `Cmd+Shift+Z` | Redo |
| `Cmd+1` through `Cmd+5` | Switch sidebar: Tree, Audit, Gaps, Workbench, Settings |
| `Cmd+Shift+W` | Toggle focus filter on tree |
| `Cmd+Shift+R` | Toggle research overlay on tree |

### 7.10.2 Tree Navigation

| Key | Action |
|-----|--------|
| Arrow keys | Navigate between profiles in tree (parent ↑, child ↓, sibling ←→) |
| Enter | Open inspector for selected profile |
| Space | Toggle profile in/out of focus set |
| Delete | Soft delete selected profile (with confirmation) |

### 7.10.3 Form Navigation

All forms (AddPersonView, AddFamilyView, EditPersonView, wizard steps) support full tab navigation. Enter submits the form. Escape cancels. The source picker is keyboard-accessible (number keys 1–5 for the five source types).

### 7.10.4 Tree Search

`Cmd+F` opens a search bar at the top of the tree view. Supports:
- **Name search:** type-ahead filtering across all profiles
- **Date range search:** "born 1830-1850" filters to profiles with birth dates in that range
- **Location search:** "born in Derbyshire" filters to matching birth locations
- **Combined:** "Land born 1830-1850 Derbyshire"

Results highlight matching profiles in the tree and show a results list. Arrow keys navigate between results.

---

## 7.11 Performance, Backup, and Data Preservation

### 7.11.1 Performance Characteristics

| Operation | Target | Notes |
|-----------|--------|-------|
| Snapshot rebuild (1k profiles) | < 100ms | Single GRDB read transaction, eagerly joined |
| Snapshot rebuild (10k profiles) | < 500ms | Acceptable for MVP ceiling. Post-MVP: incremental snapshots |
| Snapshot rebuild (50k profiles) | < 2s | Stretch goal — may require persistent data structures (HAMT) |
| Tree layout (1k profiles) | < 200ms | Reingold-Tilford / Sugiyama on visible portion + buffer |
| Tree layout (10k profiles) | < 1s | Viewport culling — only layout visible + adjacent nodes |
| Profile search | < 50ms | FTS5 index on profile names, locations |
| Workbench note search | < 50ms | FTS5 on workbench_notes |
| Add person transaction | < 50ms | Single GRDB write + snapshot rebuild |
| GEDCOM import (5k profiles) | < 10s | Batch insert in single transaction |

**Viewport culling:** The tree graph does not render all nodes simultaneously. Only nodes visible in the current viewport plus a buffer zone are laid out and rendered. Pan/zoom triggers incremental layout of newly visible nodes. This is essential for trees above ~1,000 profiles.

**Profile name index:** An FTS5 virtual table on `profiles(first_name, last_name, birth_location, death_location)` supports fast search across the tree. Built alongside the main schema (migration v1).

### 7.11.2 Backup and Data Preservation

Genealogy data has serious sentimental and research value. A user who loses a tree they've worked on for two years is devastated.

**Automatic backup:** On every app launch, the current project database is copied to `~/Library/Application Support/AncestorResearch/backups/{projectID}/{timestamp}.sqlite`. Retain the last 10 backups per project. Total storage cost: ~10× the project size (acceptable — a 10k-profile tree is ~5MB, so 50MB of backups).

**Manual backup:** "Export Project" in the file menu copies the `.sqlite` file to a user-chosen location. This is the lossless backup — all tree data, workbench, sessions, sources, disputes, transaction history.

**Recovery:** If the active database is corrupted (detected by GRDB's integrity check on open), the app offers to restore from the most recent backup. The user sees: "Your project file appears damaged. Restore from backup (last saved [date])? You may lose changes since then."

**What's preserved in project export:**
- All tree data (profiles, relationships, sources, disputes)
- All workbench data (focus sets, questions, hypotheses, notes, sessions)
- All transaction history (full undo stack)
- All citations

**What's NOT preserved (and why):**
- Source attachments (post-MVP — not yet implemented)
- App settings (per-app, not per-project)

**Cloud sync:** Not in MVP. The `.sqlite` file is compatible with iCloud Drive, Dropbox, or any file sync — but concurrent access from multiple machines is not supported (SQLite doesn't handle this safely without WAL mode + careful locking). Post-MVP: investigate CloudKit or CRDTs for true multi-device sync.

---

## 7.13 Unified Tasks View

Multiple surfaces currently show "things to do" — Audit (data consistency errors), Gaps (missing fields), Open Questions (user-curated research agenda), and Leads (engine-discovered person-shaped candidates). All produce lists of items the user could work on, and the same thread of work crosses them — *"Ernest has no parents"* (gap) becomes *"engine proposes Henry Cauldwell"* (lead) without the user changing their intent. Splitting these into separate sidebar entries forces them to navigate multiple lists for one workflow.

**Resolution: a single Tasks view in the sidebar** that unifies all of them, with filtering by source.

### 7.13.1 Tasks View Structure

The Tasks view presents a single prioritised list of actionable items. Each item has a source badge indicating where it came from:

| Source | Badge | Example |
|--------|-------|---------|
| Audit | "Audit" | "Birth after death: Thomas Land (b.1890, d.1834)" |
| Gap | "Gap" | "Missing birth date: William Land" |
| Question | "Question" | "Who were William Land's parents?" |
| Tentative | "Tentative" | "Birth year 1834 — needs more evidence" (from FactConfidence) |
| Lead | "Lead" | "Henry Cauldwell · father · b. ~1860 — engine candidate, awaiting research or decision" |

**Filters:** All / Audit / Gaps / Questions / Tentative / Leads. Default: All.

**Sort:** by priority (user-set for questions, severity for audit, completeness for gaps, lifecycle stage for leads), by profile, or by date added. Leads in the `.investigated` state (engine done, user decision required) sort above ordinary gaps; `.new` leads (engine done, research available) sort just below them; `.investigating` leads (in flight) sink to the bottom.

**Grouping:** by profile (shows all tasks for one person together) or flat list.

**Inline actions per lead row:** Research (kicks the pipeline against the lead's identity) and Dismiss (marks as `.dismissed`). Mirrors the actions in the standalone Leads view.

### 7.13.2 Relationship to Audit Engine and Gaps

The audit engine and gap detection still run as before — they're computation, not views. Their results feed into the Tasks view. The user can promote any task to an Open Question with one click (adding tried sources, priority, and notes). Resolved tasks disappear.

**Audit rules view** (previously AuditRulesView in Settings) remains in Settings — it's documentation of the rules, not a task list.

### 7.13.3 What This Replaces

- **AuditView** (sidebar item) → removed. Audit results appear in Tasks with "Audit" badge.
- **GapsView** (sidebar item) → removed. Gap items appear in Tasks with "Gap" badge.
- **LeadListView** (Leads sidebar item) → mirrored, not removed. Active leads (`.new`, `.investigating`, `.investigated`) appear in Tasks with a "Lead" badge alongside the existing sidebar entry; the sidebar entry stays as a focused view during the transition. A later slice may retire the sidebar entry once the in-Tasks surfacing is proven.
- Audit, Gaps, and Leads as *concepts* remain. The engine is unchanged. Only the user-facing surface is consolidated.

---

## 7.14 Collaboration Boundary

This product is **single-user by design**. Genealogy is a family activity, but real-time collaboration is a different product category requiring conflict resolution, access control, identity management, and network infrastructure that would compromise the app's core simplicity.

**What users can do:**
- **Share findings:** GEDCOM export with privacy filtering (§7.5.13). The exported tree can be opened in any genealogy software.
- **Send to a relative for review:** Export a branch as GEDCOM, email it, receive corrections back as a new GEDCOM to import. Import reconciliation (§7.5.11) handles the merge.
- **Share research reports:** Research reports (§7.9.5) export as PDF/Markdown — sharable as documents. "Here's what I've investigated, here's what's still open."
- **Share the project file:** The `.ancestor` archive (SQLite + media) can be copied to another machine running the same app. Full fidelity, no data loss.

**What users cannot do:**
- Real-time co-editing of the same tree
- Cloud-synced shared trees between multiple users
- Publishing a tree as a website (post-MVP — see §13)
- Commenting or annotating each other's trees

**Why this is the right boundary:** Collaboration in genealogy typically means "my cousin knows things I don't" and "my aunt wants to see what I've found." GEDCOM export + research reports address both. The product doesn't need to become a collaboration platform to serve collaborative genealogy.

---

## 7.15 Data Sovereignty and Trust

Users will invest years of research in this product. The product holds their family history, some of it sensitive (illegitimate births, criminal ancestors, family disputes, living relatives who haven't consented). The product has responsibilities.

### 7.15.1 Data Format and Portability

- **SQLite is the storage format.** It's an open, documented, long-lived standard. Even if this software ceases to exist, users can read their data with any SQLite tool.
- **The schema is documented in this spec** (§5.9). All tables, all columns, all relationships. A competent developer can write a reader without the app.
- **GEDCOM export is always available** — the universal genealogy interchange format. GEDCOM has limitations (no hypotheses, no workbench, no session history) but it preserves all tree data, relationships, and citations.
- **Project archive export** (`.ancestor` = SQLite + media directory, zipped) preserves everything — the complete data, lossless.
- **The user can leave at any time** with their data intact. No lock-in, no proprietary binary formats, no cloud-only storage.

### 7.15.2 Sensitive Data

- **Living relatives:** privacy controls (§7.5.13) with explicit opt-in/opt-out. Export filtering excludes living people by default.
- **Sensitive historical facts:** No special technical treatment — a criminal record from 1850 is stored the same as a birth record. But notes and reports should let users mark content as "private — do not include in shared exports." A `sensitive: Bool` flag on `WorkbenchNote` and `LifeEvent` with a global "exclude sensitive items from export" toggle.
- **Deletion:** Users can soft-delete any profile (§7.5.6) or hard-delete via "Permanently remove from Deleted People" in Settings. Hard delete removes all traces from the database (profile row, field changes, life events, attachments, workbench items referencing it).

### 7.15.3 Continuity

- **What happens if the developer stops maintaining this product?** The data is in SQLite — it remains readable. GEDCOM export works offline. The project archive is a self-contained file.
- **What happens if the user dies?** The project file on their Mac is inheritable like any other file. No account, no cloud dependency, no login required. A family member can open the app (or read the SQLite directly) and continue the research.
- **What's the upgrade path?** New versions of the app migrate the SQLite schema forward. Old project files are auto-upgraded on open. Schema migrations are non-destructive (columns added, never removed).

---

## 7.16 First-Time vs Returning User

The product should look different to a 30-second user vs a 30-month user. Progressive complexity, not uniform complexity.

### 7.16.1 First Session

- **Launch:** Project picker → "Start from scratch" → Onboarding wizard (§7.5.1)
- **Sidebar:** Tree and Settings only. Tasks and Workbench are hidden until the tree has 5+ profiles (they're empty and confusing before then).
- **Tree view:** Wizard results + "Add Person" / "Add Family" toolbar. Guidance hints (§7.5.12).
- **Advanced features hidden:** Person attributes (§7.5.3) collapsed. Census transcription mode not shown. Hypothesis creation not shown. Source picker defaults silently.

### 7.16.2 Growing User (1–3 months, 50–200 profiles)

- **Sidebar:** Tree, Tasks, Settings. Workbench appears once the user creates their first note, question, or hypothesis.
- **Tasks view:** guidance-flavoured framing transitions to standard audit/gap language as the tree grows.
- **Source picker:** visible and defaulting contextually. Citation entry available but not prominent.
- **Workbench:** notes and questions available. Hypotheses and focus sets appear when the user tries to use them.

### 7.16.3 Experienced User (6+ months, 500+ profiles)

- **Sidebar:** Tree, Tasks, Workbench, Settings — all visible.
- **Full feature surface:** all workbench features, census transcription, citations, research goals, session resume, reports.
- **Session resume** as default launch (not the project picker — the user has one project, and they want to continue).
- **Keyboard-driven workflow** — power users discover and use shortcuts.
- **Statistics** available in Settings: total profiles, hours invested, hypotheses promoted, sources consulted. Not gamification — recognition that the product is used over years.

### 7.16.4 Implementation

Progressive disclosure is driven by project state, not user accounts or onboarding flags:
- Sidebar items appear when their content is non-empty or when the tree crosses size thresholds
- Advanced sections start collapsed and stay collapsed until opened
- Hints and guidance-flavoured language activate when `DataSource == .manual` and profile count is low
- Session resume activates when there's a recent session with open items

No user profiles, no "beginner mode" toggle, no tutorials. The product adapts to what the user has done, not what they say they want.

---

## 7.17 Future Data Source Integrations

> **Note:** Subsection numbering below retained as 7.6.x from the original spec for cross-reference stability.

The app's multi-source architecture (§5.5 `SourceOrigin`, §5.7 merge policy) is designed to accommodate new data sources with minimal code change — each new source is one `SourceOrigin` constant and one import path. The following integrations are planned post-MVP, ranked by value-to-effort:

### 7.6.1 FamilySearch API

**Status:** Post-MVP. Requires OAuth 2.0 app approval via FamilySearch's Compatibility Review Process. The app's audit and visualisation capabilities (not available from FamilySearch directly) strengthen the approval case.

| Aspect | Detail |
|--------|--------|
| Auth | OAuth 2.0 (PKCE flow for desktop apps) |
| Data | Pedigree traversal, person records, sources, memories/media |
| Cost | Free (FamilySearch is a nonprofit) |
| Risk | Approval is not guaranteed — apps that "only read content" are deprioritised. The audit engine and gap analysis are the differentiators. |

**Integration approach:** Same pattern as WikiTree — fetch pedigree into `FamilyGraphSnapshot`, tag all fields with `SourceOrigin.familysearch`, merge via §5.7 policy. FamilySearch person IDs stored in `externalIDs["familysearch"]`.

**Action:** Submit developer application early — approval can take weeks. Build the integration once approved.

### 7.6.2 Geni.com API

**Status:** Post-MVP. Geni hosts the "World Family Tree" — a large collaborative tree. Owned by MyHeritage.

| Aspect | Detail |
|--------|--------|
| Auth | OAuth 2.0 |
| Data | Profiles, family relationships, photos, projects. Read-only traversal. |
| Cost | Free to register, requires app approval for higher rate limits |
| Risk | Low default rate limits for unapproved apps. Desktop OAuth flow (no callback URL). |

**Integration approach:** OAuth login → fetch user's tree segment → import as `SourceOrigin(identifier: "geni")`. Geni profile IDs stored in `externalIDs["geni"]`.

### 7.6.3 GEDCOM 7.0

**Status:** Post-MVP (low effort). GEDCOM 7.0 was released by FamilySearch in 2021. It's structurally similar to 5.5.1 but mandates UTF-8, supports multimedia via GEDZip, and has cleaner tag semantics. Adoption is growing.

**Integration approach:** Extend `GEDCOMParser` to detect and handle 7.0 headers and tag differences. Most of the existing parser works unchanged. Add support for `.gdz` (GEDZip) container format.

### 7.6.4 Gramps Web API

**Status:** Post-MVP (niche). Gramps is open-source genealogy software. Gramps Web exposes a REST API for self-hosted instances.

| Aspect | Detail |
|--------|--------|
| Auth | JWT against user's self-hosted Gramps Web instance |
| Data | Full CRUD — people, families, events, places, sources, media |
| Cost | Free, open source (GPL) |
| Risk | Requires user to self-host Gramps Web (Docker). Niche audience. |

**Integration approach:** User provides their Gramps Web URL + credentials. Fetch tree data via REST API, import as `SourceOrigin(identifier: "gramps")`. Consider also supporting `.gramps` file import (Gramps XML format) for users who run Gramps desktop without the web layer.

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
    │   │   ├── Citation.swift            # Formal source citation with renderer
    │   │   ├── TimelineEvent.swift       # Derived life events for timeline view
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
    │   │   ├── DiffEngine.swift           # Compare two snapshots, produce visual diff
    │   │   ├── ReportGenerator.swift     # Pedigree charts, family group sheets, narratives
    │   │   └── TimelineBuilder.swift     # Assembles TimelineEvents from profile + relationships
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
    │   │   │   ├── ProfileHistoryView.swift # Audit trail timeline
    │   │   │   ├── ProfileTimelineView.swift # Chronological life events
    │   │   │   ├── OnboardingWizardView.swift # 3-step guided first-tree creation
    │   │   │   ├── AddPersonView.swift     # Sheet: create new person (manual entry)
    │   │   │   ├── AddFamilyView.swift     # Sheet: family group entry (parents + children)
    │   │   │   ├── EditPersonView.swift    # Sheet: edit existing person fields
    │   │   │   └── AddRelationshipView.swift # Sheet: link two people
    │   │   ├── Diff/
    │   │   │   └── TreeDiffView.swift      # Visual diff after refresh
    │   │   ├── Conflicts/
    │   │   │   └── ConflictResolutionView.swift # Resolve disputed fields
    │   │   ├── Audit/
    │   │   │   ├── AuditView.swift
    │   │   │   └── GapsView.swift
    │   │   ├── Workbench/
    │   │   │   ├── WorkbenchView.swift     # Tabbed container: Focus, Questions, Hypotheses, Notes, Sessions
    │   │   │   ├── FocusView.swift         # Pin/unpin profiles, working title
    │   │   │   ├── QuestionsView.swift     # Create, prioritise, record tried sources
    │   │   │   ├── HypothesisListView.swift # List grouped by confidence
    │   │   │   ├── HypothesisDetailView.swift # Claim, evidence, promote/dismiss
    │   │   │   ├── NotesView.swift         # Create, tag, search, attach
    │   │   │   ├── SessionListView.swift   # Past sessions with summaries
    │   │   │   └── SessionResumeView.swift # Launch screen: "Welcome back..."
    │   │   ├── Reports/
    │   │   │   ├── ReportPickerView.swift  # Choose report type, scope, options
    │   │   │   ├── PedigreeChartView.swift # 4/5-gen, fan chart layouts for PDF export
    │   │   │   ├── FamilyGroupSheetView.swift # Single-family summary for PDF
    │   │   │   └── NarrativeView.swift    # Biographical summary preview + export
    │   │   └── Settings/
    │   │       ├── SettingsView.swift
    │   │       └── AuditRulesView.swift    # Invariant + fire condition + example per rule
    │   │
    │   └── ViewModels/
    │       ├── AppState.swift             # Root @Observable — current project
    │       ├── ProjectViewModel.swift     # Project CRUD, switching
    │       ├── TreeViewModel.swift        # Graph layout, selection, zoom, uncertainty layer
    │       ├── DiffViewModel.swift        # Refresh diffing state
    │       ├── ConflictViewModel.swift    # Dispute resolution state
    │       ├── AuditViewModel.swift       # Run audit, filter results
    │       └── WorkbenchViewModel.swift   # Focus, questions, hypotheses, notes, sessions
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
            ├── WikiTreeClientTests.swift
            ├── ManualEntryTests.swift       # Add/edit/delete person, family group, undo, connection requirement
            ├── DateParserSynonymTests.swift  # Natural language synonyms: "circa", "around", "before", "1880s"
            ├── ImportReconciliationTests.swift # Manual-then-import merge, duplicate detection, source weighting
            ├── HypothesisTests.swift        # Create, promote to fact, dismiss, supersede, claim types
            ├── WorkbenchPersistenceTests.swift # Focus sets, questions, notes survive save/reload
            └── SessionTests.swift           # Auto-creation, summary generation, resume data
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

### M7: Manual Tree Entry
- **Onboarding wizard** — structural question (Step 0) adapts for adoption/divorce/step-families. 5-step guided flow (structure → you → parents → paternal grandparents → maternal grandparents), optional Step 4 for spouse + children. Creates up to 11+ connected profiles in one `addFamily` transaction. Sets `Project.homePersonID`. Completion toast with [Undo wizard].
- **Home person** — `Project.homePersonID` anchors tree orientation. Set in wizard, changeable in Settings with confirmation. Re-orients tree views on change.
- **Three-axis person attributes** — `PersonAttributes` struct with orthogonal axes: `NameStatus` (known/unknown/placeholder), `LifeStatus` (normal/infantDeath/stillborn), `Privacy` (normal/livingPrivate). Presented in collapsed "Advanced" section of AddPersonView.
- `AddPersonView` — minimum one identifying field required. Context-aware connection requirement (implicit from context menu, required from toolbar, N/A for first profile). Context-aware source defaults. Context-aware auto-suggestions (surnames by family branch, locations by geographic cluster). Name normalisation on save.
- `AddFamilyView` — family group entry: parent couple + children entered together. Parents and children can all be existing people (picker) or new. Census transcription mode toggle: record type, year, address, age→birth-year computation, birthplace, occupation, relation-to-head. Source auto-set to `.manualRecord` in census mode.
- `EditPersonView` — source badge per field showing provenance. Click badge to see full source list. Distinguishes "correct this value" (replace) vs "record an alternative" (dispute) for imported fields. Per-field source picker.
- `AddRelationshipView` — third-parent flow captures relationship type (step/adoptive/biological-rediscovered/foster). Replace-parent option. Sibling shortcut with placeholder parents (`NameStatus.placeholder`). Placeholder resolution when real parents added.
- **Soft delete** — `Profile.isDeleted` flag, hidden from tree, preserved in DB. Restore via Settings → "Deleted People". Branch delete: "Remove this person and all ancestors/descendants." `TransactionKind.softDelete`.
- **Date parsing** — liberal parser: natural language synonyms, decade ranges ("1880s"), `?` for explicitly unknown. Live parse preview shows interpreted range as user types.
- **Source-aware entry** — picker: memory / family member told me / family document / official record / estimate. Context-aware defaults (personal knowledge for home person, "family member told me" for grandparents+, `.manualRecord` in census mode, same-as-sibling for siblings).
- **Import-after-manual reconciliation** — duplicate detection during import, merge dialog for matches, source-tier-aware merge weighting.
- **Guidance-flavoured audit** — Gaps view uses suggestion framing ("What you might add next"). Smart contextual hints routed by date range (1538–1837 parish registers, 1837–1911 civil registration + census, 1911–1939 census + register, 1939–1990 electoral rolls, 1990+ living memory). Post-wizard "Continue building" prompt for progressive disclosure.
- **Privacy** — `Privacy.livingPrivate` + `potentiallyLiving` heuristic (no death date AND birth date nil or within 110 years). Desktop always shows full names. GEDCOM export uses standard `RESN privacy` tag with "exclude living" checkbox (default on).
- **Disconnected tree detection** — visual islands with "Connect these?" affordance.
- **Empty state** — "Start with yourself" prompt launches wizard. Save indicator for first-time users.
- Tests: wizard with structural variants (standard, adopted, divorced), wizard creates 7+ connected profiles, family group entry with existing children, census transcription mode, add/edit/soft-delete/branch-delete person, add/remove/replace relationship, sibling shortcut + placeholder resolution, undo each operation, edit-imported distinction (correct vs alternative), source per field in edit, import-after-manual merge, date parser synonyms + preview, disconnected component detection, privacy export with RESN tag, name normalisation

### M8: Research Workbench (phased W1–W6)

Shipped in stages — each phase is independently useful:

**W1: Notes** — `WorkbenchNote` model, `workbench_notes` + FTS table, `NotesView`, notes in profile inspector. Captures unstructured thinking. `[[profile name]]` intra-tree links. Tag filtering. This is the cheapest phase and immediately useful.

**W2: Open Questions** — `OpenQuestion` model, `open_questions` table, `QuestionsView`. Create, prioritise, record tried sources. One-click promotion from Audit issues and Gaps items. The `triedSources` field alone justifies this phase — it prevents re-searching dead-end sources.

**W3: Focus + Landing Screen** — `FocusSet` model, `focus_sets` table, `FocusView`. Pin/unpin profiles, working title. Tree "Focus only" toggle. After W3, returning to the app feels continuous rather than starting from scratch each time.

**W4: Session Log + Resume** — `ResearchSession` model, `sessions` table, `SessionListView`, `SessionResumeView`. Auto-session detection (30-min inactivity boundary). Plain-English session summaries. The session resume screen ("Welcome back. Last session you worked on...") is the single feature that converts the app from a tree editor into a research tool. After W4, the app has session-to-session memory.

**W5: Hypotheses + Uncertainty Layer** — `Hypothesis` model with four claim types, `hypotheses` table, `HypothesisListView`, `HypothesisDetailView`. Promotion-to-fact flow (creates standard transactions). Dismissal with preserved reasoning. Tree uncertainty layer: dashed lines (hypothetical relationships), ghost nodes (hypothetical people), italic text (hypothetical field values). Research overlay toggle in Settings. This is the differentiator — the only genealogy tool that gives uncertainty a first-class home.

**W6: Search + Polish** — Full-text search across notes. Workbench-wide search (questions, hypotheses, notes). Keyboard shortcuts for common workbench actions. Workbench statistics in sidebar.

**Tests per phase:**
- W1: note CRUD, FTS search, intra-tree links resolve, tag filtering, notes survive save/reload
- W2: question CRUD, tried sources persistence, promotion from audit/gaps, priority sorting
- W3: focus set CRUD, tree filter shows focused + immediate connections, multiple focus sets switch
- W4: session auto-creation, 30-min boundary detection, summary generation, resume data accuracy
- W5: hypothesis CRUD, all four claim types, promote-to-fact creates correct transaction type, dismissal preserves reason, tree renders dashed/ghost/italic correctly, overlay toggle hides indicators
- W6: FTS across notes, cross-entity search, keyboard shortcuts

### M9: Profile Timeline + Citations
- **ProfileTimelineView** — chronological life events derived from profile fields + relationships + workbench items. Tab in profile inspector alongside Detail and History.
- **Citation model** — `Citation` struct on `FieldSource`, structured fields (repository, collection, title, page, URL, date accessed). `EvidenceQuality` enum mapping to GEDCOM QUAY tag.
- Citation entry UI — expandable "Add citation details" per field in AddPersonView/EditPersonView. Auto-suggest from previously used repositories/collections.
- **TimelineBuilder** service — assembles `TimelineEvent` sequence from existing data (no new storage).
- GEDCOM export updated to render citations as `SOUR` + `PAGE` + `QUAY` tags.
- Workbench items appear inline in timeline (notes at their date, questions as indicators, hypotheses in italic).
- Tests: timeline event ordering, citation formatting, citation in GEDCOM export, timeline with hypothetical events

### M10: Reports and Output
- **ReportGenerator** service — reads tree + workbench, produces PDF/Markdown.
- **Pedigree charts** — 4-gen, 5-gen, fan chart, hourglass. PDF export at 300 DPI, configurable paper size.
- **Family group sheets** — single-family summary with parents, children, sources, citations. Batch generation for all families.
- **Narrative reports** — template-based biographical prose with footnoted citations. Per-profile or per-branch. Reads workbench notes as context.
- **Research reports** — workbench as sharable document: scope, questions investigated, hypotheses, findings, dead ends. The report that prevents work duplication.
- `ReportPickerView` — choose type, scope, options, preview, export.
- Tests: pedigree chart with 4/5 generations renders correct profiles, family group sheet includes all children, narrative includes citations as footnotes, research report reflects workbench state

### M11: Keyboard + Professional Workflow
- Global shortcuts: Cmd+N add person, Cmd+Shift+N add family, Cmd+E edit, Cmd+F search, Cmd+1–5 sidebar, Cmd+Z/Shift+Z undo/redo
- Tree navigation: arrow keys (parent ↑, child ↓, sibling ←→), Enter open inspector, Space toggle focus, Delete soft delete
- Form navigation: Tab through all fields, Enter submit, Escape cancel, number keys for source picker
- Tree search: Cmd+F with name, date range, location, combined queries. Results highlighting + arrow-key navigation.
- **Relationship calculator** — "What relation is [person] to [home person]?" — displayed in profile inspector and context menu. Computes via graph traversal (e.g. "3rd cousin twice removed").
- **Sourcing integrity view** — accessible from Audit: "Show all facts with no source", "all facts whose only source is .manualEstimate". Helps users strengthen their evidence base.
- Tests: keyboard shortcuts trigger correct actions, tree arrow-key navigation follows family structure, search filters correctly, relationship calculator handles complex paths (half-siblings, step-relations)

### M12: Life Events + Fact Confidence + Unified Tasks
- **LifeEvent model** — `life_events` table with type, date range, location, description, sources, citations, confidence. 12 event types covering the full lifecycle.
- Census transcription mode updated: creates `LifeEvent` records (census, occupation, residence) instead of bio text.
- **FactConfidence** — tentative / standard / well-evidenced on FieldSource and LifeEvent. Visual indicators (dashed underline for tentative, checkmark for well-evidenced).
- **Unified Tasks view** — replaces separate Audit and Gaps sidebar items. Single prioritised list with source badges (Audit/Gap/Question/Tentative). Filters by source type. Group by profile or flat list.
- Timeline view updated: reads LifeEvent records alongside profile fields. Duration events (residence, occupation) shown as ranges.
- Tests: life event CRUD, census mode creates events, confidence indicators render correctly, Tasks view combines audit+gaps+questions, Tasks filtering works, timeline shows life events chronologically

### M13: Source Attachments + Research Goals
- **Attachment model** — `attachments` table. Photo (JPEG/HEIC/PNG), document (PDF), transcription (text). Per-project media directory.
- EXIF extraction for auto-dating and location on photo import.
- Thumbnail generation for gallery views.
- Inline viewer in profile inspector and timeline (photos, PDFs).
- GEDCOM export: `OBJE` tags (5.5.1 file references, 7.0 GEDZip).
- Reports include photos and document scans.
- `.ancestor` project archive format: SQLite + media directory, zipped.
- **ResearchGoal model** — `research_goals` table. Title, description, progress, attached questions/hypotheses/focus sets. Goals section at top of Workbench. Session resume shows active goals with progress.
- Tests: attach photo to profile, EXIF extraction, thumbnail generation, PDF viewer, GEDCOM export with OBJE, project archive round-trip, goal CRUD, goal progress tracking, session resume shows goals

### M14: Data Sovereignty + Progressive Disclosure
- **Sensitive data flag** — `sensitive: Bool` on WorkbenchNote and LifeEvent. "Exclude sensitive items from export" toggle.
- **Hard delete** — "Permanently remove" from Settings → Deleted People. Removes all traces (profile, field changes, events, attachments, workbench references).
- **Automatic backup** — project database copied on launch. 10 retained per project. Corruption detection and restore flow.
- **Progressive disclosure** — sidebar items appear when content is non-empty or tree crosses size thresholds. Advanced sections start collapsed. Guidance language activates for small manual-entry projects. Session resume as default launch for experienced users.
- Tests: sensitive flag excludes from export, hard delete removes all references, backup creation on launch, backup restore after corruption, sidebar items appear/hide at thresholds

---

## 10.5 Navigation Architecture

The app has many distinct views. Not all belong in the sidebar — that would be crowded. Navigation is layered:

| Level | Views | Pattern |
|-------|-------|---------|
| **Window** | `ProjectPickerView` | Shown when no project is open. Replaced by main view on project open. |
| **Sidebar** | Tree, Tasks, Workbench, Settings | Primary navigation. Always visible. 4 items. Tasks unifies audit issues, gaps, and open questions (§7.13). |
| **Inspector** | `ProfileDetailView`, `ProfileHistoryView`, `ProfileTimelineView` | Right panel, tabbed, appears on node selection in tree. |
| **Sheet/Modal** | `NewProjectView`, `OnboardingWizardView`, `AddPersonView`, `AddFamilyView`, `EditPersonView`, `AddRelationshipView`, `ConflictResolutionView`, `TreeDiffView` | Presented modally for focused tasks. |
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
| 17 | **Onboarding wizard (standard)** | "Start from scratch" → "No, straightforward" → wizard: self + parents + per-branch grandparents → 7 profiles created → 3-generation pedigree visible → completion toast with [Undo wizard] |
| 18 | **Wizard (non-standard family)** | "My parents divorced/remarried" → Step 2 supports two parent couples → biological + step parents created with correct subtypes |
| 19 | **Wizard (adoption)** | "I was adopted" → Step 2 labels as "Adoptive parents" → optional biological parents section → subtypes set correctly |
| 20 | **Wizard grandparent skip** | Skip paternal grandparents → proceed to maternal grandparents → only maternal grandparents created → paternal gap shown in Gaps view |
| 21 | **Home person** | Wizard sets home person → tree anchored → "Show ancestors" works → change in Settings → confirmation → tree re-orients → data preserved |
| 22 | **Family group entry** | "Add Family" → parents (one existing, one new) + 3 children (one existing, two new) → all linked in one transaction → single undo removes new profiles |
| 23 | **Census transcription** | Add Family → toggle census mode → enter year 1881, ages → birth years computed → birthplaces captured → source auto-set to "official record" |
| 24 | **Manual add person** | Add person with partial data → completeness shows guidance ("What you might add next") → date-range-aware hints shown |
| 25 | **Connection requirement** | Toolbar "Add Person" with existing tree → "Related to" required → context-menu "Add Parent" → no picker (implicit) → "Add as unconnected" override works |
| 26 | **Person attributes** | Add profile: `NameStatus.unknown` + `LifeStatus.infantDeath` simultaneously → shows "?" muted in tree → exempt from completeness |
| 27 | **Edit with source badges** | Edit imported profile → source badge per field → click badge → see all sources → choose "Correct" → value replaced. Choose "Record alternative" → dispute created |
| 28 | **Soft delete + branch delete** | Add 5-person branch → "Remove this person and all descendants" → all 5 hidden → visible in Settings "Deleted People" → restore → all reappear |
| 29 | **Date parse preview** | Type "circa 1890" → preview "Approximately 1890 (range: 1885–1895)". Type "1880s" → "Between 1880 and 1889". Type "hello" → parse error |
| 30 | **Source context defaults** | Add home person → source defaults to "I remember this". Add grandparent → defaults to "Family member told me (from: [parent name])" |
| 31 | **Import after manual** | Enter 3 people manually → import GEDCOM with overlapping profiles → merge dialog → merge → sources combined, no duplicates |
| 32 | **Sibling shortcut + placeholder resolution** | Person with no parents → "Add Sibling" → placeholder parents created → later "Add Parent" → prompt to replace placeholders → accept → sibling links transfer |
| 33 | **Disconnected detection** | Two unconnected profile groups → tree shows separate islands → "Connect these?" banner → link them → single tree |
| 34 | **Privacy export** | Mark person as living-private → GEDCOM export with "exclude living" on → exported file has `RESN privacy` tag → name shows "[Living]" |
| 35 | **Manual undo chain** | Add person → add relationship → undo add person → both person and relationship removed |
| 36 | **Auto-suggestions** | Enter 3 profiles with "Belper" → 4th location suggests "Belper". Add sibling of "Land" → surname suggests "Land". Add spouse → doesn't suggest "Land" |
| 37 | **Name normalisation** | Enter "  William   Land  " → saved as "William Land". Enter 200-char name → warning shown. Enter whitespace-only → rejected |
| 38 | **Wizard Step 4 (spouse/children)** | "Do you have a spouse or children?" → enter spouse + 2 children → all linked to home person → tree shows nuclear family |
| 39 | **Notes** | Create note on profile → `[[other person]]` link → click link → navigates to that profile → note visible in profile inspector |
| 40 | **Open questions** | Audit flags "missing parents" → promote to question → add tried sources → mark resolved → question closed |
| 41 | **Hypotheses** | Create "Thomas is son of William" hypothesis → add supporting evidence → promote to fact → relationship created in tree with solid line → hypothesis status = promoted |
| 42 | **Hypothesis dismissal** | Create hypothesis → add contradicting evidence → dismiss with reason → hypothesis searchable → same claim not re-suggested |
| 43 | **Uncertainty layer** | Hypothetical relationship → dashed line in tree → hypothetical person → ghost node → toggle overlay off → all indicators hidden → tree looks clean |
| 44 | **Focus set** | Pin 3 profiles → "Focus only" toggle → tree shows only focused profiles + connections → switch focus set → tree updates |
| 45 | **Session resume** | Work for 1 hour → close app → reopen → resume screen shows summary + open questions + active hypotheses → "Continue" restores focus |
| 46 | **Session log** | Complete 3 sessions → session list shows summaries with duration, counts → sessions survive restart |
| 47 | **Notes search** | Create 5 notes mentioning "Wirksworth" → search "Wirksworth" → all 5 found via FTS |
| 48 | **Third destination** | Research produces 3 candidates → capture as 3 hypotheses → investigate over time → promote best → dismiss others with reasons |
| 49 | **Profile timeline** | Profile with birth, marriage, death → timeline shows 3 events chronologically → sources shown per event → workbench note appears inline at its date |
| 50 | **Citations** | Add person with citation (repository, page) → source badge shows citation → GEDCOM export includes SOUR + PAGE + QUAY tags → other software reads citation |
| 51 | **Pedigree chart** | Select home person → generate 4-gen chart → PDF shows 15 profiles with dates → export at A4 → print-ready |
| 52 | **Family group sheet** | Select family → generate sheet → parents + children with dates/locations/sources → citations as footnotes |
| 53 | **Narrative report** | Generate for profile with 5 events + 2 sources → readable biography → footnoted citations → export as Markdown |
| 54 | **Research report** | Generate from focus set with 3 questions + 2 hypotheses → report shows scope, investigated, findings, open items |
| 55 | **Keyboard workflow** | Cmd+N → add person form → tab through fields → Enter → person created → arrow keys navigate tree → Cmd+E → edit form |
| 56 | **Tree search** | Cmd+F → type "Land 1830-1850" → results show matching profiles → arrow keys navigate results → Enter selects |
| 57 | **Relationship calculator** | Select distant relative → inspector shows "3rd cousin twice removed of [home person]" → calculation correct for half-siblings |
| 58 | **Backup and recovery** | Work on project → quit → relaunch → verify backup exists in backups directory → corrupt database → app offers restore from backup |

---

## 12. Critical Analysis

### Strengths

**Product differentiators (no mainstream competitor has these):**
- **Hypothesis model** — four claim types (relationship, fieldValue, identityMatch, existence) with structured evidence and confidence. Family Tree Maker has "alternate facts." Roots Magic has to-do items. Neither has a coherent model of tentative claims that resolve to committed facts. This is genuinely novel.
- **Session resume** — the app remembers what you were working on and offers to continue. No genealogy software does this. The closest analogues are in writing apps (Scrivener) and project management tools, not genealogy. For research done in stolen hours over months, this is transformative.
- **Uncertainty layer in the tree** — dashed lines, ghost nodes, italic text. The tree is visually honest about what's confirmed and what's tentative. No consumer genealogy tool expresses uncertainty in the tree visualisation itself.
- **Merge policy with named rules** — most genealogy software either silently overwrites or creates duplicates. The explicit dispute model with documented merge rules (range arithmetic, corroboration detection, union-range audit) is more sophisticated than what users have seen.
- **Formally specified audit engine** — invariants, fire conditions, worked examples per rule. Most genealogy software has black-box validation. The transparency of documenting every rule with a worked example is a real product attribute.
- **Time-bounded facts** — life events with date ranges, sources, and citations. Most genealogy software stores occupation as a single field that gets overwritten. This product tracks three occupations in three decades.
- **Source-aware manual entry** — "where did this come from?" at entry time, with four tiers. Captures evidence quality at the moment the user knows it best.

**Architecture strengths:**
- **Snapshot concurrency model** — natively Sendable, undo for free, clean SwiftUI consumption
- **Range-based dates** — prevents false positive audit errors on approximate dates
- **GEDCOM round-trip** — validates the data model. If it round-trips, the model is sound
- **SQLite via GRDB** — transactional, incremental, scalable. No JSON bottleneck. Open format for data sovereignty.
- **Hierarchical layout** — matches genealogical conventions, much better than force-directed for family trees
- **Data sovereignty** — no accounts, no cloud dependency, no lock-in. SQLite + GEDCOM = the user always owns their data.

**UX strengths:**
- **Onboarding wizard** — adapts to non-standard families (adoption, divorce, step-parents). First-session success metric ensures a visible 3-generation tree in under 10 minutes.
- **Unified Tasks view** — one place for audit issues, gaps, open questions, and tentative facts. Not three separate lists.
- **Progressive disclosure** — the product adapts to what the user has done, not a "beginner mode" toggle.

### Risks
1. **Hierarchical graph layout is hard** — Reingold-Tilford and Sugiyama are non-trivial algorithms. May need a library or significant implementation effort. Most likely milestone to overrun.
2. **Liquid Glass is brand new** — WWDC25 APIs may have bugs. Mitigation: standard SwiftUI first, Liquid Glass pass at M6.
3. **GEDCOM parsing edge cases** — real exports are messy. `GenealogicalDate` parser is critical path. Test with actual exports from WikiTree and Ancestry early in M2.
4. **GRDB learning curve** — well-maintained but new dependency. Schema design needs to support the snapshot + transaction pattern efficiently.
5. **Conflict resolution UX** — `TreeDiffView` and `ConflictResolutionView` are the trust-building views. They deserve design attention (mockups, UX flow) disproportionate to their code complexity.
6. **FamilySearch assumption** — post-MVP roadmap assumes FS will approve the app. An email to FS DevRel is free insurance. Decision: build first, but this risk is acknowledged.
7. **Workbench scope creep** — The workbench has six phases (W1–W6). The phasing is designed so each phase is independently shippable, but the temptation to build everything before shipping is real. Mitigation: ship W1 (notes) as soon as it works; each subsequent phase ships independently.
8. **Uncertainty layer rendering** — Dashed lines, ghost nodes, and overlay indicators add visual complexity to the tree graph. Needs careful design to avoid clutter, especially on dense trees. The toggle (Settings → "Show research indicators") is the safety valve.

### Known Ceilings (acceptable for MVP, document for post-MVP)
- **Snapshot copy cost** — at 10k profiles, snapshot rebuild copies entire dictionary. Persistent data structures (HAMT) would help at 100k+ but not needed now.
- **Transaction table growth** — unbounded over years of active use. Post-MVP: "compact history" operation that collapses old transactions into a baseline.
- **Location field disputes** — "London, England" vs "London, UK" will generate false disputes. Post-MVP: location gazetteer normalisation + user-defined equivalences.

---

## 13. Beyond End-State — Platform Extensions

These are outside the end-state product vision. They represent a different category of product — platform features that could extend Ancestor Research but are not part of the core research tool.

### Data Sources
- **FamilySearch OAuth** — OAuth 2.0 PKCE flow, pedigree import, record hints, deep links. See §7.17
- **Geni.com API** — OAuth 2.0, World Family Tree import. See §7.17
- **GEDCOM 7.0** — extend parser for 7.0 headers, UTF-8 mandate, GEDZip support. See §7.17
- **Gramps Web API** — REST API for self-hosted Gramps instances. See §7.17

### Map View
- Geographic visualisation of ancestor locations over time. Reads existing location data — no new entry needed.
- Timeline slider: show where the family was at different points in time
- Migration paths: animated lines showing geographic movement across generations
- **Value:** far more accessible for non-genealogist family members than a tree diagram

### Multi-Window
- Open two profiles side by side for comparison
- Shared snapshot state — both windows see the same data
- SwiftUI `WindowGroup` with profile ID as scene data

### Mobile Companion
- Read-only iOS companion app or web export. Tree browsing, profile viewing, photo gallery — no editing.
- Share via iCloud or export as self-contained HTML bundle
- **Essential for:** showing the tree at family gatherings, checking facts while visiting archives

### Configurable Audit Rules
- User-toggled rules, user-tuned thresholds, rule snoozing, custom rules
- All changes stored per-project. Default rules unchanged.

### Enrichment Pipeline
- Python API server — enrichment only (LLM, sources). Calls Swift for audit via IPC.
- Leads & Facts UI, research pipeline with SSE progress streaming
- Source contribution — write sources back to FamilySearch

### Collaboration Extensions
- **Share read-only link** — publish tree as static HTML
- **Import corrections as suggestions** — relative's changes arrive as hypotheses, not auto-committed facts
- **Cloud sync** — investigate CloudKit or CRDTs for multi-device sync (single-user, not collaborative editing)

### Additional Views
- **Comparison view** — two profiles side by side for identity matching or sibling comparison
- **Statistics dashboard** — average lifespan, common surnames, geographic distribution, source coverage

### Accessibility
- High-contrast mode, VoiceOver for tree navigation, reduced-motion mode
- Dynamic type in all views (already required by AppTypography convention)
