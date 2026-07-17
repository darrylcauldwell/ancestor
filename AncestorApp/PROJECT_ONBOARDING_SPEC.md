# PROJECT_ONBOARDING_SPEC

**Status:** accepted-direction 2026-07-17 (owner). Not started.
**Motivation:** several settings that materially change research quality are
currently *discoverable-by-accident* — most importantly the home region anchor
(silently derived, and quietly under-performs when empty/wrong) and the two
local-AI models (each behind a separate, unexplained download). A first-run
setup phase surfaces these as deliberate choices; a re-openable Getting Started
layer teaches the views. Part A is primary; Part B is secondary.

Guiding rule (unchanged app doctrine): **nothing here may block a user who just
wants to dive in.** Every step is skippable and every choice has a sane default,
so onboarding *encourages* good configuration without gating on it.

---

## Part A — Setup wizard (PRIMARY)

A short, skippable wizard shown once per project, at the moment a project is
created or connected.

### A.1 Trigger points
- New empty project.
- GEDCOM import.
- WikiTree connect.
(One shared wizard; the entry context only pre-fills defaults — e.g. GEDCOM
import can guess the home region from the most common birth county in the file.)

### A.2 Steps

Minimal-first build = **Steps 1 + 2 only**; Steps 3–4 grow later.

1. **Home region / base locale.** "Where is this family mostly from?" Sets the
   project's home Chapman anchor (`project_meta.home_chapman_code`, surfaced via
   `Project.resolvedHomeChapmanCode`) and, where relevant, the `RegionConfig` /
   `config.yaml` context (county, parishes, districts). This is the single
   highest-value prompt: it is the fallback locality used when a record has no
   place, and it drives the geography gates and source scoping. Default: derived
   from tree data (existing behaviour) — the wizard just makes it explicit and
   correctable. **No hardcoded regions:** the picker is populated from the
   Chapman/registration-district registry, not a Derbyshire special case.

2. **Enable local AI (the unified download).** ONE consent screen that explains
   both models, their sizes, and what each unlocks — replacing today's two
   separate mystery downloads:
   - **Reasoning model** (`LocalInferenceService`, Qwen family, ~GB) — next-search
     suggestions, candidate comparison, evidence extraction.
   - **Semantic clustering model** (`MLXTextEmbedder`, minilm, ~90 MB) — tighter
     "Possible People" clustering via semantic similarity.
   User can enable neither / either / both; sizes shown; downloads happen here
   with progress, not silently on first feature use. Default: **off** (the app is
   fully functional deterministically with no model — core doctrine). Folds in
   the "auto-use the semantic model once downloaded" behaviour from Part B.4.

3. **Home person.** Choose the tree's root / "you-are-here" anchor
   (`project_meta.home_person_id`) — drives nearest-gap prioritisation and the
   home-person context action. Default: largest-degree node, or skip.

4. **Sources.** Which free sources to enable and an acknowledgement of
   volunteer-source etiquette (rate-limit caps). Default: the current registry
   defaults. Advanced settings (auto-approval posture, etc.) are deliberately
   NOT here — they stay in Settings.

### A.3 Persistence & behaviour
- Writes only to existing project settings (`project_meta`), `config.yaml`
  context, and model-enablement flags — no new tree data, no firewall change.
- A "Set up later" escape on every step; a project may be fully used un-configured.
- Re-runnable from Settings ("Re-run project setup").

### A.4 Acceptance criteria
- A newly created/imported project shows the wizard once; skipping it leaves the
  project fully usable with today's defaults.
- Setting a home region in Step 1 is reflected in `resolvedHomeChapmanCode` and
  changes geography-gated search scope (a test fixture proves the anchor reaches
  the dispatcher).
- Enabling a model in Step 2 downloads it with visible progress and it is used
  thereafter; enabling nothing leaves every feature working deterministically.

---

## Part B — Getting Started (SECONDARY)

Teaches the UI. Distinct from Part A: Part A *configures*, Part B *explains*, and
Part B is **re-openable** at any time (nobody absorbs a tour on day one).

### B.1 Design principle — low maintenance
A heavy scripted walkthrough anchored to exact controls goes stale every time the
UI moves (and this UI moves often). Instead:
- A concise **per-view help affordance** (an "i"/"?" on each major view — Tree,
  Research, Triage, Workbench, Sourcing, Settings) answering "what is this view
  for / how do I use it" in a few lines.
- A short **overview** ("how the pieces fit": research → triage → tree) reachable
  from Help and offered at the end of the setup wizard ("Take a quick tour?").
No coordinate-glued coach marks.

### B.2 Entry points
- Offered once at the end of Part A.
- Always available from a Help menu / Settings.

### B.3 Acceptance criteria
- Every major view has a help affordance whose copy matches the view's actual
  current purpose.
- The overview and per-view help are reachable without re-triggering setup.

### B.4 Folded-in tweak
The "auto-use the semantic model once downloaded" behaviour (raised 2026-07-17)
lands here / in Part A Step 2: never auto-*download*, but auto-*use* the semantic
embedder whenever a model is already present — so the user opts in once, not per
session.

---

## Delivery

Staged, minimal-first:
- **Stage 1 — Part A core:** Steps 1 (home region) + 2 (unified enable-local-AI,
  incl. auto-use-once-downloaded). The biggest capability win.
- **Stage 2 — Part A rest:** Steps 3 (home person) + 4 (sources); re-run-from-Settings.
- **Stage 3 — Part B:** per-view help affordances + overview + "Take a tour" hand-off.

## Open questions
- Wizard as a modal sheet vs. a dedicated first-run screen?
- Should GEDCOM import auto-suggest the home region from the file's dominant birth
  county (nice, but must stay correctable and non-hardcoded)?
- Where does Help live on macOS (menu bar Help vs. in-app) — and mirror for the
  iOS viewers later?
