# PHASE4_VIEWER_SPEC — Family Tree Viewers (tvOS, iOS)

**Status:** Draft v1 (2026-07-09) — no changes started.
**Governing context:** `PUBLISHER_SPEC.md` §4 is the data contract this spec consumes; `ARCHITECTURE_REVIEW_2026-07.md` §3 adjudicated the publisher/viewer split and assessed UI portability.
**Order decision (supersedes the review's "iPad first"):** tvOS ships first, on the owner's own iCloud account — same-account access reads the published zone straight from the private database, needing no share acceptance (which tvOS cannot do anyway). The iOS viewer follows and adds CKShare acceptance for family on other iCloud accounts. Decision log #1.

---

## 1. Purpose

Read-only viewer apps for the published tree: first an Apple TV app for the owner's household, then an iPhone/iPad app that family members on **other** iCloud accounts use after accepting a share invite. Explicitly *not* goals: editing or contributing from any viewer (single-writer is the product model — standing user decision, 2026-07-04), research features, AI of any kind (bios are pre-synthesised at publish time), offline-first sync guarantees beyond a refreshable cache, and macOS viewing (the Mac app already renders the canonical tree).

What the two shells prove, deliberately in this order:
- **tvOS (same account):** production schema is consumable by a second platform; records round-trip; AncestorKit + the canvas renderer work off-Mac; the fetch/cache core design is sound. Proven against real data immediately (dev environment already holds the generation-3 publish, 967 records).
- **iOS (other accounts):** the actual sharing model — invite acceptance, participant read-only enforcement, revocation, and redaction as seen by a non-owner. This closes the acceptance items PUBLISHER_SPEC Change 5 deferred to Phase 4.

## 2. Architecture

```
Owner's iCloud account                        Family member's iCloud account
┌────────────────────────────┐                ┌────────────────────────────┐
│ private DB                 │   CKShare      │ sharedCloudDatabase        │
│  zone: co.pointfree.       │  (hierarchy,   │  owner's zone appears      │
│  SQLiteData.defaultZone    │   manifest-    │  after one-time acceptance │
│  (all published projects,  │   rooted,      │  on iPhone/iPad            │
│   manifest-lineage scoped) │   read-only)   │                            │
└──────────▲─────────────────┘                └──────────▲─────────────────┘
           │ .private scope                              │ .shared scope
        ┌──┴──────────────────────────────────────────────┴──┐
        │      AncestorViewerKit (new, platform-neutral)     │
        │  ZoneFetcher (CKFetchRecordZoneChangesOperation    │
        │   + change tokens, scope-parameterised)            │
        │  → RecordMapper (Person_v1… → AncestorKit models)  │
        │  → ViewerCache (GRDB, Caches dir, disposable)      │
        │  → FamilyGraphSnapshot                             │
        └──┬──────────────────────────────────────────────┬──┘
           │                                              │
   tvOS shell (Change 2)                          iOS shell (Change 3)
   focus-driven navigation                        touch canvas (pan/zoom)
   same-account only                              + share acceptance (Change 4)
        both render via AncestorKit TreeLayout/CanvasTransform
        + AncestorKitUI TreeCanvasRenderer (theme injected per platform)
```

Load-bearing facts (verified in-code 2026-07-09):
- **AncestorKit and AncestorKitUI have no AppKit/UIKit imports** — the renderer is pure SwiftUI `GraphicsContext` + `Path`; `TreeCanvasTheme` is injected by the host. The only porting gate is `AncestorKit/Package.swift:11` declaring `platforms: [.macOS("26.0")]`.
- **The published zone is `co.pointfree.SQLiteData.defaultZone` in the owner's private DB** — one zone for ALL published projects, isolated by manifest lineage (`Person_v1.manifestID` → manifest). Viewers must scope every query by the chosen manifest, and must tolerate rows from other manifests being present in the zone.
- **tvOS has no share-acceptance UI** (PUBLISHER_SPEC §2). Same-account access sidesteps this entirely for Change 2. For family later: they accept once on iPhone/iPad; the zone then appears on their Apple TV too — onboarding copy must say this.
- **Environment split:** dev builds (Xcode run) see the CloudKit *development* environment — which already contains real published data; TestFlight/App Store builds see *production* — empty until the first production publish. This makes the dev loop fast and makes the tvOS TestFlight build the natural companion to the first production publish.
- Records carry SQLiteData shadow fields (`sqlitedata_icloud_userModificationTime_*` etc.); §4.3 of PUBLISHER_SPEC already obliges viewers to ignore unknown fields silently.

## 3. The viewer data contract (pointer, not a copy)

PUBLISHER_SPEC §4 is authoritative: record types `TreeManifest_v1`, `Person_v1`, `Relationship_v1`, `LifeEvent_v1`, `Media_v1`; five-field `GenealogicalDate` encodings; `citationsJSON`/`badgesJSON`; `isRedacted` (render as name-only card, distinct from absent) and `isProvisional` (render as ghost card). The §4.3 viewer obligations are restated here as *requirements on AncestorViewerKit*, each with a test:

1. `generation` is a freshness signal only — render whatever is cached; never treat a mid-publish fetch as complete.
2. Unknown record types and unknown fields are ignored silently. If `TreeManifest.schemaVersion` exceeds the supported version, show "update the app to see the latest tree" over the cached copy.
3. `CKError.changeTokenExpired` ⇒ discard token, refetch the zone from scratch (this is also the tvOS purged-cache path — same code).
4. Do not assume connectivity from `rootPerson`; disconnected components exist; reconcile against `personCount`.
5. Deletions arrive as record tombstones in the change fetch (unpublish = row tombstoning); the cache must apply them.

## 4. AncestorViewerKit (the shared core — Change 1) — SHIPPED 2026-07-09

> **Shipped** (2 commits, 2026-07-09): `AncestorViewerKit/` package (7 sources, 26 offline tests green via `swift test`), AncestorKit/AncestorKitUI platforms extended and compiler-proven for `generic/platform=tvOS` + `iOS`, package wired into the app test target, and the live E2E (`ViewerLiveE2ETests`, env-gated `RUN_VIEWER_E2E=1`) green in 10s against the real dev-environment zone: 967 records fetched, profile/relationship counts reconciled exactly with the generation-3 manifest, redaction contract verified on real data, incremental refresh no-op confirmed. Implementation notes: all published fields are ENCRYPTED (read via `record.encryptedValues`; `asset` is the plain-ASSET exception); tombstones and id-fallback parse the `<uuid>:<tableName>` record-name convention; the cache has NO foreign keys on purpose (records arrive in arbitrary order mid-publish); no mock-container trap exists here — ZoneFetcher talks to CKContainer directly, so E2E runs are live by construction.

New SwiftPM package beside AncestorKit/AncestorKitUI. Depends on AncestorKit + CloudKit + GRDB. **Hand-rolled read-only fetch, not SQLiteData** (decision log #2): the viewer never writes, so a bidirectional sync engine is unwanted surface area (a viewer bug must not be *able* to push); PUBLISHER_SPEC §2's diagram already specifies `CKFetchRecordZoneChangesOperation` + change tokens for viewers; and one fetch core parameterised by database scope (`.private` for same-account, `.shared` for participants) covers both shells — SQLiteData's shared-DB consumer story would need its own spike for zero benefit here.

Components (all `Sendable`, no UI):
- **`ZoneFetcher`** — given container ID, database scope, and zone ID: initial fetch + incremental change fetch with persisted `CKServerChangeToken`; zone discovery for `.shared` scope via `fetchAllRecordZones`. Maps `changeTokenExpired` → full refetch. Never issues a modify operation (enforced by construction: the type wraps only fetch operations).
- **`RecordMapper`** — pure functions `CKRecord → StoreRow → AncestorKit model`: `Person_v1` → `Profile` (record UUID becomes `Profile.id`; five-field date encodings → `GenealogicalDate`), `Relationship_v1` → `Relationship`, `LifeEvent_v1` → `LifeEvent`, `Media_v1` → media metadata (CKAsset fetched lazily on display), `TreeManifest_v1` → manifest. Unknown fields ignored; decode failures skip the record and log, never crash the fetch.
- **`ViewerCache`** — GRDB database in the **Caches** directory (tvOS storage is purgeable; "cache vanished ⇒ full refetch" is a normal startup path, not an error). Tables mirror the five record types + one row for the change token, keyed by manifest. Rebuilding from CloudKit is always valid; the cache carries no state that cannot be refetched.
- **`SnapshotBuilder`** — cache → `FamilyGraphSnapshot` for one manifest lineage. Completeness badges come from published `badgesJSON` where present (never recomputed — publish-time values are canonical; local recomputation over a *redacted* projection would lie); persons without a badge get an empty-badge rendering.

**Testing without CloudKit:** the Change 2 family bundle (`Export Family Bundle…`) uses the same UUIDs and schema as the zone by design (PUBLISHER_SPEC decision #3). A `BundleBackedFetcher` test double feeds the exporter's JSON through the same mapper, so redaction invariants, snapshot construction, and viewer-obligation behaviours are all offline-testable. One env-gated live E2E (`RUN_VIEWER_E2E=1`) fetches the real dev-environment zone and asserts generation/person-count agreement with the manifest — same live-context discipline as the publisher E2Es (mock-container lesson, PUBLISHER_SPEC Change 4 correction).

**Acceptance:** AncestorKit/AncestorKitUI `Package.swift` platforms extended (`.tvOS("26.0")`, `.iOS("26.0")` added; macOS unchanged) and both packages build for all three platforms; mapper round-trips every §4.2 field including all five date encodings; redacted person maps to name-only `Profile` with zero vitals; tombstone application removes person + dependent rows from cache; token-expiry path refetches cleanly; schema-version guard triggers on manifest `schemaVersion + 1`; snapshot from the real family bundle matches expected person/relationship counts; live E2E green against the dev zone.

## 5. tvOS shell (Change 2) — IN PROGRESS (shell built 2026-07-09)

> **Built and simulator-verified** (commit e8c92fe): `Ancestor-Viewer-TV` target (created in Xcode by the user; packages wired by hand), ViewerModel state machine (loading / no-account / not-published / failed / ready, render-before-refresh from cache), TreeScreen (focus-driven canvas via TreeCanvasRenderer at fixed 1.15 scale, 3 generations; swipes move focal person and re-root; select opens PersonScreen; play/pause refreshes), FocusInfoPanel (glass, name + vitals + portrait + bioText; lock badge for redacted), PersonScreen (full bio, timeline, gallery, menu-button dismiss), AppTypography per convention. Renderer gained additive `showsCompletenessBadge` (default true; TV passes false — decision #4). Simulator screenshots verified: no-account state screen, and a DEBUG env-gated fixture tree (`VIEWER_FIXTURE=1`) showing pedigree + ghosts + redacted name-only spouse + bio panel. **Remaining acceptance:** real Apple TV, real 967-person tree via `.privateDatabase` (owner's account), every-person-reachable-by-remote pass, cache-purge cold path, VoiceOver pass, TestFlight build against production.

New app target **Ancestor for Apple TV** (working name; bundle `dev.dreamfold.Ancestor-Viewer-TV`), tvOS 26, in the existing xcodeproj. Entitlements: CloudKit, container `iCloud.dev.dreamfold.Ancestor-Research` (containers are per-team, shared across apps). Uses AncestorViewerKit with `.private` scope — **same-account only in this change**; the settings screen states plainly that the Apple TV must be signed into the same iCloud account that publishes the tree (family-member support arrives with the iOS viewer's share acceptance; an accepted share then appears on their TV via `.shared` scope — wired in Change 4, essentially free once the scope parameter exists).

Interaction model — **focus-driven, not free canvas panning** (the Siri Remote is not a trackpad; `TreeGraphView`'s existing arrow-key navigation + VoiceOver mirror already proved the tree is navigable as a focus graph):
- **Tree screen:** the canvas renders via `TreeCanvasRenderer` exactly as on macOS (theme: tvOS fonts + accent, larger node scale for 10-ft viewing), but navigation is focal-person movement — remote swipes move focus parent/child/spouse/sibling; select re-centres the layout on the focused person (TreeLayout's progressive-disclosure window already works this way on macOS). No pinch-zoom; fixed comfortable scale with re-centre-on-move.
- **Focus info panel (the primary reading experience):** whenever a person is in focus, a Liquid Glass panel beside the tree shows their name, vitals, portrait (if published), and `bioText` prose — family browse the tree and read lives without leaving the graph. `nameOnly`/redacted persons show the name card only (bioText is empty for them at publish time — by design, not a viewer decision); `isProvisional` ghosts show no panel.
- **Person screen:** select-and-hold (or a "more" affordance on the panel) opens the full person: complete bioText, life-event timeline, portrait + media gallery (CKAssets fetched lazily, cached in Caches). `isRedacted` persons get the name-only card; no detail screen.
- **Manifest picker:** if the zone holds multiple manifests, a picker on launch; one manifest auto-selects.
- **States:** no-iCloud-account, zone-not-found ("publish from the Mac app first"), stale-cache-refreshing, and the schema-version banner.
- **Styling:** native Liquid Glass throughout the chrome (standard SwiftUI components against the tvOS 26 SDK; overlays above the canvas use `.glassEffect`), full dark-mode support via semantic colors only — the injected `TreeCanvasTheme` must carry semantic (appearance-adaptive) colors and tvOS type sizes, never hardcoded values. The canvas itself is drawn content, not glass, matching the Mac app's composition (glass = chrome/overlays, canvas = content).

**Acceptance:** dev build on the household Apple TV renders the real 967-record tree from the dev environment; every person reachable by remote alone; focusing a `full` person shows their bio in the info panel, focusing a `nameOnly` person shows name only; redacted/provisional cards render per contract; kill + relaunch with network off renders from cache; cache deleted ⇒ silent full refetch; TestFlight build against production renders the production publish (this doubles as the production-publish verification from the owner's side). VoiceOver pass on tree + person screens.

## 6. iOS shell (Change 3)

New app target **Ancestor** for iPhone/iPad (bundle `dev.dreamfold.Ancestor-Viewer`), iOS 26. This is v1 of the primary customer-facing iOS app (iPhone-first market decision, 2026-07-04) — the shell is built expecting to grow authoring later, but this change ships viewing only.

- **Touch canvas:** full `CanvasTransform` pan/zoom with pinch + drag (the transform is already the single source of truth for hit-testing on macOS; gestures map straight onto it), tap = select, person detail as sheet. iPad gets the same app with layout affordances, not a separate target.
- Same-account `.private` scope works from day one (the owner's own iPhone is the second proof device, zero sharing needed).
- Reuses every screen concept from Change 2 (person detail, manifest picker, states); the shells share SwiftUI views where the input model allows, but **no forced abstraction** — a duplicated simple view beats a platform-conditional one.

**Acceptance:** owner's iPhone renders the tree via `.private` scope from production; pan/zoom/tap hit-testing correct at all scales; person sheet parity with tvOS person screen; works on iPad.

## 7. Share acceptance + participant validation (Change 4)

The deferred PUBLISHER_SPEC Change 5 acceptance items, now executable because a client app exists:

- **Acceptance flow:** CloudKit share URL → `userDidAcceptCloudKitShareWith` scene-delegate path → `CKAcceptSharesOperation` → zone appears in `sharedCloudDatabase` → AncestorViewerKit `.shared` scope fetch. Onboarding copy for the no-account / declined states.
- **tvOS `.shared` wiring:** once a family member has accepted on iPhone/iPad, their Apple TV sees the zone — the tvOS shell gains the `.shared` scope probe (try shared first, fall back to private) and the onboarding copy PUBLISHER_SPEC §2 requires.
- **Validation matrix (Darryl's second iPhone, separate iCloud account):** participant fetches and renders read-only; participant write attempt fails server-side (proven by a debug-only harness hook, not shipped UI); owner revokes → participant loses access on next fetch (graceful "no longer shared" state, cache cleared); owner unpublishes → tombstones propagate; redaction audit **as the participant**: nameOnly persons show name only, omitted persons absent, stripped edges carry no marriage data, household rule holds.

**Acceptance:** the full matrix above, live, against production, from the second-account iPhone. This is the moment "family invites possible" becomes true.

## 8. Risks

- **Wrong assumption about shared-DB fetch shape** — mitigations: scope is a parameter from day one; a `.shared` smoke test runs in Change 4's first week (fetch-only, before UI); fallback is fetching via share metadata's zone ID directly.
- **Zone co-tenancy** (all projects in one zone): a viewer that forgets manifest scoping renders a merged multi-project tree — mitigation: `SnapshotBuilder` takes a manifest ID as a required parameter; the cache schema keys every row by manifest; a test publishes two fixture manifests and asserts isolation.
- **tvOS purged cache mid-demo** — mitigation: refetch-from-scratch is the tested cold path, and the manifest's `personCount` gates "ready to render" so a partial refetch never shows a half tree silently.
- **Media quota/latency on TV** — CKAssets lazy-fetched and size-capped in the gallery; portraits cached; never block the tree render on media.
- **App Store posture:** the viewer apps ship with the same PRIVACY.md stance as the publisher (data comes only from the user's/inviter's iCloud; no third-party services, no AI). Nutrition labels for the two new apps in the same release as their store submission.

## 9. Decision log

1. **tvOS first, same-account, then iOS with share acceptance** (user, 2026-07-09) — supersedes ARCHITECTURE_REVIEW §5's "iPad first". Rationale: same-account access needs no share-acceptance UI (which tvOS lacks), the dev environment already holds real data, and the household TV is a natural first surface. The sharing model itself is explicitly *not* proven until Change 4.
2. **Hand-rolled read-only fetch (CKFetchRecordZoneChangesOperation + change tokens), not SQLiteData, in viewers** — viewers must be structurally unable to write; one scope-parameterised fetcher covers private and shared databases; matches PUBLISHER_SPEC §2's original viewer diagram. SQLiteData remains publisher-side only.
3. **Separate viewer app targets/bundles sharing the publisher's CloudKit container** — the Mac research app and the viewers are different products with different store postures; the container is the shared contract.
4. **Badges from published `badgesJSON`, never recomputed viewer-side** — publish-time values are canonical; recomputation over a redacted projection would misreport.
5. **Cache lives in Caches and is disposable by design** — tvOS storage rules make purge a normal path; one cold-start code path (initial fetch) serves first-run, purge, and token-expiry alike.
6. **Focus-driven tvOS interaction, not canvas panning** — Siri Remote reality; re-centre-on-focal-person reuses TreeLayout's existing progressive-disclosure window.
7. **iOS viewer bundle is the future primary iOS app** — named and structured for growth (per the iPhone-first market decision); viewing-only at this phase.
