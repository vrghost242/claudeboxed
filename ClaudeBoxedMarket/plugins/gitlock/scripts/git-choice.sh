#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# git-choice.sh — PreToolUse hook for git operation standardization
#
# Enforces a consistent git workflow:
#   - git CLI for commits and pushes (uses gh credential helper)
#   - gh CLI for PRs and issues
#   - Blocks MCP GitHub write tools (they bypass local git history)
#   - Auto-refreshes expired credentials before network operations
#
# Hook input (stdin): JSON with tool_name and tool_input
# Hook output (stdout): JSON with permissionDecision or additionalContext
# Exit 0 = success (parse output), no output = allow
# ─────────────────────────────────────────────────────────────────────────────

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

case "$TOOL_NAME" in
    mcp__github__push_files|mcp__github__create_or_update_file)
        echo "🚫 gitcontrol: blocked $TOOL_NAME — use git CLI instead" >&2
        jq -n '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: "Do not use MCP GitHub to write files. Use the local git workflow: git add, git commit, git push. For PRs use: gh pr create."
            }
        }'
        ;;

    Bash)
        COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

        if echo "$COMMAND" | grep -qE '^\s*git\s|^\s*GIT_'; then
            # Check if this is a network operation that needs valid credentials
            if echo "$COMMAND" | grep -qE 'git\s+(push|pull|fetch|clone|remote\s+update|ls-remote)'; then
                if ! gh auth status &>/dev/null; then
                    echo "🔑 gitcontrol: credentials expired, attempting refresh..." >&2

                    if gh auth refresh &>/dev/null; then
                        echo "✓  gitcontrol: credentials refreshed" >&2
                    elif timeout 120 gh auth login --web --git-protocol https 2>&1; then
                        echo "✓  gitcontrol: re-authenticated via web login" >&2
                    else
                        echo "✗  gitcontrol: credential refresh failed (web login timed out or was cancelled)" >&2
                        jq -n '{
                            hookSpecificOutput: {
                                hookEventName: "PreToolUse",
                                permissionDecision: "deny",
                                permissionDecisionReason: "GitHub credentials are expired and automatic refresh failed. Ask the user to run: gh auth login --web --git-protocol https"
                            }
                        }'
                        exit 0
                    fi
                fi
            fi

            echo "🔀 gitcontrol: git command detected" >&2
            jq -n '{
                hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    additionalContext: "Git workflow rules: Use git CLI for add/commit/push (auth handled by gh credential helper). Use gh CLI for PRs (gh pr create) and issues. Never use MCP GitHub push_files or create_or_update_file."
                }
            }'
        fi
        ;;
esac
