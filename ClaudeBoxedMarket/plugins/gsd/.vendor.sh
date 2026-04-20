#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# .vendor.sh — pull a pinned GSD release into this plugin directory
#
# Usage:
#   ./.vendor.sh [tag]        # default: value of GSD_TAG below
#
# What it does:
#   1. Download the GSD release tarball for the given tag from GitHub
#   2. Copy commands/ agents/ hooks/ scripts/ get-shit-done/ into ./
#      (skip sdk/, tests/, docs/, assets/, README.*, CHANGELOG.md — not needed)
#   3. Rewrite @~/.claude/get-shit-done/ references to the absolute in-container
#      path so the plugin works without a runtime symlink into ~/.claude/
#   4. Stamp the pinned tag into .claude-plugin/plugin.json
#
# Re-run after bumping GSD_TAG to upgrade.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GSD_TAG="${1:-v1.38.1}"
REPO="gsd-build/get-shit-done"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_PATH="/opt/claude-market/plugins/gsd/get-shit-done"

echo "→  Fetching GSD ${GSD_TAG} from github.com/${REPO}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/${REPO}/archive/refs/tags/${GSD_TAG}.tar.gz" -o "$TMP/gsd.tar.gz"
tar -xzf "$TMP/gsd.tar.gz" -C "$TMP"
SRC="$TMP/get-shit-done-${GSD_TAG#v}"
[ -d "$SRC" ] || { echo "✗  extracted dir not found: $SRC" >&2; exit 1; }

echo "→  Copying commands/ agents/ hooks/ scripts/ get-shit-done/ into plugin"
# Preserve our locally authored hooks.json across re-vendoring — GSD ships
# hook *executables* but the Claude Code plugin wiring lives in hooks.json.
HOOKS_JSON_BACKUP=""
if [ -f "$PLUGIN_DIR/hooks/hooks.json" ]; then
    HOOKS_JSON_BACKUP=$(mktemp)
    cp "$PLUGIN_DIR/hooks/hooks.json" "$HOOKS_JSON_BACKUP"
fi

for d in commands agents hooks scripts get-shit-done; do
    rm -rf "${PLUGIN_DIR:?}/$d"
    cp -R "$SRC/$d" "$PLUGIN_DIR/$d"
done

if [ -n "$HOOKS_JSON_BACKUP" ]; then
    cp "$HOOKS_JSON_BACKUP" "$PLUGIN_DIR/hooks/hooks.json"
    rm -f "$HOOKS_JSON_BACKUP"
fi

# Also vendor the upstream LICENSE alongside the code we're redistributing
cp "$SRC/LICENSE" "$PLUGIN_DIR/LICENSE.gsd"

echo "→  Rewriting @~/.claude/get-shit-done/ → @${CONTAINER_PATH}/"
# -print0 / xargs -0 handles any filename; grep first to keep it fast
grep -rlZ '@~/.claude/get-shit-done/' "$PLUGIN_DIR/commands" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/get-shit-done" 2>/dev/null \
    | xargs -0 -r sed -i "s|@~/.claude/get-shit-done/|@${CONTAINER_PATH}/|g"

chmod +x "$PLUGIN_DIR/hooks/"*.sh "$PLUGIN_DIR/scripts/"*.sh 2>/dev/null || true

# Stamp the tag into plugin.json so we know what's installed
if command -v jq &>/dev/null && [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ]; then
    TMP_JSON=$(mktemp)
    jq --arg v "${GSD_TAG#v}" '.version = $v' "$PLUGIN_DIR/.claude-plugin/plugin.json" > "$TMP_JSON"
    mv "$TMP_JSON" "$PLUGIN_DIR/.claude-plugin/plugin.json"
fi

echo "✓  Vendored GSD ${GSD_TAG}"
