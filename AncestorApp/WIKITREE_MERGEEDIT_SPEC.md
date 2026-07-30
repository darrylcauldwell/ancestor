# WIKITREE_MERGEEDIT_SPEC — assisted write-back via Special:MergeEdit

**Status:** Accepted 2026-07-31 (owner: "work on writing the spec and getting started on implementation"). Build WT1–WT5; live verify BLOCKED on the Error-2562 unblock (memory `wikitree_account_blocked`).
**Posture authority:** memory `reference_wikitree_write_posture` (verified 2026-07-30). MergeEdit is WikiTree's sanctioned application write path; assisted tools need no pre-approval ("If you have an idea, run with it!" — Help:Developers). Unattended bots are forbidden — this design never automates a save.
**Wire contract:** Help:MergeEdit (page mod 2025-03-20; fetched via Wayback 2025-12-22 snapshot; verbatim extract at time of spec in scratchpad, key facts inlined below). ⚠ Standing rule: NO programmatic requests to wikitree.com from Darryl's network until the block is resolved — nothing in WT1–WT4 makes one.

## 1. The mechanism (why this is ToS-clean by construction)

`POST https://www.wikitree.com/wiki/Special:MergeEdit` renders a **review page in the member's logged-in browser**: every proposed field change appears with a checkbox, and the member confirms the save on WikiTree's own page. The app therefore:

1. Builds the payload (pure, offline — from the app's evidence-backed profile data).
2. Writes a temp **self-submitting HTML form** and opens it in the default browser (`NSWorkspace`). The browser carries Darryl's WikiTree session; the app never holds credentials, never scrapes, never commits.
3. Darryl reviews and saves on WikiTree — the human-commits model of BEE/Sourcerer/WikiTree X.

## 2. Wire contract (Help:MergeEdit, condensed)

- Identifier: `user_name` (WikiTree ID `Name-1234`) | `id` | `page_id`. We use `user_name` from E1 `externalIdentifiers["wikitree"]`.
- **JSON path (`person`)** — our v1 path. Accepted fields: `Prefix, FirstName, RealName, MiddleName, LastNameCurrent, LastNameOther, Nicknames, Suffix, BirthDate, BirthLocation, DeathDate, DeathLocation, Gender, Bio`. Note: **`LastNameAtBirth` is NOT editable via MergeEdit** (absent from the list).
- `expected` — same fields; when expected ≠ current profile value, that update is **skipped** with an error message and the original stays checked. WikiTree's own check-before-overwrite; we always populate it.
- `options.mergeBio: 1` — appends `Bio` to the end of `== Biography ==`. **INVARIANT: `Bio` is NEVER sent without `mergeBio: 1`** — without it the entire biography is overwritten.
- `summary` — change-log text (their default is "Imported data from external site."; ours is explicit, §4).
- GEDCOM X path (`data`) exists (persons/facts/sourceDescriptions; non-birth/death facts become bio bullet lines) — **deferred**: the JSON path covers v1 because WikiTree citations live in bio wikitext anyway (§4), and `expected` is only documented on the JSON path.
- Precedent apps: WikiTree X, WikiTree+ autocorrect. A demo app exists (compare against it at live-verify).

## 3. Field mapping + eligibility (WT1)

Eligible profile: has a `wikitree` external identifier, is deceased (same living test as the FS leg — living people never leave the app), and has at least one sendable change.

A field is **sendable** only when (a) the app's value differs from the twin's last-known WikiTree value, and (b) the app's value carries research-source provenance (`SourceOrigin.tier == .researchSource` or `.userAuthoritative` on that field) — estimates never overwrite WikiTree data (check-before-overwrite, both directions).

| App | MergeEdit | Notes |
|---|---|---|
| firstName | FirstName | |
| middleName | MiddleName | |
| marriedSurname | LastNameCurrent | WikiTree's married-surname convention (memory `wikitree_married_surname_convention`) |
| — | LastNameOther | from E2 nameForms variants beyond maiden/married, comma-joined |
| nickName | Nicknames | |
| birthDate.original | BirthDate | verbatim original string ("ABT 1887" etc.); review page shows it |
| birthLocation | BirthLocation | |
| deathDate.original | DeathDate | |
| deathLocation | DeathLocation | |
| gender | Gender | Male/Female only; other/unknown never sent |
| generated (§4) | Bio | ALWAYS with mergeBio: 1 |

`expected[field]` = the twin's last-known WikiTree value for every sent field (empty string when the twin has none — a populated live value then correctly skips). Maiden-surname corrections are NOT possible via MergeEdit (LastNameAtBirth absent) — surface those as "manual edit needed" notes in the UI, never silently dropped.

## 4. Bio append content (WT1)

A single appended block, idempotency-tagged so re-contributions are detectable by eye and by a later diff:

```
=== Research notes ({date}, Ancestor Research) ===
{per-fact lines: '* {Fact}: {value}<ref>{citation.formatted}</ref>'}
{uncited additional citations as '* {citation.formatted}'}
```

Only citations not already present in the twin's bio text are included (substring match on volume/page or URL — conservative: when in doubt, include; Darryl deletes on the review page). `summary` = "Sourced update from Ancestor Research: {field list}." — honest provenance in the change log.

## 5. Build slices

- **WT1 — payload builder (pure).** `Services/WikiTree/WikiTreeMergeEdit.swift`: `WikiTreeMergeEditPayload.build(profile:twin:citations:date:) -> Payload?` (nil = nothing sendable) where `Payload = {userName, personFields [String:String], expectedFields, bioAppend?, summary, manualNotes [String]}`. All §3/§4 policy here, fully tested.
- **WT2 — launcher.** Temp HTML self-submitting form (fields: `user_name`, `person`, `expected`, `options`, `summary` — JSON-encoded values; best-guess encoding flagged §7) → `NSWorkspace.shared.open`. HTML-escape everything; file in the app's temp dir; auto-submit via JS with a visible "Submitting to WikiTree…" fallback link.
- **WT3 — UI.** Profile-card action "Contribute to WikiTree…" (enabled iff eligible): sheet previews the exact diff (field: twin value → app value, each with its provenance), the bio append text, the summary line, and any manual-notes (e.g. maiden-surname corrections MergeEdit can't carry); button "Open review page in browser". Nothing sends until Darryl saves ON WikiTree.
- **WT4 — bookkeeping.** Migration `v54_wikitree_contributions`: `wikitree_contributions(id, profile_id, wikitree_id, fields_json, bio_appended, summary, opened_at)`. Records that a review page was OPENED — whether it was saved is unknowable app-side; truth arrives via the next twin sync (marked clearly in UI copy).
- **WT5 — docs + live-verify runbook.** ROADMAP entry; live verify (post-unblock): (1) small manual edit proves the unblock; (2) courtesy post in WikiTree Apps Google Group; (3) first MergeEdit against Darryl's OWN profile or a sandbox profile with one trivial field; confirm §7 unknowns; then real contributions.

## 6. Explicitly out of scope (sequenced later, not parked)

GEDCOM X `data` path (structured sourceDescriptions + fact bullets); relationship/parent edits (MergeEdit is field-level only); create-new-profile; batch contributions (one profile per review page keeps the human genuinely in the loop); MCP staging of contributions (wants the same request-table pattern as FS once the flow is proven); twin re-sync automation (WAF + block questions first).

## 6a. As-built record (2026-07-31, #WT0–#WT4)

WT1–WT4 SHIPPED in one pass, full suite 3,434/365 green:
- **WT1** `78b1037` — `WikiTreeMergeEdit.build` (Services/WikiTree/): differs-AND-research-provenance sendability, twin-raw `expected` (the `.wikitree`-origin FieldSource stamped at import is the in-app twin memory), maiden-surname manual notes, §4 research-notes block with bio-dedup, FNV-1a citation keys. 10 tests.
- **WT2** `20378db` — `WikiTreeMergeEditLauncher`: pure `reviewPageHTML` (form fields `user_name`/`person`/`expected`/`options`/`summary`, JSON-encoded values, HTML-escaped) + temp-file `NSWorkspace.open`. Bio↔mergeBio pairing structurally enforced + pinned by test. 4 tests.
- **WT3+WT4** `4e3410a` — `WikiTreeContributeSheet` (preview: field diffs, bio text, manual notes, summary; "Open WikiTree Review Page"; opened-state copy says offered-not-saved) wired into the profile card's More menu; migration `v54_wikitree_contributions` + `ProjectDatabase+WikiTreeContributions` (offers newest-first, profile-cascade). 2 tests.

**Remaining: WT5 (live verify) — BLOCKED on the Error-2562 unblock**, then: small manual edit → Apps Google Group courtesy post → first MergeEdit against Darryl's own profile → settle §7.

## 7. Unresolved — settle at live verify

1. Exact POST encoding: separate form fields with JSON-encoded values (our build) vs one raw-JSON body — Help page shows a single JSON document; the G2G "params on the URL + window.open" report implies param-style works. Compare with the demo app if the form bounces.
2. Whether `person` + `data` may combine in one request (sources alongside expected-guarded fields).
3. Date-format tolerance (uncertain dates like "ABT 1887") on the review page.
4. Whether off-apps-server-origin form POSTs hit third-party-cookie friction (2020–22 G2G reports) — if so, fallback is GET-with-params via `window.open`-style URL, or hosting a tiny page on apps.wikitree.com (Apps Project membership grants a directory).
