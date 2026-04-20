#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# entrypoint.sh — runtime uid/gid fix for cross-platform volume permissions
#
# Problem: Docker volume mounts use numeric uid/gid for ownership checks.
#   - On Linux the host uid is typically 1000, but could be anything (e.g. 501
#     on some distros, or a corporate AD uid in the thousands).
#   - On Docker Desktop for Mac, VirtioFS presents bind-mounted files as
#     root-owned inside the container regardless of real host ownership.
#
# Solution: Run the container as root. The launcher passes the real host uid
# via HOST_UID (stat of /workspace is unreliable on VirtioFS). If the
# resulting uid is non-zero, remap the 'claude' user to match it and drop to
# 'claude' before exec. If the uid is 0 (VirtioFS or a genuinely root-owned
# workspace), stay as root and rely on VirtioFS to translate file ownership
# on the host side.
#
# This means the image never needs to be rebuilt for a different user.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Detect the uid/gid of the mounted workspace ──────────────────────────────
# Prefer explicit values from the launcher (HOST_UID/HOST_GID). Fall back to
# stat'ing /workspace when invoked directly via `docker run`.
#
# Docker Desktop for Mac (VirtioFS) presents bind-mounted files as root-owned
# inside the container regardless of real host ownership. The stat fallback
# therefore returns 0 on that platform; the uid=0 branch below handles it by
# running as root throughout (VirtioFS translates writes back to the real
# host user on the host side).
WORKSPACE_UID="${HOST_UID:-$(stat -c '%u' /workspace 2>/dev/null || echo "1000")}"
WORKSPACE_GID="${HOST_GID:-$(stat -c '%g' /workspace 2>/dev/null || echo "1000")}"

CURRENT_UID=$(id -u claude)
CURRENT_GID=$(id -g claude)

# ── Decide: drop to 'claude' or stay as root ────────────────────────────────
# When the workspace is root-owned (either genuinely or via VirtioFS
# translation on Docker Desktop), dropping to an unprivileged user produces
# silent permission failures on bind-mounted directories. Stay as root in
# that case — all the mounts are then accessible, and VirtioFS rewrites file
# ownership to the real host user on the host side.
AS_CLAUDE=(gosu claude)
if [ "$WORKSPACE_UID" = "0" ]; then
    echo "ℹ  Workspace reports root ownership — running as root inside the container."
    echo "   (Typical on Docker Desktop/VirtioFS; host file ownership is preserved.)"
    AS_CLAUDE=()
    # Children (gh, claude, npm) must use /home/claude for config, not /root.
    export HOME=/home/claude
fi

# ── Remap claude user if we're going to drop to it ──────────────────────────
if [ ${#AS_CLAUDE[@]} -gt 0 ] && { [ "$WORKSPACE_UID" != "$CURRENT_UID" ] || [ "$WORKSPACE_GID" != "$CURRENT_GID" ]; }; then
    # Remap the group first
    if [ "$WORKSPACE_GID" != "$CURRENT_GID" ]; then
        # If another group already owns this gid, reuse it; otherwise modify claude's
        EXISTING_GROUP=$(getent group "$WORKSPACE_GID" | cut -d: -f1 || true)
        if [ -z "$EXISTING_GROUP" ]; then
            groupmod --gid "$WORKSPACE_GID" claude
        else
            usermod --gid "$WORKSPACE_GID" claude
        fi
    fi

    # Remap the user uid
    if [ "$WORKSPACE_UID" != "$CURRENT_UID" ]; then
        EXISTING_USER=$(getent passwd "$WORKSPACE_UID" | cut -d: -f1 || true)
        if [ -z "$EXISTING_USER" ]; then
            usermod --uid "$WORKSPACE_UID" claude
        else
            # Refuse to continue silently — proceeding would leave workspace files
            # owned by $WORKSPACE_UID while the process runs as $CURRENT_UID, so
            # Claude Code can neither read nor write its own workspace.
            echo "✗  Cannot remap 'claude' to uid $WORKSPACE_UID: already in use by '$EXISTING_USER'" >&2
            echo "   The host uid collides with a pre-existing user in the image." >&2
            echo "   Rebuild the image with a non-colliding base, or run the host process as a different uid." >&2
            exit 1
        fi
    fi

    # Fix ownership only on the volume-mounted directories, not the entire
    # home. /home/claude/.cargo and .rustup contain thousands of files —
    # chown -R /home/claude on macOS/VirtioFS takes ~60s. Instead we target
    # only the dirs that are actually mounted from the host.
    for dir in /home/claude/.claude /home/claude/.ssh /home/claude/.config/gh; do
        if [ -d "$dir" ]; then
            chown -R "$WORKSPACE_UID:$WORKSPACE_GID" "$dir" 2>/dev/null || true
        fi
    done
    # The home directory itself needs the right owner so gosu can write
    # transient files (e.g. .bash_history), but we don't recurse into it.
    chown "$WORKSPACE_UID:$WORKSPACE_GID" /home/claude 2>/dev/null || true
fi

# ── Fix macOS → container path translation for Claude Code plugins ────────────
# ~/.claude is shared from the macOS host, so installed_plugins.json and
# known_marketplaces.json contain hardcoded macOS home paths (/Users/<name>).
# Without this, Claude Code can't find the marketplace or plugin cache:
#   - All plugins fail to load (paths don't exist inside the container)
#   - Startup is slow because the marketplace gets re-cloned from GitHub on
#     every run instead of reusing the existing local clone
#
# Fix: create a symlink at the macOS home path pointing to /home/claude so
# every path reference in those JSON files resolves correctly. The JSON files
# themselves are never modified, so macOS operation is unaffected.
if [ -f /home/claude/.claude/plugins/known_marketplaces.json ] && command -v jq &>/dev/null; then
    HOST_HOME=$(jq -r 'to_entries[0].value.installLocation // empty' \
        /home/claude/.claude/plugins/known_marketplaces.json 2>/dev/null \
        | sed 's|/\.claude/.*||')
    if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "null" ] && [ ! -e "$HOST_HOME" ]; then
        mkdir -p "$(dirname "$HOST_HOME")"
        ln -sfn /home/claude "$HOST_HOME"
        # Remove stale .orphaned_at markers — they were written because these
        # paths previously couldn't resolve. The cache content is intact.
        find /home/claude/.claude/plugins/cache -name '.orphaned_at' -delete 2>/dev/null || true
    fi
fi

# ── Grant claude access to the Docker socket (sibling containers) ─────────────
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    # Reuse the existing group if one owns this gid, otherwise create 'docker'
    DOCKER_GROUP=$(getent group "$DOCKER_GID" | cut -d: -f1 || true)
    if [ -z "$DOCKER_GROUP" ]; then
        groupadd --gid "$DOCKER_GID" docker
        DOCKER_GROUP="docker"
    fi
    usermod -aG "$DOCKER_GROUP" claude
fi

# ── Configure GitHub authentication ──────────────────────────────────────────
# Uses gh CLI as the single auth source for both git and GitHub API.
# OAuth tokens persist in ~/.config/gh/ (mounted as a volume from the host).
#
# Priority:
#   1. Existing gh OAuth session (from a previous container run)
#   2. GH_TOKEN environment variable
#   3. Interactive web login (OAuth device flow)

mkdir -p /home/claude/.config/gh
# Only chown when we're actually dropping to the claude user. In root-mode
# (uid=0 branch) the bind mount's ownership is handled by VirtioFS.
if [ ${#AS_CLAUDE[@]} -gt 0 ]; then
    chown -R "$WORKSPACE_UID:$WORKSPACE_GID" /home/claude/.config 2>/dev/null || true
fi

if "${AS_CLAUDE[@]}" gh auth status &>/dev/null; then
    echo "✓  GitHub: authenticated"
else
    if [ -n "${GH_TOKEN:-}" ]; then
        if echo "$GH_TOKEN" | "${AS_CLAUDE[@]}" gh auth login --with-token 2>/dev/null; then
            echo "✓  GitHub: authenticated via GH_TOKEN"
        else
            echo "✗  GitHub: GH_TOKEN is invalid or expired — clearing from environment"
            unset GH_TOKEN
        fi
    fi

    if ! "${AS_CLAUDE[@]}" gh auth status &>/dev/null; then
        echo ""
        echo "→  GitHub: no valid credentials. Starting web login..."
        echo "   (One-time setup — token persists across container restarts)"
        echo ""
        "${AS_CLAUDE[@]}" gh auth login --web --git-protocol https || {
            echo ""
            echo "⚠  GitHub: auth skipped — git push/pull won't work for private repos"
        }
    fi
fi

# Use gh as git's credential helper. Set at system level because ~/.gitconfig
# is bind-mounted read-only from the host.
git config --system credential.helper '!gh auth git-credential'

# Export the token so child processes inherit it (e.g. MCP GitHub server).
GH_AUTH_TOKEN=$("${AS_CLAUDE[@]}" gh auth token 2>/dev/null || true)
if [ -n "$GH_AUTH_TOKEN" ]; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_AUTH_TOKEN"
fi

# ── Update Claude Code to latest version ─────────────────────────────────────
# Non-fatal: a registry outage or transient network issue must not block startup.
echo "⟳  Checking for Claude Code updates..."
npm update -g @anthropic-ai/claude-code --loglevel=warn \
    || echo "⚠  Update skipped — continuing with currently installed version"

# ── Load ClaudeBoxed marketplace plugins ─────────────────────────────────────
# Only plugins named in CLAUDEBOXED_PLUGINS (space-separated) are loaded —
# set by the launcher (default: gitlock; others opted in via --plugin).
# Each selected plugin is passed as --plugin-dir, so no state is written to
# ~/.claude/plugins (which is shared with the host).
PLUGIN_ARGS=()
if [ -d /opt/claude-market/plugins ] && [ -n "${CLAUDEBOXED_PLUGINS:-}" ]; then
    # Ensure plugin scripts are executable (bind mounts on macOS may lose the execute bit)
    find /opt/claude-market/plugins -name '*.sh' -exec chmod +x {} +

    for plugin_name in ${CLAUDEBOXED_PLUGINS}; do
        plugin_dir="/opt/claude-market/plugins/${plugin_name}"
        if [ -d "$plugin_dir" ]; then
            PLUGIN_ARGS+=(--plugin-dir "$plugin_dir")
        else
            echo "⚠  Plugin '${plugin_name}' not found at ${plugin_dir} — skipping"
        fi
    done
    if [ ${#PLUGIN_ARGS[@]} -gt 0 ]; then
        echo "✓  Marketplace: ${#PLUGIN_ARGS[@]} plugin(s) loaded (${CLAUDEBOXED_PLUGINS})"
    fi
fi

# ── Exec Claude Code (as 'claude' or as root, per AS_CLAUDE above) ───────────
exec "${AS_CLAUDE[@]}" claude "${PLUGIN_ARGS[@]}" "$@"
