#!/bin/bash
# Build the Claude Desktop extension (.mcpb) for the Ancestor Research MCP
# server (roadmap 2f — assistant-surface packaging).
#
# A .mcpb is a zip: manifest.json at the root plus the server binary. Claude
# Desktop opens it, prompts for the manifest's user_config (the project
# .sqlite path), and runs the server with ANCESTOR_MCP_PROFILE=reader — the
# read-and-trigger consumer posture; nothing in the bundle can write to the
# tree (Evidence Firewall).
#
# Usage: Scripts/build_mcpb.sh [version]
# Output: dist/AncestorResearch.mcpb
#
# Remaining for the in-app "Connect to Claude" button (deliberately not done
# here): embed the release binary in the app bundle via an Xcode Copy Files
# phase (code-sign-on-copy), then have the button stage this same zip at
# runtime and NSWorkspace-open it. Needs an Xcode-side target edit — do it
# with the project open, not by hand-editing the pbxproj.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/AncestorResearch.mcpb"

echo "Building FieldResearcherMCP (release)…"
swift build -c release --package-path "$ROOT/FieldResearcherMCP"

BIN="$ROOT/FieldResearcherMCP/.build/release/FieldResearcherMCP"
[ -x "$BIN" ] || { echo "error: release binary not found at $BIN" >&2; exit 1; }

STAGE="$(mktemp -d)/AncestorResearch"
mkdir -p "$STAGE/server"
cp "$BIN" "$STAGE/server/FieldResearcherMCP"

# Stamp the requested version into the manifest.
sed "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" \
    "$ROOT/FieldResearcherMCP/mcpb-manifest.json" > "$STAGE/manifest.json"

# Sanity: manifest must parse and its entry_point must exist in the stage.
python3 - "$STAGE" << 'EOF'
import json, os, sys
stage = sys.argv[1]
with open(os.path.join(stage, "manifest.json")) as f:
    m = json.load(f)
entry = m["server"]["entry_point"]
assert os.path.exists(os.path.join(stage, entry)), f"entry_point missing: {entry}"
print(f"manifest ok — {m['name']} v{m['version']}, entry {entry}")
EOF

mkdir -p "$OUT_DIR"
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" .)

echo "Built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
echo "Install: open it with Claude Desktop (Settings → Extensions), pick your project .sqlite when prompted."
