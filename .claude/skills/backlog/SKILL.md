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
- **Status:** `git log --oneline --grep='#<ID>' --all`
- **Design detail:** the owning `*_SPEC.md`, referenced from the item line.

## Why derived, not stored

Status for one change used to live in four places at once — the spec's change list,
`ROADMAP.md`, `README.md`'s status column, and `MEMORY.md`. All four were hand-maintained
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
grep -oE '^\| `#[A-Z0-9-]+`' AncestorApp/BACKLOG.md | tr -d '|` ' | while read -r id; do
  n=$(git log --oneline --grep="#${id#\#}" --all | wc -l | tr -d ' ')
  printf '%-10s %s commits\n' "$id" "$n"
done
```

An item with commits is probably done: report it, confirm the acceptance test passed,
then delete the line. Pruning is a by-product of reading, not a separate status update.

## Adding an item

Append a row. Required: a stable ID, the outcome in one sentence, and an acceptance test
concrete enough to act on without asking — name the file, view, button, or command, not a
category. No status, no dates, no commit refs; git holds those.

## Closing an item

Commit the work with the ID in the message (`fix: <what changed> #GL3`), then delete the
row. Never write "SHIPPED" into the file.
