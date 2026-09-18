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

Deployment target stays `26.2`; everything here is gated behind `if #available(macOS 27, *)`.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#M27-1` | `swipeActions` (now available on macOS, previously iOS-only) on Workbench Attention rows for accept / discard / refuse without opening the row | Swiping an Attention row on macOS 27 performs the action; on macOS 26 the row behaves exactly as today |
| `#M27-2` | A decision, written into `RESEARCH_PIPELINE_SPEC.md`, on whether dragging a person between clusters should exist at all given "when in doubt, split" — and if yes, `reorderContainer(for:)` / `reorderDestination(for:in:)` implementing it | The spec records the ruling with its reasoning; any implementation cannot merge two clusters without the existing confirmation path |
| `#M27-3` | Polish adoption where it earns its place: `TabsPickerStyle`, `Section(isExpanded:)` with a footer, `AnyNavigationTransition`, `TabContent.help` | Each adopted API replaces a hand-rolled equivalent, not added decoration |
| `#M27-4` | `#Preview(arguments:)` parameterised previews across the 106 view files, starting with the states that are painful to reach by hand | A reviewer can see empty / populated / conflict states of a view without driving the app |

## FM — FoundationModels

The macOS 27 SDK opens the framework to custom models via `LanguageModel` +
`LanguageModelExecutor`, so the local MLX tier could drive a real `LanguageModelSession`
and get `@Generable` guided decoding, tool calling and streaming while staying on-device.

| ID | Outcome | Acceptance test |
|---|---|---|
| `#FM1` | `LocalInferenceService` conforms to `LanguageModelExecutor` so MLX work runs through `LanguageModelSession`. `PrivateCloudComputeLanguageModel` is **forbidden** — it makes outbound calls and breaches the no-third-party-API invariant | Structured extraction returns a `@Generable` type instead of parsed free text, with no outbound network connection observed during a run |
| `#FM2` | `SystemLanguageModel` as a fallback reasoning tier, so a first run needs no multi-GB download | With no MLX model downloaded, next-search suggestion and candidate comparison still work |

## MS — measurements owed

| ID | Outcome | Acceptance test |
|---|---|---|
| `#MS1` | Settle whether app work runs on the main thread during a research run. Before 2026-09-18, `RecordSource.search` and `HTTPClient.get` were inferred `@MainActor` (the properties were all explicitly `nonisolated`, the async methods were not), so calls may have hopped to main. Also covers the open `runrequestwatcher` SQLite-writes-on-main item | `sample <pid>` during a run that triggers the marriage fan-out (`async let groomSide`/`brideSide`) shows the main thread idle or in AttributeGraph, not in URLSession completion, HTML parsing or GRDB frames |
| `#MS2` | The glass changes are verified in the running app, not just compiled | A Triage screen showing a cluster with a "Possible duplicate" or "Conflicts with tree" badge renders the badge group correctly, and the two collapsed bins ("Scorer rejected", "Discarded") show their count pill distinct from the card behind it |

## CFG — build configuration

| ID | Outcome | Acceptance test |
|---|---|---|
| `#CFG1` | A decision on `SWIFT_DEFAULT_ACTOR_ISOLATION`, measured rather than inherited. It came from Xcode's app template, and the service layer overrides it heavily — 212 `nonisolated` occurrences across 228 files in `Services/`, with `ProjectDatabase`, `RecordScorer` and `ProjectStore` all opting straight back out | Either the setting is kept with the reasoning recorded, or it is removed and the now-redundant annotations are deleted; the app and tests build either way |
| `#CFG2` | `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY` enabled, in its own commit | The project builds with the flag on, with `any` added where the compiler requires it and no behaviour change |
