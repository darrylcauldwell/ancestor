---
name: ship
description: Ship this project. Overrides the user-level ship skill, which runs a preflight script and monitors CI — neither exists here.
allowed-tools: Bash, Read, Grep
---

# Ship (ancestor)

**No CI and no preflight script.** The user-level `ship` skill commits, runs
`Scripts/preflight.sh`, pushes and monitors a CI run; this project has none of those. Do not
wait for or check a CI result after pushing — there isn't one.

1. **Validate** — invoke the project `preflight` skill (`xcodebuild test`). It is the entire gate.
2. **Commit** — atomic, conventional, each referencing a backlog ID (`fix: ... #GL3`). See the
   `backlog` skill; delete the row once its acceptance test passes.
3. **Push** — only when explicitly asked. Do not retry a failed push; wait for instruction.
4. **Distribute** — fastlane lanes directly, never `/ship`:
   `bundle exec fastlane mac beta` / `mac promote` / `mac metadata`.

Never push to TestFlight without running the app and verifying the change on the screen it
affects. Clean DerivedData before archiving.
