---
name: preflight
description: Validate this project before shipping. Overrides the user-level preflight skill, which expects a Scripts/preflight.sh that does not exist here.
allowed-tools: Bash, Read, Grep
---

# Preflight (ancestor)

**There is no `Scripts/preflight.sh` in this project and no GitHub Actions CI.** The
user-level `preflight` skill assumes both; ignore it here. `Scripts/` contains only
`capture_screenshots.sh`.

The gate is `xcodebuild test`:

```bash
xcodebuild test -project "Ancestor Research.xcodeproj" \
  -scheme "Ancestor Research Tests" -destination "platform=macOS" -skipMacroValidation
```

**When Xcode is open**, add `-derivedDataPath /tmp/ancestor-test-dd` (DerivedData lock).
**In a fresh derivedDataPath**, also add the explicit-modules flags or swift-nio's C shim
fails before reaching our code — this reproduces on Xcode 26 *and* 27:

```
CLANG_ENABLE_MODULES=YES _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO
```

**After an Xcode update**, mlx-swift may fail with `cannot execute tool 'metal'` — run
`xcodebuild -downloadComponent MetalToolchain` (~839MB) first.

Known flakes under parallel execution — re-run in isolation before treating as real:
`BackupServiceTests`, `MultiWindowAppStateTests/staticServicesAreThreadSafe`.

Do not report a pass without the `** TEST SUCCEEDED **` line.
