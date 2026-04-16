#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# entrypoint.sh — runtime uid/gid fix for cross-platform volume permissions
#
# Problem: Docker volume mounts use numeric uid/gid for ownership checks.
#   - On Linux the host uid is typically 1000, but could be anything (e.g. 501
#     on some distros, or a corporate AD uid in the thousands).
#   - On macOS the default uid is 501. Docker Desktop uses VirtioFS which
#     handles permissions differently, but the container user still needs to
#     match for writes to work reliably.
#
# Solution: Run the container as root, detect the actual owner of the mounted
# workspace, remap the internal 'claude' user to that uid/gid at startup, fix
# ownership of the home directory, then drop to 'claude' and exec Claude Code.
#
# This means the image never needs to be rebuilt for a different user.
# ─────────────────────────────────────────────────────────────────────────────
set -e

# ── Detect the uid/gid of the mounted workspace ──────────────────────────────
# Using /workspace rather than ~/.claude because it's always mounted and its
# ownership reflects the actual host user.
WORKSPACE_UID=$(stat -c '%u' /workspace 2>/dev/null || echo "1000")
WORKSPACE_GID=$(stat -c '%g' /workspace 2>/dev/null || echo "1000")

CURRENT_UID=$(id -u claude)
CURRENT_GID=$(id -g claude)

# ── Remap claude user if uid/gid don't match the workspace owner ─────────────
if [ "$WORKSPACE_UID" != "$CURRENT_UID" ] || [ "$WORKSPACE_GID" != "$CURRENT_GID" ]; then
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
chown -R "$WORKSPACE_UID:$WORKSPACE_GID" /home/claude/.config 2>/dev/null || true

if gosu claude gh auth status &>/dev/null; then
    echo "✓  GitHub: authenticated"
else
    if [ -n "${GH_TOKEN:-}" ]; then
        if echo "$GH_TOKEN" | gosu claude gh auth login --with-token 2>/dev/null; then
            echo "✓  GitHub: authenticated via GH_TOKEN"
        else
            echo "✗  GitHub: GH_TOKEN is invalid or expired"
        fi
    fi

    if ! gosu claude gh auth status &>/dev/null; then
        echo ""
        echo "→  GitHub: no valid credentials. Starting web login..."
        echo "   (One-time setup — token persists across container restarts)"
        echo ""
        gosu claude gh auth login --web --git-protocol https || {
            echo ""
            echo "⚠  GitHub: auth skipped — git push/pull won't work for private repos"
        }
    fi
fi

# Use gh as git's credential helper. Set at system level because ~/.gitconfig
# is bind-mounted read-only from the host.
git config --system credential.helper '!gh auth git-credential'

# Export the token so child processes inherit it (e.g. MCP GitHub server).
GH_AUTH_TOKEN=$(gosu claude gh auth token 2>/dev/null || true)
if [ -n "$GH_AUTH_TOKEN" ]; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_AUTH_TOKEN"
fi

# ── Load ClaudeBoxed marketplace plugins ─────────────────────────────────────
# Scan /opt/claude-market/plugins/ and pass each as --plugin-dir so they are
# active for the session without modifying ~/.claude/plugins/ (which is shared
# with the host).
PLUGIN_ARGS=()
if [ -d /opt/claude-market/plugins ]; then
    for plugin_dir in /opt/claude-market/plugins/*/; do
        [ -d "$plugin_dir" ] && PLUGIN_ARGS+=(--plugin-dir "$plugin_dir")
    done
    if [ ${#PLUGIN_ARGS[@]} -gt 0 ]; then
        echo "✓  Marketplace: ${#PLUGIN_ARGS[@]} plugin(s) loaded from ClaudeBoxed"
    fi
fi

# ── Drop privileges and exec Claude Code ─────────────────────────────────────
exec gosu claude claude "${PLUGIN_ARGS[@]}" "$@"
