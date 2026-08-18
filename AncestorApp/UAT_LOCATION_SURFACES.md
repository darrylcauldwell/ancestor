# UAT — how locations are surfaced

**Build:** the 2026-08-17/18 location work (`84fd193` … head). Rewritten after the
first UAT pass changed the app nine times — the steps below match what ships now.
**Time:** ~35 minutes for the full script, ~10 for Parts 1–2 alone.
**What you are judging:** not whether the answers are *right* — you know the
genealogy better than the app does — but whether the app **tells you what it
knows and what it is guessing**. Every failure this work fixed was the app
sounding certain when it wasn't.

All the people and places named below are real rows in your tree, found via MCP.

> **Note on counts.** Expected bucket counts come from a test sweep that used a
> uniform 1861 for every string. The live app uses each profile's real year, so
> your numbers will differ by a few. Treat counts as approximate; treat the
> *specific rows* as exact.

---

## Part 0 — Setup (2 min)

| # | Do | Expect |
|---|---|---|
| 0.1 | Open your project | — |
| 0.2 | Look at the left sidebar | A **Places** item with a map-pin icon, between Tasks and Health |
| 0.3 | Click it | A two-pane view: scored list left, detail right |

☐ **PASS** ☐ **FAIL** — notes:

*If Places is missing:* the tab only appears once some profile has a birth or
death location. That is certainly true of your tree, so a missing tab is a bug.

---

## Part 1 — The list itself (5 min)

| # | Do | Expect |
|---|---|---|
| 1.1 | Read the header | Chips counting **high / medium / low / unresolved**. Roughly 87 rows total, ~19 unresolved |
| 1.2 | Switch the filter to **All** | List sorted **worst first** — unresolved at top, high at the bottom |
| 1.3 | Check within one confidence band | Ties broken by how many fields use the string (most-used first) |
| 1.4 | Switch to **Needs a decision** | Only rows that are both below "high" and not already settled |
| 1.5 | Switch to **Settled** | Empty on first run — nothing has been decided yet |
| 1.6 | Type `turnditch` in the filter box | **Three separate rows**: `Turnditch`, `Turnditch, Derbyshire`, `Turnditch, Derbyshire (DBY)` |

☐ **PASS** ☐ **FAIL** — notes:

**Judgement call for you on 1.6.** Those are three spellings of one village
(Ernest b.1886, George b.1890, Samuel b.1889, William b.1882 between them). The
app treats each *string* as its own question, so you would settle it three times.
That is deliberate — merging them means assuming they mean the same place — but
it is exactly the sort of thing that is fine in a spec and irritating in use.
**Does it irritate you?** Your answer decides whether variant-grouping is worth
building.

---

## Part 2 — Middleton: the case this was all built for (8 min)

Ruth Brailsford was born **1824** at **"Middleton, Derbyshire (DBY)"**. Derbyshire
has several Middletons. The app used to answer *Bakewell* — a registration
district that did not exist until **1839**, fifteen years after she was born — and
nothing anywhere said so.

Filter for `middleton` and select **`Middleton, Derbyshire (DBY)`**. The pane
should read, near enough word for word:

> **Low**
> • 2 different places share this name: Middleton, Middleton & Smerrill.
> • Registration district: **Matlock**.
> • County stated in the text (DBY).
> • Ruled out for 1824: **Bakewell (began 1839)**.
> • 1824 predates civil registration (1837) — the district locates the place, it is not where the event was registered.

| # | Check | Expect |
|---|---|---|
| 2.1 | The score | **Low**, near the top of the list |
| 2.2 | The rivals are **named**, not just counted | *"Middleton, Middleton & Smerrill"* |
| 2.3 | A **Ruled out** section exists | **Bakewell — began 1839**, struck through |
| 2.4 | The pre-registration caveat | Present, mentioning 1824 and 1837 |
| 2.5 | **Used by** | Ruth Brailsford, Birth, 1824 |
| 2.6 | Now select **`Middleton By Wirksworth, Derbyshire, England`** (Ethel Spencer) | **High** — *"Registration district: Ashbourne"*, no rivals, nothing ruled out |

☐ **PASS** ☐ **FAIL** — notes:

**This is the headline test.** 2.1 and 2.3 are the ones that matter: a Low score
*and* a visible elimination. If Middleton reads "High", or if Bakewell has simply
vanished rather than being shown struck through, the fix has not landed — an
answer reached by knocking rivals out is only checkable when you can see what was
knocked out.

**Now the sharp bit, and the reason 2.6 is in the script.** Ruth's row offers
**Matlock** — reached via *Middleton & Smerrill*, the Middleton near Youlgreave.
Ethel's fuller string resolves to **Ashbourne** — the Middleton near Wirksworth.
Those are two different villages twelve miles apart, and your own research notes
put Ruth at Middleton-by-Wirksworth, i.e. **Ashbourne, which her row does not
offer as its answer**.

So: does the pane give you enough to notice that, and enough to act on it? You
would need the **Show all matches nationally** hatch, or to know Ethel's row
exists. **That is the honest test of whether "we report, you decide" actually
works in practice** — or whether reporting the rivals without ranking them by
plausibility just moves the work onto you.

---

## Part 3 — The other failure shapes (10 min)

One row each, chosen because each broke differently.

### 3.1 The label used to lie — `City Hospital, Derby` (Molly Cauldwell, 1997)

| Expect |
|---|
| Scored **Low**, *not* "Unresolved" |
| *"Registration district: Derby."* — one candidate |
| *"Matched on "Derby", not "City Hospital""* — the precise place is not in the catalogue |
| **Ruled out for 1997: Belper (ended 1994), Shardlow (ended 1974)** |

Previously this read **Unresolved** while still listing candidates — enough
deductions drove the score to zero and the word then contradicted the pane. It is
also a good era-filter check in the other direction: this is a **1997** birth, so
the districts eliminated are ones that *closed*, not ones that had not opened.

☐ **PASS** ☐ **FAIL**

### 3.2 A hamlet found only via its parish — `Calling Low, Youlgreave, Derbyshire` (Mary Thompson, 1882)

| Expect |
|---|
| **Medium** |
| Explicitly: *matched on "Youlgreave", not "Calling Low"* |

The point is that you are told the precise place is still unknown, rather than
being shown Youlgreave's district as though Calling Low had been found.
Same shape: **`Bridge Town (Darley Bridge), Wensley, Derbyshire`** (William
Holmes, 1882) → matched on Wensley.

☐ **PASS** ☐ **FAIL**

### 3.3 Two settlements share a name — `Loscoe, Derbyshire, England` (Ernest 1919, George 1915, Kenneth 1917)

| Expect |
|---|
| **Low** — *"2 different places share this name: Codnor & Loscoe, Heanor & Loscoe"* |

☐ **PASS** ☐ **FAIL**

### 3.4 One settlement, several districts — `Wirksworth, Derbyshire, England` (you, and Ian)

| Expect |
|---|
| **Medium**, not Low — 2 possible districts (Bakewell, Belper) but only **one** place |

3.3 and 3.4 are the pair worth comparing. Two *places* sharing a name is real
ambiguity; one place filed under two districts is not. The app scores them
differently on purpose — check that the panes make the difference legible.

☐ **PASS** ☐ **FAIL**

### 3.5 Genuinely unresolved hamlets

`Longcliffe Wharf, Derbyshire` (Harriet Holmes 1857) · `Stanton-in-Peak,
Derbyshire` (Samuel Holmes 1847) · `Bolehill, Derbyshire, England` (Jennifer
Holmes) · `Pilhough, Derbyshire` · `Priestcliffe, Derbyshire`

| Expect |
|---|
| **Unresolved**, with *"No registration district matches any part of this text"* |
| **No candidate districts offered** — silence, not a guess |

☐ **PASS** ☐ **FAIL**

### 3.6 Not places at all

`Ashborne` (Annie Cauldwell ×2 — a typo for Ashbourne) · `Derbyshire` (Robert
Cauldwell — a county is not a district) · `Warwickshire, England` (Ellen Ward) ·
`Darley Hall` (a house) · `- (or Dublin), County Dublin (or Ireland)`

| Expect |
|---|
| All **Unresolved** |
| `Ashborne` and `Darley Hall` also note **no county stated, so nothing narrows the search** |

☐ **PASS** ☐ **FAIL**

**Worth noticing:** `Ashborne` is one letter from a real district the app knows.
It does not offer "did you mean Ashbourne?". Should it?

### 3.7 Pre-registration — `Warslow, Staffordshire` (Sarah Wain, b.1786)

| Expect |
|---|
| **High** — *"Registration district: Leek"*, county stated (STS) |
| **Ruled out for 1786: Staffordshire Moorlands (began 1974)** |
| A reason noting **1786 predates civil registration (1837)** |

The interesting bit: Warslow appears under two districts (Leek, and
Staffordshire Moorlands after the 1974 reorganisation) yet still scores High,
because that is one place across a boundary change, not two rival places.

☐ **PASS** ☐ **FAIL**

---

## Part 4 — Making a decision (10 min)

Use **`Bolehill`** — a real hamlet the gazetteer has never listed, six people, one
1891 household. It exercises everything at once.

| # | Do | Expect |
|---|---|---|
| 4.1 | Select it | **Where is it?** first, with a search box; then Why this score; then the reason field; then the uses |
| 4.2 | Look at **Apply to which uses?** | **Six rows, one per person** — not seventeen. Each lists its fields (`Census 1891 · Occupation 1891 · Residence 1891`). All **pre-ticked**, `16 of 16 selected`, Select all / none **above** the list |
| 4.3 | Check **Same place, other spellings** | *"Also settle 1 other spelling"*, ticked, naming `Bolehill, Derbyshire, England` |
| 4.4 | Type `Wirk` in the search | Parish rows first, each with `Wirksworth · <district> · Derbyshire`. **No year ranges.** A note explaining that a parish can be filed under several districts. `Wirksworth · Belper district` shows **"1 record in this family already"** |
| 4.5 | Reason: *"Bolehill is a hamlet in Wirksworth parish"*, then **It's here** on Belper | Both Bolehill rows settle; unresolved drops by 2 |
| 4.6 | Filter **Settled**, reselect | Orange **"Placed by hand — the gazetteer did not match this text"**, your reason, and the years it covers |
| 4.7 | **Reopen this** | Back in the queue |

☐ **PASS** ☐ **FAIL** — notes:

### 4.8 Ambiguity still makes you tick deliberately

| # | Do | Expect |
|---|---|---|
| 4.8 | Select **`Middleton, Derbyshire (DBY)`** | **Nothing pre-ticked** — two real villages share that word, so the app will not choose for you. Bolehill pre-ticks because nothing about it is ambiguous |

☐ **PASS** ☐ **FAIL**

### 4.9 The refusal, and the way through it

| # | Do | Expect |
|---|---|---|
| 4.9 | Select **`Cromford, Derbyshire`** | If its uses straddle 1839 or 1994: **"These uses span a boundary"** naming the year and district |
| 4.10 | Try to bind a district that cannot hold them all | Refused by name and year, **plus a button**: *"Settle just the N that fit \<district>"* |
| 4.11 | Use it, then settle the remainder against a district that can hold it | One string, two answers — which is the point of per-field decisions |

☐ **PASS** ☐ **FAIL**

## Part 5 — Escape hatches (5 min)

| # | Do | Expect |
|---|---|---|
| 5.1 | On any row, click **Show all matches nationally** | A longer list, **county shown against each**, ignoring both the stated county and every date. On Middleton you should see Lancashire's among them |
| 5.2 | On `Darley Hall`, click **This isn't a place** | Set aside; leaves the queue; a **no-entry** marker appears in the list |
| 5.3 | Re-select it | A **Set aside** block with **Put it back in the queue** |
| 5.4 | Check the profile that used it | **The tree text is unchanged** — setting aside records a judgement, it does not edit your data |
| 5.5 | On an **Unresolved** row, look for **Ask the local model** | Present. If no MLX model is loaded: *"No local model loaded"* and nothing else happens |
| 5.6 | *(Only if a model is loaded)* Ask it on `Pilhough, Derbyshire` | A suggestion naming a **real Derbyshire parish**, the model's own words, an orange *"check it before accepting"*, and an **Accept this** button |

☐ **PASS** ☐ **FAIL** — notes:

**On 5.6:** the model is never asked an open question — it is handed the list of
real parishes in the stated county and told to pick one or decline. If it ever
names something that is not a Derbyshire parish, that is a serious bug; tell me.

---

## Part 6 — The picker (5 min)

This is where a bug that has been shipping for weeks got fixed.

**Do this in the Add Person sheet, not on a real profile** — you will be typing
throwaway values, and Add Person has a Cancel button. Tree → add a person.
**Press Cancel at the end; save nothing.**

| # | Do | Expect |
|---|---|---|
| 6.1 | In Add Person, put `1861` in **Birth date** *first* | The picker reads the year from the date field beside it, so this has to come first |
| 6.2 | Click into **Birth location** and type `Crich` | Dropdown row shows **Crich · Belper · Derbyshire** |
| 6.3 | Check what it does **not** say | **Not "Amber Valley"** — that district began in **1994**, 133 years after this birth |
| 6.4 | Now clear the birth date, and retype `Crich` | **Amber Valley reappears** as a rival. That is the fix working — with no year, nothing can be ruled out |
| 6.5 | Put `1861` back, and type `Cromford` | District text in **orange**, reading **"Bakewell or 1 other"** (Belper is the other; Matlock ended 1838) |
| 6.6 | Hover the orange text | A tooltip listing the rival districts and pointing you at the Places tab |
| 6.7 | Type something absent, e.g. `Pilhough` | *"No gazetteer match — will be saved as freeform text."* You are **not blocked** |
| 6.8 | Now type `Derby` and **click away without picking from the dropdown** | An orange **?** and *"Saved as text — you didn't pick from the list."* Previously this said **nothing at all** |
| 6.9 | **Cancel the sheet** | Nothing saved |

☐ **PASS** ☐ **FAIL** — notes:

**6.8 is the one I most want your read on.** It is the commonest way a location
ends up uncoded — you typed a real place, the app knew it, and moved on without
selecting it. It now says so. Judge the wording and the weight: is an orange
caption right, or too loud for something that is explicitly allowed? Note it
appears **only for fields you edited this session**, never against text that
arrived from an import — otherwise most of your tree would wear it.

### 6.10 The era fix now covers every embed

There are **ten** picker embeds; five were date-blind until this build.

| # | Do | Expect |
|---|---|---|
| 6.10 | Open **Add Family**, put `1861` in a birth date, type `Crich` in the birth location beside it | **Crich · Belper** — *not* Amber Valley. Same answer as Add Person gives |
| 6.10b | In the same sheet, find the census transcription section | **Street address** *and* **Parish or town** are separate fields; only the parish has a picker. A street is not a gazetteer entry |
| 6.11 | Same sheet, marriage section: `1861` marriage date, type `Cromford` | Era-filtered, and orange if rivals remain |
| 6.12 | Cancel the sheet | Nothing saved |

☐ **PASS** ☐ **FAIL** — notes:

6.3 is the regression check. Before this build the picker asked without a year
and took whichever district sorted first — about two rows in five showed a rival,
and some showed districts that did not exist yet.

6.6 is deliberate: unresolved places must keep working. Judge whether the message
makes that feel like a considered choice or like a failure.

---

## Part 7 — Typos, junk, and the remaining gaps (5 min)

### 7.1 Correcting the text — the third answer

`Ashborne` is a misspelling of a district the app knows. `-` is a stray
character. Neither *settling* nor *setting aside* is true of either, so there is
now a third action — the **only** one in this tab that edits your tree.

| # | Do | Expect |
|---|---|---|
| 7.1 | Select **`Ashborne`** (3 people) → **Correct the text…** | A field pre-filled with `Ashborne`, and a line stating exactly how many fields will change |
| 7.2 | Change it to `Ashbourne` → **Rewrite the tree** | The `Ashborne` row **disappears** and merges into `Ashbourne`, which resolves on its own — it was always a real place |
| 7.3 | Select **`-`** (3 people) → **Correct the text…**, leave it **empty** | Warns it will **CLEAR** 3 fields. Do it; the row vanishes entirely |
| 7.4 | Check the profile history for one of those people | The change is there as a normal edit — undoable, not a silent overwrite |

☐ **PASS** ☐ **FAIL** — notes:

**Judgement call:** `Cottage`, `Hill Side` and `Park Nook` could be house names,
hamlets, or transcription fragments. Three actions now fit them — settle,
set aside, or correct. Does having all three make the choice clear or crowded?

### 7.5 Still genuinely missing

| # | Do | Expect (the gap) |
|---|---|---|
| 7.5 | Edit a marriage place inline on the tree card (`m. [date] [place] ✓`) | **Plain text box, no picker** — marriage places typed there still get no structured code |
| 7.6 | Open a burial life event → **Cemetery** | Plain text, no gazetteer |
| 7.7 | Health tab | Only **Suspect Location**, which checks *formatting* — never whether a place exists. `Notaplace Magna` passes it |

☐ **CONFIRMED** — notes:

## What to tell me afterwards

1. **Did Part 2 land?** Low score, rivals named, Bakewell shown struck through.
2. **Is the reasoning readable, or is it a wall of text?** Every row carries 3–5
   reason lines. On a 19-row unresolved queue that is a lot of prose.
3. **Turnditch × 3** (1.6) — does string-by-string decision-making annoy you
   enough to justify grouping variants?
4. **Anything that looks confident and is wrong.** That is the whole point; it is
   the one failure mode the design treats as unacceptable.
5. **Anything that looks broken rather than merely unhelpful** — empty panes,
   controls that do nothing, a row that will not settle.
