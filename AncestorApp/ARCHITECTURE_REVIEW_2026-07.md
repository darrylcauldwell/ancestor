# Architecture Review — July 2026

Status: review artefact (not a spec). Produced 2026-07-04 from an 11-agent survey: seven codebase readers (engine, sources, data model, UI, AI tier, Python/MCP, specs), two web researchers (CloudKit sharing, on-device model landscape as of WWDC 2026), and two rival target-architecture proposals. Full structured findings archived in the session scratchpad.

Owner's stated goals:
1. A product to research his ancestry AND display it to family visitors.
2. Database in a CloudKit shared zone so family iCloud accounts can view, enabling iPad and tvOS visualisation.
3. AI tier: app as harness around a local open-weight model, optional server API, question open on CoreML/Apple Intelligence.

---

## 1. Verdict on the as-built architecture

**The organic growth produced a better architecture than feared.** The load-bearing decisions are sound and consistently enforced:

- **The deterministic sandwich is structurally real, not aspirational.** The live LLM surface is exactly four call sites (Level-1 source hint, Level-2 focused-query strategist, candidate-comparison prose, prose-corpus extraction), every one guards `isAvailable`, has a deterministic fallback, and re-enters the pipeline through the same `RecordScorer`. `DeterminismBoundaryTests` pins the boundary. The app is fully functional with no model installed.
- **The core engines are pure and portable.** `RecordScorer`, `ScoringRules`, `ClusteringEngine`, `ConvergenceEngine`, `BiographicalFitEvaluator`, `BirthYearConsensusDetector`, `GPSScorer` are nonisolated static functions over `Sendable` value types; 53/55 Research files import only Foundation. They compile for iOS/tvOS unchanged.
- **Persistence is behind one seam.** `ProjectDatabase` (+12 extensions); only 4 call sites outside it touch `dbQueue`. Domain models are plain Codable structs, not GRDB records — an alternative store can reuse them unchanged.
- **The source plugin layer has a genuinely uniform protocol** (`RecordSource` + `SourceQueryResult` 5-case result enum), circuit breakers on the fragile volunteer services, and region knowledge as bundled data (1,125-district FreeBMD catalogue) rather than code.
- **Test density is high**: ~1,600+ `@Test` functions incl. scorer-gate, firewall, determinism-boundary, and overwrite-policy suites.

Scale: app 290 files / 72.3k lines (Services 41k, Views 22.4k); tests 163 files / 34.3k lines; Python reference 12k lines; MCP server 2.7k lines.

## 2. Where the organic growth actually hurt

Ranked by how much they block the three goals:

| # | Debt | Evidence | Why it matters |
|---|------|----------|----------------|
| 1 | **Three write/accept paths** | `ResearchViewModel.apply*` (1,743-line ViewModel), `RunRequestWatcher.autoAcceptStronglySupportedProposals`, `PlaceholderWriteback.apply` | Already produced real bugs (accept-flow gaps memory). Any publish/sync layer needs ONE choke point. Extract an `ApplyEngine` service. |
| 2 | **No module separation** | Everything in one macOS app target | Every platform goal starts by carving an `AncestorKit` SwiftPM package (Models, GenealogicalDate, FamilyGraphSnapshot, trust-tier types, Canvas layout core). |
| 3 | **God files** | `ProjectDatabase` 2,819; `ResearchPipeline` 2,069 (per-slice flow methods accreted); `AppState` 2,047/94 funcs; `MCPServer` 2,721 single file, untyped JSON | Merge friction; `AppState` welds project lifecycle to local sqlite paths, blocking any alternate data source. |
| 4 | **`try?` swallowing in apply/persist paths** | ~15 sites in `ResearchViewModel` | Failed writes are silent — user believes a cluster applied when nothing persisted. Contradicts own conventions. |
| 5 | **MainActor-everything** | `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` + explicit `@MainActor` on pipeline/dispatcher | Fine on Mac, blocker for research on iPad; pure engines already escape, orchestrator doesn't. |
| 6 | **DBY residue** (invariant violation) | `ClusteringEngine.swift:18,143`, `FreeCenSource.swift:73`, `FreeREGSource.swift:78` | The follow-up audit flagged 2026-06-02 was never done; non-Derbyshire projects silently get DBY scoring/searches. |
| 7 | **Dispatcher owns per-source query strategy** | ~300-line string-keyed switch in `SearchDispatcher.buildQueries` (263–552) | Plugin encapsulation is illusory; an 8th source touches 3–4 files. Move a `buildQueries` hook onto `RecordSource`. |
| 8 | **Schema drift** | 6 rowid-PK tables; heterogeneous `profiles.id` (GEDCOM xref / WikiTree name / UUID); soft FKs everywhere; duplicate table families (`research_records` vs `evidence_records`, `hypotheses` vs `research_hypotheses`, dead `record_rejections`, dead `field_researcher_sessions`) | Only matters if the canonical store ever syncs; the publisher approach (below) sidesteps it. |
| 9 | **Dead code** | ~600 lines caller-less interpreter AI (evaluateCluster/disambiguate/NarrativeAssembler LLM path), ~1,700 lines Playwright WikiTree write-back (account blocked), 3 divergent JSON parsers, DeepSeek default never flipped to Qwen | Misleads architecture reasoning; fenced-JSON output from weaker models silently dropped. |
| 10 | **Doc rot** | App CLAUDE.md claims 5 migrations/168 tests (reality: 30/~1,579); DESIGN.md still declares "single-user, no-cloud" (§7.14/§7.15) and a superseded Python-server AI plan; PRIVACY.md says data never leaves the device | DESIGN.md and PRIVACY.md are actively hostile to the new goals as written; both need supersession work as part of any CloudKit step. |

Also noteworthy: parser-fixture coverage exists only for FreeBMD/FindAGrave/CWGC — the four most regex-heavy parsers (Wirksworth, FreeREG, FreeCen detail, Probate) have no offline regression protection; `HuggingFaceDownloader` buffers multi-GB safetensors fully in RAM with no resume.

## 3. CloudKit + iPad/tvOS: recommendation

**Recommendation: the publisher pattern, not a synced canonical store.** Keep GRDB local and canonical; add an explicit "Publish Tree" step that projects a denormalised, redaction-filtered, read-only snapshot into ONE custom CloudKit zone in your private database, shared via a single zone-wide `CKShare` with all family participants `.readOnly`.

Key external facts (researched, mid-2026):
- **SwiftData still has no shared/public database support as of WWDC 2026 / appleOS 27.** Do not wait for it.
- **`NSPersistentCloudKitContainer`** would mean migrating to Core Data — disproportionate for a viewing requirement.
- **`CKSyncEngine`** is the sanctioned path for non-Core-Data stores. **Point-Free's SQLiteData** (GRDB-based, CKSyncEngine + zone-wide CKShare with enforced read-only, v1.6.6 June 2026) is worth a 1–2 week spike for the *snapshot store*; hand-rolled CKSyncEngine is the fallback.
- **tvOS supports CloudKit fully but has no share-acceptance UI.** Family accept the invite once on iPhone/iPad/Mac; the shared zone then appears in `sharedCloudDatabase` on all their devices including Apple TV. (~100 participants per share; any iCloud account; Family Sharing not required.)
- **CloudKit production schema is additive-only and deploy is one-way** — version record types from day one (`Person_v1`…).
- 1 MB/record; photos as `CKAssets`; private/shared zones count against the OWNER's iCloud quota.
- **Living-person data**: invite-only shared zone (not the public DB), and a redaction filter (sensitive=1 exclusion + living-person heuristic + pre-publish review screen) built into the publish step from day one. PRIVACY.md and the App Store nutrition label must be rewritten in the same release.

Why publisher wins for these goals: single writer → no conflicts by construction; canonical research DB never at risk (cloud copy is disposable — republish fixes any sync bug); only ~6–7 of the 33 tables are viewer-relevant (`FamilyGraphSnapshot` is already the read model; `GEDCOMExporter` proves the projection); read-only CKShare is a *stronger* Evidence Firewall than today's code-shape convention; fresh-UUID record names via a `published_ids` mapping table sidestep the heterogeneous `profiles.id` problem entirely; FieldResearcherMCP and all Python tooling keep working unchanged.

What it deliberately gives up (accepted): family members can view but not contribute; you cannot author on iPad; viewers see the last publish, not live state. **The one question that flips this recommendation: if you actively want family corrections/photo contributions or sofa-authoring on iPad, the synced-store path (store split + key normalisation + CKSyncEngine over the tree store) becomes the right long-term answer — at roughly 3–6 months of plumbing before the first relative sees anything, vs weeks for the publisher.**

UI portability is better than expected: AppKit coupling is 4 view files + the app entry point; ViewModels are clean `@Observable`; the Canvas tree renderer is portable as-is; `TreeGraphView`'s existing arrow-key navigation + VoiceOver mirror is 80% of a tvOS focus-driven interaction model. A visitor experience needs ~25% of existing view code plus a new ~500–1,000-line tvOS shell.

## 4. AI tier: recommendation

Direct answer to the CoreML/Apple Intelligence question: **the thing you were looking for exists and is called the Foundation Models framework** (Apple Intelligence, iOS/macOS 26+, WWDC 2025; third-gen "AFM 3 Core" at WWDC 2026). You do not convert a model to CoreML yourself — Apple ships a ~3B on-device model with **guided generation (`@Generable`)**: constrained decoding that *guarantees* schema-valid Swift structs. That is a near-perfect fit for this app's AI usage, because the survey confirmed all live tasks are small-context (few KB; 24 KB cap on prose extraction), JSON-out, advisory-only, and already arithmetic-precomputed. Hand-rolled CoreML conversion of open 7B models remains niche/painful — not the path.

Platform reality: Foundation Models needs iPhone 15 Pro+ / M1+ iPad/Mac; **tvOS has no Apple Intelligence at all** (current Apple TV is A15). This is fine: the viewer targets need ZERO AI — bios are synthesised on the Mac at publish time (revive `NarrativeAssembler.templateNarrative`, currently dead code, deterministic) and shipped as text.

Plan:
1. Extract a `ReasoningBackend` protocol over `reason()/reasonJSON()` (the `ProseExtractionLLM` seam proves the pattern; ~1 day). MLX stays the default macOS implementation.
2. Housekeeping: flip default model DeepSeek-R1 → Qwen (standing decision; research says Qwen3-4B-class now matches R1-Distill-7B in far less memory); unify the three JSON parsers on the lenient extractor; delete the ~600 dead interpreter lines; pass real max-token params instead of the char-count heuristic; stream downloads to disk.
3. Add a FoundationModels backend on macOS 26+ using `@Generable` for the strategist + extraction tasks; A/B against MLX.
4. **Claude API stays out of the shipped app** (May 2026 removal was the right call for App Store posture — your own spec Decision 7 records this). Server-class reasoning re-enters, if ever, as (a) dev-side Claude driving the existing FieldResearcherMCP 17-tool surface into `pending_facts` behind the deterministic auto-approval gate — the plumbing already exists — or (b) Apple's Private Cloud Compute / the WWDC26 `LanguageModel` protocol (which supports Anthropic backends) as an explicit opt-in later. Per your own written doctrine (§7.7), any escalation decision is gated on the §5.8 eval harness — which is still unbuilt (ROADMAP Epic 1) and should be built before any model-strategy money is spent.

## 5. Recommended sequence

- **Phase 0 — hygiene (days):** DBY residue removal (invariant violation); Qwen default flip; JSON parser unification; `try?` → `do/catch` + visible failure in apply paths; delete dead WikiTree write-back + interpreter code; regenerate app CLAUDE.md.
- **Phase 1 — consolidation (1–2 wks):** extract `ApplyEngine` (all three write paths through it); `ResearchRunService` for the three pipeline construction sites; move `PendingFactsReviewView` raw SQL into ProjectDatabase; centralise the accept predicate.
- **Phase 2 — portability (1–2 wks):** carve `AncestorKit` SwiftPM package; split `TreeGraphView` into portable Canvas core + macOS input shell. (Watch the `.gitignore models/` trap and Xcode synchronized-group quirks.)
- **Phase 3 — publish:** write PUBLISHER/PLATFORM spec first (per project convention — this would otherwise be the first major unspecced work in the project's history, against docs that currently say the opposite); `published_ids` mapping + `PublishedTree` projection + redaction filter, shipped first as an offline "Export family bundle" (DESIGN.md §13's own idea, and the permanent fallback); then CloudKit container, versioned record types, PublishEngine diff/batch upload, zone-wide read-only CKShare; PRIVACY.md + nutrition label update in the same change.
- **Phase 4 — viewers:** iPad first (friendliest platform, validates the pipeline; TestFlight to family), then the tvOS focus-driven shell.
- **Phase 5 — AI (parallel track):** `ReasoningBackend` + FoundationModels backend; eval harness (Epic 1) before any escalation-tier decision.
- **Deferred until/unless family contribution or iPad authoring becomes a goal:** key normalisation, tree/research store split, two-way CKSyncEngine over the canonical store.
