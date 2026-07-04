# PUBLISHER_SPEC — Family Tree Publisher

**Status:** Draft v1.1 (2026-07-04) — v1 revised after two-agent adversarial review (codebase-contradiction + completeness); all blockers folded in. No changes started.
**Governing context:** `ARCHITECTURE_REVIEW_2026-07.md` Phase 3 (architecture adjudicated there: publisher over synced store).
**Supersedes:** DESIGN.md §13's "Mobile Companion" / "Share read-only link" / "Cloud sync" bullets, and amends DESIGN.md §7.14/§7.15's no-cloud posture (opt-in, derived-snapshot-only).

---

## 1. Purpose

Let family members view the tree — on iPhone, iPad, and Apple TV — without the researcher giving up anything: the canonical GRDB research database stays local and untouched, a **derived, redaction-filtered, read-only snapshot** is published to CloudKit, and invited family read it from their own iCloud accounts. Explicitly *not* goals of this spec: family contributions, editing from any second device, real-time freshness, public no-sign-in access, and the viewer apps themselves (Phase 4; their data contract is §4).

**Why publisher, not sync** (decided in the review; summarised for future readers): single writer = no conflicts by construction; the canonical store is never at risk (the cloud copy is disposable — republish fixes anything); redaction is one publish-time filter instead of a permanent two-zone partition; the 29-migration engine schema (FTS5, triggers, DB-as-IPC queues, undo log) never has to survive eventual consistency; and read-only CloudKit participants give the Evidence Firewall a server-enforced mechanism. Revisit trigger: if family contribution or iPad authoring becomes a goal, see the review's "synced store" alternative and its costed migration.

## 2. Architecture

```
Mac app (single writer)                                   Family devices
┌─────────────────────────┐                               ┌──────────────────┐
│ GRDB project DB          │   Publish (explicit action)  │ sharedCloudDatabase│
│ (canonical, unchanged)   │ ──► PublishedTree projection │  └ zone replica   │
│                          │      └ redaction filter      │ CKFetchRecordZone- │
│ published_state (local)  │ ──► presence diff → batched  │ ChangesOperation + │
│ published_ids   (local)  │      CKModifyRecords ops     │ change tokens      │
│ publish_meta    (local)  │              │               │ local cache        │
└─────────────────────────┘              ▼                │ TreeLayout +       │
                       Owner's private CloudKit DB        │ TreeCanvasRenderer │
                       1 custom zone per project          └──────────────────┘
                       (zone name = project UUID — display names get renamed)
                       zone-wide CKShare, participants .readOnly
```

Load-bearing platform facts (verified July 2026, sources in the review):
- **SwiftData has no shared-DB support** (as of appleOS 27) — not a candidate.
- **tvOS supports CloudKit fully but has no share-acceptance UI**: each family member accepts the invite once on iPhone/iPad/Mac; the zone then appears on all their devices including Apple TV. Onboarding copy must say this.
- **Zone-wide CKShare**: ~100 participants, any iCloud account (no Family Sharing needed), per-participant `.readOnly`.
- **Production CloudKit schemas are additive-only and deploy is one-way** → all record types versioned from day one (`Person_v1` → `Person_v2`, never mutate).
- 1 MB/record; photos as `CKAsset`; the shared zone bills the **owner's** iCloud quota.
- **Plumbing decision is gated on a spike (Change 3)**: Point-Free `SQLiteData` (GRDB-based CKSyncEngine wrapper with enforced read-only CKShare) vs hand-rolled CKSyncEngine.

**Single-writer is enforced, not assumed** (a second Mac on the same iCloud account, or a Time-Machine-restored container, has stale local state): before any modify batch, PublishEngine fetches `TreeManifest_v1`; if the server `generation` exceeds the local `publish_meta.generation`, abort with a "this tree was published from another Mac — a full republish is required" prompt. The manifest save uses `.ifServerRecordUnchanged` so concurrent publishers lose deterministically. Full republish (nuke zone + rebuild) is a first-class recovery, not a dev hack.

## 3. Trigger model

- **Explicit "Publish Tree…"** toolbar/menu action is the primary trigger. Never mid-research-run.
- Publish = project → presence-diff against `published_state` → delete batches (dependents before persons) → upsert batches → bump `TreeManifest.generation` **last**.
- The generation is a **freshness signal, not an atomicity guarantee**: a viewer doing an initial fetch mid-publish can see a partial zone (records carry no generation tag). Viewer obligations in §4.3 make this benign.
- **Change 7 (optional, later):** debounced auto-publish after ApplyEngine commits — see Change 7's review-screen precondition.

## 4. Published schema v1 (the viewer contract)

### 4.1 Identity

Record names are **fresh UUIDs** minted per published entity and remembered in the local `published_ids` table (`entity_kind, canonical_id, record_uuid, superseded_by NULL`). Rows are **permanent**: a person deleted, `omit`-flipped, or later re-added keeps the same `record_uuid` (stable identity; viewer caches never see duplicates). Canonical merge: the survivor keeps its `record_uuid`; the loser's row gets `superseded_by = survivor_uuid` and its record is tombstoned. The canonical `profiles.id` (heterogeneous GEDCOM xref / WikiTree name / UUID) never leaves the Mac.

### 4.2 Record types (all carry `schemaVersion: Int`)

| Record type | Fields (≤1 MB each) |
|---|---|
| `Person_v1` | displayName, givenName, familyName, genderRaw, birth + death date encodings (each: original, earliest, latest, qualifierRaw, isApproximate — the full `GenealogicalDate` five-field encoding; component-built dates aren't reparseable from `original` alone), birthPlace, deathPlace, bioText (Change 6; empty until then), citationsJSON, badgesJSON, isRedacted (Bool), isProvisional (Bool — no given name AND no vital facts; viewers render as ghost card) |
| `Relationship_v1` | fromPerson (recordName), toPerson, typeRaw (parent/spouse), roleRaw, subtypeRaw (biological/adoptive/step), marriage date encoding (five-field, as above), marriageLocation, divorce date encoding (five-field) — see §5 edge-redaction |
| `LifeEvent_v1` | person (recordName), kindRaw, date encoding (five-field), location, detailsJSON (typed payloads; household-member rule in §5), sourceURL? |
| `Media_v1` | person (recordName), asset (CKAsset), caption?, kind (`portrait` / `document`) |
| `TreeManifest_v1` | schemaVersion, generation (monotonic Int), rootPerson (recordName), personCount, relationshipCount, publishedAtISO |

Field derivations (nailed down so v1 is implementable):
- **citationsJSON** per field: source name = `Citation.collection ?? SourceOrigin.identifier`; url = `Citation.url`; trustTier = `SourceTierRegistry.lookup(url).trustTier.rawValue` (`SourceTrustTier`: community/transcription/primary), omitted when url is nil. **Never** derived from `SourceOrigin.tier` — that is the overwrite-policy provenance enum, not evidence trust.
- **badgesJSON**: completeness score/max from `FamilyGraphSnapshot.completeness(for:)`; convergence level from the latest completed run's `research_runs.result_json` envelope for the profile — absent (never researched, or pre-v29 run) ⇒ badge omitted. No publish-time recomputation.
- **Media**: `AttachmentType` mapping photo→`portrait`, document→`document`, transcription→**excluded** (transcription text belongs in citations, not the family gallery). Only attachments with `target_kind = profile` are publishable; lifeEvent/fieldSource-targeted attachments are excluded in v1 (decision log #7). There is **no** `Person_v1.portraitAsset` — viewers use the first `Media_v1(kind: portrait)` for the person; one canonical home per asset.
- Marriage location codes (`marriageLocationCode`) are engine-internal and not published.

Not published, ever (the projection enumerates *included* tables; it never enumerates exclusions): all research/engine tables (`pending_facts`, `scored_records`, `evidence_records`, `research_runs`/`_requests`/`_hypotheses`, `leads`, `record_rejections`, `negative_searches`, `page_cache`), workbench tables, `transactions`/`field_changes` undo log, `field_disputes`, non-opted-in attachments. TreeLayout ghost *nodes* are viewer-side synthesis, never records.

### 4.3 Viewer obligations

- Treat `generation` as a refresh/freshness signal only; render whatever is cached; never assume a fetch mid-publish is complete or consistent.
- Tolerate unknown record types and unknown fields silently (forward compatibility). If `TreeManifest.schemaVersion` exceeds the viewer's supported version, show "update the app to see the latest tree" over the cached copy.
- Handle `CKError.changeTokenExpired` by discarding the token and re-fetching the zone from scratch.
- Do not assume connectivity from `rootPerson`: disconnected components are published; reconcile completeness against `personCount`.
- `isRedacted` persons render as name-only cards (the distinction from "absent" is deliberate: family see the person exists).

## 5. Redaction & privacy (correctness-critical)

Storage facts: `sensitive` flags exist on `workbench_notes` and `life_events` (migration v11) — **profiles have no sensitive column**, hence the policy table below.

- **Per-person publish policy** in a new `publish_policy` table (`profile_id TEXT PRIMARY KEY, policy TEXT, acknowledged_at DATETIME?`): `auto` (default) / `full` / `nameOnly` / `omit`.
- **`auto` resolves via the existing `ProfileCompleteness.potentiallyLiving` heuristic** (`FamilyGraphSnapshot.swift` — no death date ⇒ living unless born >100 years ago; one definition, reused, not duplicated; the spec's earlier 110-year draft is superseded). Living ⇒ `nameOnly`; deceased ⇒ `full`. A death recorded without a date (death life-event or deathLocation but `deathDate` nil) still resolves living ⇒ `nameOnly` — the safe default; the pre-publish screen is where a human corrects it.
- **`nameOnly`** publishes displayName + relationship edges only: no dates, places, events, bio, media; `isRedacted = true`.
- **Edge redaction rule** (marriage facts are facts about *both* parties): a `Relationship_v1` touching an `omit` person is **not published at all**; one touching a `nameOnly` person publishes with marriage/divorce/location fields **stripped** (bare edge only). Parent edges to `nameOnly` persons publish bare (they're implied by the person's visibility).
- **Household-member rule** (`HouseholdMember` entries are free text with no profile linkage, so per-person policy cannot apply): household members inside `LifeEvent_v1.detailsJSON` are published only when the event year ≤ (currentYear − 100); otherwise the household array is stripped. With current sources (census ≤1911) this publishes everything historical while structurally excluding any hypothetical future recent-event household.
- `life_events` with `sensitive = 1` are excluded regardless of person policy.
- **Pre-publish review screen** (Change 4 UI): lists every person with resolved policy; all `auto→nameOnly` resolutions and every not-previously-acknowledged person require explicit acknowledgement (written to `publish_policy.acknowledged_at`) before first publish including them. Per-person overrides write `publish_policy`.
- **Redaction is a pure function** — `PublishPolicyResolver.resolve(profile:completeness:override:) -> ResolvedPolicy` — with its own test suite (Change 1 acceptance). This tree contains living and recently deceased people; a miss publishes third-party personal data to every participant.
- **Legal/store posture:** shipping Change 4 REQUIRES, in the same release: PRIVACY.md rewrite (the "not uploaded to any server" sentence becomes "…unless you explicitly publish a redacted snapshot to your own iCloud for people you invite"), App Store nutrition-label review, and review-notes language. Invite-only shared zone was chosen over the public DB specifically because of living-person data (GDPR-relevant third-party personal data). Unpublish (Change 5) is the erasure mechanism.

## 6. Changes (implementation order; each independently shippable)

### Change 1 — Projection + policy foundation (no CloudKit)
Migration `v30_publisher_tables`: `publish_policy` (§5), `published_ids` (§4.1), `published_state` (`record_uuid PRIMARY KEY, checksum TEXT`), `publish_meta` (one row: `generation INT, last_published_at`), `publish_media` (`attachment_id TEXT PRIMARY KEY` — presence = opted in). New `Services/Publish/PublishedTree.swift`: pure projection `PublishedTree.project(snapshot:lifeEvents:attachments:policies:mediaOptIns:) -> PublishedTree` (value types mirroring §4.2, no CK imports) + `PublishPolicyResolver` + `recordChecksum` (canonical deterministic serialization — also the Change 2 determinism basis).
**Acceptance:** resolver suite (living heuristics: no dates at all; born 99/100/101 years ago; death event without deathDate; explicit overrides); projection excludes engine data by construction; `nameOnly` persons carry zero dates/places/events/media; edge rule (omit ⇒ edge dropped; nameOnly ⇒ marriage fields stripped) tested both sides; household rule tested at the year boundary; merge/`superseded_by` identity tested; George Brooks project round-trips with expected counts.

### Change 2 — Export Family Bundle (offline artifact + permanent fallback)
"Export Family Bundle…" writes a folder/zip: `manifest.json`, `people.json`, `relationships.json`, `events.json`, `media/` — the §4 schema as JSON, **using the same `published_ids` UUIDs CloudKit will use** (viewer code prototyped on bundles works unchanged on zones). Export does **not** touch `published_state`/`publish_meta` (the first CloudKit publish must still see everything as new). This is DESIGN.md §13's companion-bundle idea, shipped before any CloudKit dependency; doubles as the publisher's test harness and the offline "family gathering" demo path.
**Acceptance:** bundle from the real project validates against a JSON-schema file checked in beside the spec; media files copied; a `validate_bundle` test target asserts redaction invariants on the artifact; re-export byte-identical modulo `publishedAtISO`.

### Change 3 — Plumbing spike (decision gate) — AMENDED 2026-07-04
**Decision (provisional, code-level analysis complete; runtime proof pending container): adopt SQLiteData 1.6.6 for the published store only.** Findings that decided it:
- SQLiteData has **no zone-wide CKShare** — only `CKShare(rootRecord:)` hierarchy sharing, and any table with 2+ real SQL foreign keys is excluded from sharing (`PRAGMA foreign_key_list`-based rule). §2's "zone-wide CKShare" is therefore **amended to a hierarchy CKShare rooted at the TreeManifest row** — functionally equivalent for this design (everything in the published store hangs off the manifest; one `share(record: manifest)` shares the tree; server-enforced read-only participants unchanged).
- **Published-store shape** (satisfies their single-FK-chain rule): `Manifest` (no FKs, share root) ← `Person.manifestID` ← `LifeEvent.personID` / `Media.personID`; `Relationship.fromPersonID` is a real FK, **`toPersonID` is a plain TEXT column with no REFERENCES clause** — acceptable because the store is a projection rebuilt from canonical data; referential integrity is the projection's job, not the store's.
- Their table rules: TEXT primary key (`NOT NULL ON CONFLICT REPLACE DEFAULT (uuid())`), no UNIQUE on non-PK columns, ON DELETE CASCADE/SET NULL only, additive-only migrations — all compatible with §4.
- **Update rows in place; never delete+reinsert the same primary key** (their open issue #418, data loss on delete-then-reinsert). Our §4.1 permanent-UUID identity already implies update-in-place.
- Coexistence with the canonical GRDB store is supported (explicit table allowlist, separate metadatabase); one shared GRDB version resolves — we're on 7.10.0, they need ≥7.6.0 ✓.
- Their `CloudSharingView` is UIKit-only — Change 5 builds its own macOS invite/participant UI (already planned).
- Under this plumbing, `published_state` (v30) may go unused — the published store itself becomes the diff basis (publish = upsert/delete store rows from the projection; the library syncs deltas). Keep the table; revisit at Change 4.

**Runtime proof remaining** (needs container + management token, then headless): SyncEngine init validation passes on the five-table shape; records reach the dev environment; `share(record: manifest)` yields a working share. Phones validate participant read-only at Change 5.

**cktool operational notes** (verified locally, Xcode 26): no container creation, no zone create/delete (zones are made by app code or Console; `--zone-name` works on record ops); `import-schema` needs a management token; record ops in the private DB need a **user token**; production promote flow = `export-schema` from dev → versioned `.ckdb` in repo → import to production. Env vars `CLOUDKIT_MANAGEMENT_TOKEN`/`CLOUDKIT_USER_TOKEN` override stored tokens.

### Change 4 — PublishEngine + CloudKit stand-up
Container + entitlements; record types per §4 (dev environment; **promote to production only after Change 5 validates with a second account**); `PublishEngine`: presence diff (desired set from projection vs `published_state`; missing ⇒ tombstone delete, dependents before persons), per-record `recordChecksum` change detection, batched ~400-record ops, manifest bump last with `.ifServerRecordUnchanged` + the §2 second-Mac guard; resumable on partial failure (`published_state` reflects only server-acknowledged batches). Pre-flight: `CKContainer.accountStatus` must be `.available` (signed-out fails before any batch, specific message); `CKError.quotaExceeded` aborts cleanly. All failures surface through the app's persist/report convention — **no `try?` in the publish path**. "Publish Tree…" UI with progress + §5 review screen. PRIVACY.md + nutrition label in the same commit series.
**Acceptance:** publish real project; verify in CloudKit console; mutate one profile → republish uploads only the delta; flip a person full→omit → their records + edges tombstone; kill mid-publish → republish converges; publish attempt from a second container-copy aborts on the generation guard; signed-out and quota paths surface correctly; manifest generation strictly monotonic (survives nuke-and-republish via `publish_meta`).

### Change 5 — Share flow + unpublish
Zone-wide CKShare creation, invite management (add/remove participant, revoke), owner-side participant list UI. Onboarding copy: family accept on iPhone/iPad/Mac once; Apple TV then just works. Never touch `publicPermission` (reverting evicts all participants). **"Unpublish Tree…"**: deletes the CKShare (evicting participants), deletes the zone, clears `published_state` (keeps `published_ids` per §4.1 and bumps `publish_meta.generation`); deleting or archiving a project with a live zone prompts to unpublish first. This is the GDPR-erasure mechanism.
**Acceptance:** second real iCloud account accepts and fetches read-only; participant write attempts fail server-side; revocation removes access; unpublish leaves no zone; republish after unpublish reuses identities and a higher generation.

### Change 6 — Publish-time bio synthesis
Revive `NarrativeAssembler.templateNarrative` (deterministic; retained in Phase 0 step 5 for exactly this — do NOT route through `assemble`, whose sibling path calls the MLX model) → `Person_v1.bioText` for `full` persons. In scope: a `LifeEvent → NarrativeLifeEvent` adapter (templateNarrative's input type is currently only produced from research results). **Relative-redaction rule**: templateNarrative receives the resolved policy map; `nameOnly` relatives appear by displayName only, with no dates/places attached to them; `omit` relatives do not appear at all.
**Acceptance:** bios from committed facts only; `nameOnly` persons have empty bio; snapshot tests include a deceased subject with one living spouse and one omitted child.

### Change 7 — (Optional, deferred) auto-publish debounce
Hook on ApplyEngine commit → publish-dirty flag → debounce (e.g. 5 min idle) → background publish, **only when every person in the diff has an acknowledged policy** (`publish_policy.acknowledged_at` set); any new `auto`-resolved person parks the publish as dirty and badges the toolbar for manual review — auto-publish never bypasses the §5 human gate for new people. Deliberately last; requires soak evidence from Changes 4–5.

## 7. Risks

- **Wrong v1 record design is permanently sticky** (additive-only production schema) — mitigations: versioned types, promote only after Change 5, JSON bundle first, and the §4.2 field-derivation nail-downs from adversarial review.
- **Redaction miss = real personal-data exposure** — mitigations: pure-function resolver + dedicated suite + review screen + `nameOnly` default + edge/household/bio relative-rules (§5, Change 6).
- **Hand-rolled sync plumbing debugging** (if Change 3 rejects SQLiteData) — mitigation: cloud copy is disposable; unpublish + full republish is always valid recovery.
- **Owner quota**: media-heavy trees bill the owner's iCloud; media is opt-in per attachment (`publish_media`).
- **Second-Mac / restored-backup divergence** — §2 generation guard.

## 8. Decision log

1. Publisher over synced store — review §3; revisit trigger recorded in §1.
2. Invite-only shared zone over public DB — living-person data posture.
3. JSON bundle before CloudKit — de-risks schema freeze, permanent offline fallback, viewer prototyping contract (same UUIDs).
4. Per-person publish policy table over a profiles.sensitive column — profiles carry no sensitive flag today; policy is publisher-domain data, excluded from any future canonical sync.
5. Record names are publisher-minted permanent UUIDs — canonical heterogeneous IDs never leave the Mac; stable across delete/re-add/omit; merge via `superseded_by`.
6. Living-person heuristic: reuse `ProfileCompleteness.potentiallyLiving` (100-year rule) — one definition in one place; the publisher does not fork it.
7. v1 publishes only profile-targeted attachments; lifeEvent/fieldSource-targeted media excluded (additive to add later; the reverse is impossible).
8. Household members redacted by event-year rule (≤ currentYear − 100), not per-person linkage — `HouseholdMember` has no profile id; a deterministic year rule beats unimplementable cleverness.
9. SQLiteData over hand-rolled CKSyncEngine (Change 3 amendment, 2026-07-04) — hierarchy share rooted at TreeManifest replaces zone-wide share; `Relationship.toPersonID` demoted to plain TEXT to satisfy their single-FK sharing rule; update-in-place always (their #418).
