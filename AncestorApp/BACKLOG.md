# Backlog

Open work, one row per item. **No status, no dates, no commit refs** — run
`git log --oneline --grep='#<ID>' --all` for status, or invoke the `backlog` skill, which
renders the whole file with derived status. A row with commits against it is done: verify
its acceptance test, then delete the row.

IDs are `#<TAG><n>`, unique repo-wide. Bare `#Change<n>` is deprecated — it collides across
specs, so its status cannot be derived.

## TT — test target under Swift language mode 6

All four targets now build at language mode 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
defined once at project level. The test target was previously at mode 5 (Xcode template
residue), so its concurrency was never checked. These are the surviving findings.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#TT1` | The `URLProtocol` stub in `Ancestor Research Tests/FamilySearchClientTests.swift` stops fighting actor isolation on its overrides (`canInit(with:)`, `canonicalRequest(for:)`, `startLoading()`, `stopLoading()`, `init(request:cachedResponse:client:)` — lines 276, 314, 315, 317, 333) | `xcodebuild build-for-testing -scheme "Ancestor Research Tests"` reports no `different actor isolation from nonisolated overridden declaration` errors |
| `#TT2` | Call-counting test doubles are safe under real concurrency: `FamilySearchClientTests` `record` (lines 71, 97, 122) and `FagBridgeCapTests` `fetchCount`/`fetchedIDs` (lines 183, 184). Decide per double — `actor` with awaited reads, or a mutex — because `RecordSource`/`HTTPClient` are now correctly `nonisolated` and the pipeline calls them from concurrent `async let` children | No `cannot be called from outside of the actor` / `can not be mutated from a nonisolated context` errors, and the count assertions still hold |
| `#TT3` | The test build reaches every file. `ProseCorpusAdderTests`, `PublishEngineE2ETests`, `QueryCacheTests` and `ScoreReplayDriftTests` never compiled in the 2026-09-18 runs (build aborted earlier), and still hold Sendable-closure findings plus `conformance of 'Row' to 'Sendable' is unavailable` — GRDB `Row` crossing a concurrency domain | `build-for-testing` succeeds, then a full `xcodebuild test` run is green apart from the known `BackupServiceTests` / `MultiWindowAppStateTests` flakes |

## GL — Liquid Glass

macOS 27 adds no new glass API (verified against the macOS 27.0 SDK: `Glass`, `glassEffect`,
`GlassEffectContainer`, `ConcentricRectangle` are all still macOS 26.0). The improvement is
system-side rendering, so the work is using the existing API properly. Measured 2026-09-18:
49 hand-rolled glass card rects across 25 files, 36 of them the `.padding(N)` +
`.glassEffect(.regular, in: .rect(cornerRadius: N))` idiom, 5 radii against 5 paddings with
no rule, and no shared card component.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#GL1` | A `GlassCard` component plus shape/spacing tokens (mirroring the `AppTypography` no-inline-literals rule), with the 36 idiom sites migrated to it | No bare `.glassEffect(.regular, in: .rect(...))` outside the component; the radius/padding set is reduced to a documented few and named in the tokens file |
| `#GL2` | Glass grouped into `GlassEffectContainer` at the seam rather than per site, including the open question of one container above the page-level `LazyVStack` (shares one backdrop pass across every card; risks breaking laziness from above, which is the documented cause of the Triage scroll hang) | `sample` during a Triage scroll on a large cluster shows no more `AttributeGraph`/`QuartzCore` heat than today's build, and visibly fewer backdrop passes |
| `#GL3` | Nested glass corners derive from their container via `.rect(corners: .concentric)` / `ConcentricRectangle` instead of hardcoded radii | A capsule inside a card visually shares the card's corner geometry at both card sizes |
| `#GL4` | The HR4 severity ladder carries its band in the material — `.glassEffect(.regular.tint(.red/.orange/.blue), ...)` — instead of colouring text on neutral glass | Red/amber/blue bands are distinguishable at a glance in both light and dark appearance |
| `#GL5` | Settle whether macOS 27 fixed the Liquid Glass hit-testing bug where a `.glassEffect` capsule in a Button label ate the click, and delete the dedicated-chevron workaround in `ClusterReviewView.recordRow` if so | A single Button wrapping a whole record row registers the click on macOS 27; the workaround comment and extra chevron Button are removed |

## M27 — macOS 27 API adoption

Deployment target stays `26.2`, so **adoption** rows are gated behind `if #available(macOS 27, *)`.

`#M27-5`–`#M27-7` are different in kind: they are *changed semantics of existing API*, which
apply at compile time against the SDK 27 toolchain **regardless of deployment target**, and
cannot be gated away. Apple's own authoritative guidance for these ships with Xcode — read the
matching `references/*.md` before touching one:
`~/Library/Developer/Xcode/CodingAssistant/ExportedPlugins/<xcode build>/claude/skills/swiftui-whats-new-27/`.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#M27-1` | Swipe actions on Workbench Attention rows for accept / discard / refuse without opening the row. SDK 27 allows these in **any scrollable container** — mark the container `swipeActionsContainer()` and keep `swipeActions(edge:allowsFullSwipe:)` per row — so the existing `ScrollView`/`LazyVStack` needs no rewrite into a `List`. See `references/swipe-actions.md` | Swiping an Attention row on macOS 27 performs the action; on macOS 26 the row behaves exactly as today |
| `#M27-2` | A decision, written into `RESEARCH_PIPELINE_SPEC.md`, on whether dragging a person between clusters should exist at all given "when in doubt, split" — and if yes, `reorderContainer(for:)` / `reorderDestination(for:in:)` implementing it | The spec records the ruling with its reasoning; any implementation cannot merge two clusters without the existing confirmation path |
| `#M27-4` | `#Preview(arguments:)` parameterised previews across the 106 view files, starting with the states that are painful to reach by hand | A reviewer can see empty / populated / conflict states of a view without driving the app |

| `#M27-5` | The `@State`-as-macro migration is understood and guarded. `@State` is no longer a property wrapper; views that compiled before can fail with "variable used before being initialized", "invalid redeclaration of synthesized property", or "extraneous argument label". 474 `@State` declarations here. **Apple states the intuitive fix — reordering init assignments — is WRONG and produces incorrect runtime behaviour**; `references/state-macro.md` has the correct one | The app and both viewer shells build against SDK 27 with no `@State` diagnostics, and the correct remedy is recorded in `CLAUDE.md` gotchas so nobody applies the wrong one |
| `#M27-6` | The 9 `confirmationDialog` files and 14 `.alert(` sites move to the new `item: Binding<T?>` overloads where they currently drive presentation from a Bool plus an optional. This is the `.sheet(item:)` shape that already fixed the EmptyView-rectangle bug (memory `feedback_sheet_isPresented_race`) | No `isPresented:` + `if let` pairing remains in an alert or confirmation dialog; each presents from a single optional binding |
| `#M27-7` | The `@ContentBuilder` unification is absorbed. It is source-incompatible for ambiguous `ShapeStyle` overloads in `overlay`/`background` and for type references shadowed by other modules — the same family as the "ShapeStyle ternary fails with mixed types" trap already in memory `feedback_xcode_project_quirks` | Build is clean with no `ShapeStyle`/builder ambiguity errors, and any type-check slowdown in a deeply-branching view is identified rather than tolerated |


## DF — dogfood hardening (graduated from ROADMAP 2026-09-18)

Core-correctness fixes from live-tree dogfooding; full repro cases in memory
`project_dogfood_2026_08_06`. "Core research before polish" ranks these ahead of Stage 2.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#DF1` | The second half of the married-surname fix: for a post-marriage-dated census, an unmarried "Dau" of a *same-surname* head is a strong negative — a born-Holmes daughter, not the subject who married into Holmes. Needs household-role analysis, so census-only. The temporal half shipped (`f4c9ab9`) | Sarah Gilbert's candidates (all born-WHEELDON girls) score negative rather than clearing; an 1891 "Mary E HOLMES" does not match a subject who became Holmes by her 1915 marriage |
| `#DF2` | Cross-record birthplace-consistency **gate** — applied-fact birthplace vs the candidate/loaded-household target birthplace demotes in ranking/verdicts and gates the census-absorb capsule. Display shipped (`c717fef`); the gate is deliberately still unbuilt because a naive town-compare cries wolf | George Ward (@I_1564729976@): applied Ashbourne birth vs the loaded Derby household of James J Ward is suppressed or warned, **and** a legitimate district/town pair like Milford-in-Belper still passes |
| `#DF3` | The geography gate knows registration districts | Ellen Brooks' own 1891 Duffield/Milford household row passes instead of soft-failing "unknown district: Duffield" while Derby/Chesterfield/Glossop namesakes pass; Joyce Land's 1945 **Florida** state census is rejected as a childhood census (worst hemisphere breach on record) |
| `#DF4` | The Health Apply-childhood-census path enforces `CensusFamilyLinker`'s guards | Joseph W Cauldwell's 1861 census, where he is "Grnson" (3m), does not lift his grandparents as parents; a "Son/Dau" row whose surname ≠ Head's (Joseph CAULDWELL in Joseph REPTON's household) does not propose the Head as biological father |
| `#DF5` | Backing out a namesake census offers cascade-delete of the profiles `addCensusFamily` created for it | Undoing the Coleorton/Leics namesake George Brooks household offers to delete the orphaned Ann Brooks island (Ann + Mary/Annie/Edith) rather than leaving a 4-person orphan group |
| `#DF6` | Parent-unlock findings show their evidence at the point of the click — ranked census fields + roster + in-tree badges + the subject's row highlighted, Apply/Dismiss beside it, as the reconciliation panels and absorb capsule already do | Re-running the 11-row pre-vet sweep, every trap that made it 0/11 one-click-correct (Grnson grandparents, Ilkeston namesake, Florida 1945, Ireland 1851) is visible without opening the profile or querying MCP |
| `#DF7` | The Add-Relationship "other person" picker disambiguates same-name profiles — rows carry a birth year and top relation | The two "Lydia Twyford" and the two "Mary Keyworth" are distinguishable in the dropdown, removing the risk of linking a man to his own daughter |
| `#DF8` | A safe child↔spouse role-change op that preserves the profile and its records, plus the missing parent-younger-than-child audit | Herbert Brewell's case is repairable without rename-phantom + delete-real (which destroyed his birth/death/leads research); Mabel b.1897 with son Herbert b.1898 raises a finding |
| `#DF9` | Parent-age-gap severity/midpoint display, so genuinely-approximate imports with wide "abt" windows soften rather than showing red ERROR. The census-derived false positives are already gone (`2657ff4` writes ±1 CAL dates) | A wide-"abt" import shows a midpoint/severity view; a real 10-year gap still errors |

## S1 — Stage 1 residual (graduated from ROADMAP 2026-09-18)

| ID | Outcome | Acceptance test |
|---|---|---|
| `#S1-1` | SOURCE_WEIGHTING live verification — the one hard owner-driven app session. Set project Home county, enter Elsie Twyford's known facts, re-run anchored + married-name burial hunt, one anchored run and one Kenneth-class ladder run | Dispatch-log query counts compared before/after and recorded in `SOURCE_WEIGHTING_SPEC.md`; staged weighting demonstrably changes dispatch order |
| `#S1-3` | §14.B.2–6 MCP auto-approval Phase 2 — the transaction/undo keystone, a cross-package build (app + standalone MCP raw-SQL). Auto-approval stays OFF until the undo lands | An MCP-committed fact can be undone transactionally from the app; `#RC1` (corroboration Change 5) is unblocked by the keystone covering relationship entities |
| `#S1-6a` | Location Stage 3 — decision-core geography-gate rebuild, substring → hierarchy + validity walk. The `PlaceResolver` primitive is ready | The gate resolves through a place hierarchy rather than substring matching; `#DF3`'s district cases pass through the rebuilt gate rather than a special case |
| `#S1-4a` | FT-19 FreeREG parish place-scoping — live connector work again now FreeREG is restored to free-trio parity | FreeREG queries scope to parish where the subject's parish is known, instead of widening silently |

## MS — measurements owed

| ID | Outcome | Acceptance test |
|---|---|---|
| `#MS1` | Settle whether app work runs on the main thread during a research run. Before 2026-09-18, `RecordSource.search` and `HTTPClient.get` were inferred `@MainActor` (the properties were all explicitly `nonisolated`, the async methods were not), so calls may have hopped to main. Also covers the open `runrequestwatcher` SQLite-writes-on-main item | `sample <pid>` during a run that triggers the marriage fan-out (`async let groomSide`/`brideSide`) shows the main thread idle or in AttributeGraph, not in URLSession completion, HTML parsing or GRDB frames |
| `#MS2` | The glass changes are verified in the running app, not just compiled | A Triage screen showing a cluster with a "Possible duplicate" or "Conflicts with tree" badge renders the badge group correctly, and the two collapsed bins ("Scorer rejected", "Discarded") show their count pill distinct from the card behind it |

## WT — stale workflow worktrees

| ID | Outcome | Acceptance test |
|---|---|---|
| `#WT1` | The four `.claude/worktrees/wf_53b1eec3-032-*` worktrees (1.4GB) are salvaged or removed, deliberately. All four are 0 commits ahead of main but carry **uncommitted** edits (2/2/6/2 files) — `MCPServer.swift` + a new `GetScoredRecordsTests.swift`, `FamilySearchSource.swift`, `QueryCache.swift`/`SearchDispatcher.swift`, `RecordTypes.swift`. They are based on `3251abc`, so diffing them against today's main measures main's divergence rather than unique work; the real comparison is each worktree's own `git diff` against `3251abc`, then asking whether that change already exists on main | Every dirty file is confirmed redundant or its change is committed to main, then `git worktree remove` for each and the 1.4GB is gone |

## CFG — build configuration

| ID | Outcome | Acceptance test |
|---|---|---|
| `#CFG1` | A decision on `SWIFT_DEFAULT_ACTOR_ISOLATION`, measured rather than inherited. It came from Xcode's app template, and the service layer overrides it heavily — 212 `nonisolated` occurrences across 228 files in `Services/`, with `ProjectDatabase`, `RecordScorer` and `ProjectStore` all opting straight back out | Either the setting is kept with the reasoning recorded, or it is removed and the now-redundant annotations are deleted; the app and tests build either way |
| `#CFG3` | Every type that is `@unchecked Sendable` **and** lock-guarded says `nonisolated`. Under MainActor-by-default such a type is silently main-actor isolated while its own declaration claims it is safe from any domain — the contradiction only surfaces when something finally calls it off the main actor. Six known: `FreeBMDQueryShapeTests`, `CWGCQueryShapeTests`, `PerSourceStrictnessTests`, `FreeREGDispatchSelectionTests`, `Ancestor Research/Services/Research/HTTPClient.swift` (`RecordingFormHTTPClient`), `Ancestor Research/Services/Publish/PublishEngine.swift` | `grep -rl '@unchecked Sendable'` cross-referenced with `NSLock`/`Mutex` returns no type lacking `nonisolated`; app and tests both build |
| `#CFG2` | `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY` enabled, in its own commit | The project builds with the flag on, with `any` added where the compiler requires it and no behaviour change |
