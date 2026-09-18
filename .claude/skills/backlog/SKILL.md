---
name: backlog
description: Read, render, add to, or close items on this project's backlog (AncestorApp/BACKLOG.md). Use whenever asked what is outstanding, what to work on next, to add a to-do, or to check whether a change shipped. Status is derived from git, never stored.
allowed-tools: Bash, Read, Edit, Grep
---

# Backlog

This project has no issue tracker (see memory `no_github_issues.md`). The backlog is one
file plus git. **Status is never written down** — it is derived from commit messages, so
it cannot drift.

- **Items:** `AncestorApp/BACKLOG.md` — one line per item: ID, outcome, acceptance test.
- **Status:** `git log --all --format='%h %s' | grep -E '#<ID>([^0-9A-Za-z-]|$)'` — **subject only**
- **Design detail:** the owning `*_SPEC.md`, referenced from the item line.

## Why derived, not stored

Status for one change used to live in four places at once — the spec's change list,
`README.md`'s status column, and `MEMORY.md`. All four were hand-maintained
and they drifted: on 2026-09-18 both "living" routing docs were 6–8 weeks behind while
memory was 3 weeks behind. Commit messages are the only copy that cannot go stale, because
writing one *is* the act of doing the work.

## ID scheme

`#<TAG><n>` — TAG is a short uppercase workstream tag, unique across the whole repo
(`#GL3`, `#TT2`, `#M27-1`). Pick the next free number for an existing tag, or a new tag
for new work.

**Do not use bare `#Change<n>`.** It is not unique — `git log --grep='#Change1'` returns
33 commits spanning unrelated specs, so its status cannot be derived. Existing history
keeps it; new items must not.

## Reading the backlog

Render items with derived status rather than trusting the file:

```bash
grep -oE '^\| `#[A-Za-z0-9._-]+`' AncestorApp/BACKLOG.md | tr -d '|` ' | while read -r id; do
  n=$(git log --all --format='%s' | grep -cE -- "${id}([^0-9A-Za-z-]|\$)")
  printf '%-10s %s commits\n' "$id" "$n"
done
```

**Match the SUBJECT, not the whole message.** A commit that merely *mentions* an ID in its body
is not work on it — the `#X27-6` docs commit enumerates twenty other IDs, and whole-message
matching reported every one of them as shipped. Your commit convention already puts the ID in
the subject (`type: description #ID`), so filter on `%s`.

**The boundary is load-bearing.** A plain `--grep='#TT1'` also matches `#TT10`; `--grep='#X27'`
matches `#X27-1`; `--grep='#S1-4'` matches `#S1-4b`. And `\b` does NOT work — git's regex engine
ignores it and silently returns zero, which looks like "never shipped". Always use
`([^0-9A-Za-z-]|$)` with `-E`. Match the ID charset too: `[A-Za-z0-9._-]`, since real IDs carry
lowercase suffixes (`#S1-4b`) and legacy ones exist (`#T9-Change1`).

An item with commits is probably done: report it, confirm the acceptance test passed,
then delete the line. Pruning is a by-product of reading, not a separate status update.

## ID grammar, and why they are never rewritten

`#<TAG><n>` — TAG uppercase, unique repo-wide; an optional lowercase suffix marks a split
(`#S1-4` → `#S1-4b`, `#S1-4c`).

**An ID is immutable once it appears in a commit message**, because that message is the only
copy of its status. Renaming means rewriting history, which changes SHAs — and 417 distinct
SHAs are already cited across memory files and docs, none of which would error when broken.
So choose a tag deliberately the first time; do not tidy them later.

Tags in use: ASST, CFG, CPU, DC, DF, EH, EV, FM, FS, FUT, GL, KIN, M27, MED, MS, RC, S1, TOS,
TT, WT, X27. Note `M27` (adopting macOS 27 APIs) and `X27` (the Xcode 27 toolchain migration)
are easily confused — a cost of not choosing carefully, and now permanent.

Deprecated: bare `#Change<n>`, on 169 commits across unrelated specs. Never derivable; never
reuse it.

## Dependencies: store forward, derive reverse

Write a dependency **once**, on the item that is blocked, naming the blocker's ID:

```
| `#CPU2` | ChildhoodCensusRanker ranks village adjacency … **gate: `#RC8`** | … |
```

Do NOT also annotate `#RC8` with what it unblocks. That is a second copy of one fact and it
drifts, exactly as stored status did. The reverse direction is derived:

```bash
grep -rn '#RC8' AncestorApp/ .claude/skills/   # everything that depends on it
git log --oneline --grep='#RC8' --all          # and whether it shipped
```

**Retiring a spec: when, and how.** Retire it as soon as its items are routed — NOT when the
work is "finished". Finished never arrives: every spec ends with a tail, the tail keeps the file
alive, and the file then accumulates a second, unmaintained description of a system that keeps
moving. On 2026-09-18, 14 of 31 docs had drifted that way — one contradicting itself (header
"Stage 3 SHIPPED", body "DEFERRED"), one contradicting the shipped code (no mention of
`applyExclusivity`'s `appliedIDs` exemption, so it told the reader the opposite of what runs),
one the only record of a security invariant.

Walk it **claim by claim**, never file by file:
1. Verify each claim against CODE, not prose.
2. Route every outstanding statement — including ones phrased as closure ("deliberate scope
   limit", "known limitation", "non-goal for v1", "self-heals", "follow-on phase").
3. Migrate anything that exists nowhere else: invariants to `CLAUDE.md`, behaviour and rationale
   to the code's own doc comments, specimens to tests.
4. Then PROPOSE deletion. Git history is the archive.

**Consumer relationships are the step most easily missed.** A consumer relationship often
exists only as prose with no ID on either end — "a gazetteer refinement is a non-goal for v1"
was the whole record that the childhood-census ranker was waiting on village data. Prose has
no ID, so nothing can cross-reference it and deleting the document deletes the dependency.
Give the waiting work an ID and a `gate:` before retiring the document that mentions it.

## Check for a collision before minting an ID

Tags outlive the work that created them, and history is long. Before using a new ID:

```bash
git log --all --format='%s' | grep -oE '#[A-Za-z][A-Za-z0-9]*[0-9]+[a-z]?' | sort -u   # every ID ever claimed
```

This is not hypothetical: `#WT1` was minted for worktree salvage on 2026-09-18 when `#WT0`–`#WT4`
had belonged to the WikiTree MergeEdit series since March (`78b1037`). The status query then
reported the new row as already shipped. Renamed to `#WTS1`.

## Adding an item

Append a row. Required: a stable ID, the outcome in one sentence, and an acceptance test
concrete enough to act on without asking — name the file, view, button, or command, not a
category. No status, no dates, no commit refs; git holds those.

## Closing an item

Commit the work with the ID in the message (`fix: <what changed> #GL3`), then delete the
row. Never write "SHIPPED" into the file.
