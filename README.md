# claudeboxed

Run [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) in an isolated Docker container — works on Mac (Intel & Apple Silicon) and Linux.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image with Node 22, Python 3, Rust, Playwright, gh CLI, and language tooling |
| `docker-compose.yml` | Compose services for interactive and unsafe modes |
| `claudeboxed` | Convenience shell script wrapping `docker run` |
| `entrypoint.sh` | Runtime uid/gid remapping so volume permissions work cross-platform |
| `setup` | Interactive check-and-guide script for first-time configuration |
| `.mcp.json.example` | MCP server configuration template |

## Quick start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac/Windows) or Docker Engine (Linux)
- A Claude Code account — log in via `claude /login` on your host first

### 1. Clone and make the launcher executable

```bash
git clone git@github.com:vrghost242/claudeboxed.git
cd claudeboxed
chmod +x claudeboxed
```

### 2. Run the setup check

```bash
./setup
```

The script checks your environment (Docker, Claude auth, Git, GitHub, AWS, MCP) and guides you through anything missing. It does not handle credentials directly — it tells you which tool to run.

### 3. Launch

```bash
# Interactive session in the current directory
./claudeboxed

# One-shot prompt
./claudeboxed "Write unit tests for src/parser.py"

# Skip permission prompts (container boundary is your protection)
./claudeboxed --unsafe

# Force rebuild the image before starting
./claudeboxed --build

# Run in a git worktree (isolated branch for parallel agents)
./claudeboxed --worktree content

# Load an opt-in marketplace plugin (repeatable)
./claudeboxed --plugin gsd
```

The first run builds the Docker image automatically.

### Marketplace plugins

ClaudeBoxed ships a small plugin marketplace at `ClaudeBoxedMarket/`, bind-mounted into the container at `/opt/claude-market`. `gitlock` is loaded by default; others (e.g. `gsd` — [Get Shit Done](https://github.com/gsd-build/get-shit-done)) are opt-in via `--plugin <name>`, repeatable.

Plugins live fully inside the container — nothing is written to `~/.claude/plugins/`, so host state is unaffected. To update the vendored copy of GSD, bump the tag in `ClaudeBoxedMarket/plugins/gsd/.vendor.sh` and re-run it.

### Running multiple agents in parallel

Use `--worktree` to give each agent its own isolated branch and working directory. Each worktree runs in a separate container with no git conflicts.

```bash
# Open separate terminals and launch one agent per service
./claudeboxed --worktree content --unsafe
./claudeboxed --worktree document --unsafe
./claudeboxed --worktree progress --unsafe
```

Worktrees are created as sibling directories (`../<repo>-<name>`) on branch `worktree-<name>`. When each agent finishes, merge the branch via PR. To clean up:

```bash
git worktree remove ../<repo>-content
git branch -d worktree-content
```

## Authentication

**claude.ai login (default):** The container mounts `~/.claude` and `~/.claude.json` from your host, so if you've already logged in on the host with `claude /login`, the session carries over — no API key needed.

**API key (alternative):** Set `ANTHROPIC_API_KEY` in your environment and pass it through by adding `-e ANTHROPIC_API_KEY` to the docker run flags, or uncomment the relevant line in `docker-compose.yml`.

## Git and GitHub

Git is included in the image. Authentication works via two mechanisms:

**SSH (default):** `~/.ssh` is mounted read-only, so `git clone/push/pull` over SSH works if your host has SSH keys configured.

**GitHub CLI + token:** The `gh` CLI is installed in the image. Set `GH_TOKEN` in your environment before launching:

```bash
export GH_TOKEN=ghp_your_token_here
./claudeboxed
```

`gh` reads `GH_TOKEN` automatically — no `gh auth login` needed. This also enables HTTPS-based git operations. The `claudeboxed` script passes `GH_TOKEN` through to the container only when set.

`~/.gitconfig` is mounted read-only if present, so your git identity (name, email) carries over.

You can also use the GitHub MCP server for structured access to issues, PRs, and repos — see [MCP configuration](#mcp-configuration) below.

## Browser testing with Playwright

The image includes [Playwright](https://playwright.dev/) with a headless Chromium browser. Claude can write and run browser automation scripts for frontend testing.

Playwright is available in two modes:

- **CLI / library:** Write Playwright test scripts and run them with `npx playwright test`. The `playwright` package is installed globally.
- **MCP server:** The `@playwright/mcp` package is installed globally. Add it to your MCP configuration to give Claude structured browser interaction (navigate, click, screenshot, etc.) — see [MCP configuration](#mcp-configuration).

Browsers are pre-installed at `/opt/playwright-browsers` so there is no download delay at runtime.

## AWS access

Mount your AWS credentials into the container for CLI and SDK access. The `claudeboxed` script mounts `~/.aws` read-only if the directory exists.

```bash
export AWS_REGION=eu-west-2
export AWS_PROFILE=claude-sandbox
./claudeboxed
```

For richer access, configure the AWS MCP server — see [MCP configuration](#mcp-configuration).

**Security:** Create a dedicated IAM profile (e.g. `claude-sandbox`) scoped to only the permissions Claude needs. Never mount credentials with admin access.

## MCP configuration

Claude Code supports [MCP servers](https://modelcontextprotocol.io/) for structured access to external services. Configuration can live at two levels:

| Level | Location | Use for |
|---|---|---|
| **Project** | `.mcp.json` in the project root | Project-specific tools that don't carry secrets |
| **User** | `~/.claude/` (via `claude mcp add --scope user`) | Credential-bearing servers (GitHub, AWS) — persists across all projects |

**User-level is recommended for servers that require tokens or credentials**, since `~/.claude` is already mounted and the config is never committed to a repository.

To get started, copy the example and edit it:

```bash
cp .mcp.json.example .mcp.json
```

Or configure at the user level (recommended for credentials):

```bash
claude mcp add --scope user github -- npx -y @modelcontextprotocol/server-github
claude mcp add --scope user playwright -- npx @playwright/mcp --headless --browser chromium
claude mcp add --scope user aws -- uvx awslabs.aws-api-mcp-server@latest
```

See `.mcp.json.example` for the full configuration template with all available servers.

## Using docker compose

```bash
# Build the image
docker compose build

# Interactive session
docker compose run --rm claude

# One-shot prompt
docker compose run --rm claude "Refactor the auth module"
```

> **Note:** When using `docker compose` directly (not the `claudeboxed` script), make sure `~/.claude` and `~/.claude.json` exist on your host first. The script creates these automatically, but Compose will create them as directories if missing, which breaks config parsing. Optional mounts (`~/.gitconfig`, `~/.ssh`, `~/.aws`) must also exist on the host — the `claudeboxed` script skips these if missing, but Compose will fail. Comment out any mounts you don't need.

## Targeting a different project directory

```bash
# With the script — just cd into the project
cd /path/to/myproject && /path/to/claudeboxed

# With Compose — set WORKSPACE_PATH
WORKSPACE_PATH=/path/to/myproject docker compose run --rm claude
```

## Volume mounts

| Host path | Container path | Notes |
|---|---|---|
| `$PWD` | `/workspace` | Your project — Claude reads and writes here |
| `~/.claude` | `/home/claude/.claude` | Persists settings, memory, and session history |
| `~/.claude.json` | `/home/claude/.claude.json` | Claude config file |
| `~/.gitconfig` | `/home/claude/.gitconfig` | Git identity (read-only, mounted if present) |
| `~/.ssh` | `/home/claude/.ssh` | SSH keys for git push/pull (read-only, mounted if present) |
| `~/.aws` | `/home/claude/.aws` | AWS credentials (read-only, mounted if present) |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket for building/running sibling containers |

## How it works

The container runs as root at startup only to remap the internal `claude` user's uid/gid to match the mounted workspace owner. This means:

- On Linux (uid 1000 or any other) and macOS (uid 501), volume permissions work without rebuilding the image
- After remapping, the entrypoint drops privileges via `gosu` and runs Claude Code as the `claude` user

## Included toolchains

The image ships with language servers, tooling, and integration CLIs:

| Category | Tools | LSP |
|---|---|---|
| TypeScript | `tsc`, `ts-node`, `eslint`, `prettier` | `typescript-language-server` |
| Python | `mypy`, `ruff`, `black`, `pytest`, `uv` | `pyright` |
| Rust | `cargo`, `rustfmt`, `clippy` | `rust-analyzer` |
| Browser | `playwright`, `@playwright/mcp` (Chromium) | — |
| Git/GitHub | `git`, `gh` | — |

## Docker-in-Docker (sibling containers)

The host's Docker socket is mounted into the container, so Claude Code can build and run Docker containers. These are **sibling containers** — they run on the host Docker daemon, not nested inside the Claude Code container. This means:

- Containers Claude builds are visible to both you and Claude (`docker ps` works on both sides)
- Port mappings (`-p 3000:3000`) are exposed on the host, so you can access web apps from your browser
- From inside the Claude Code container, reach sibling containers via `host.docker.internal`

If you don't want Docker socket access, remove the `/var/run/docker.sock` volume mount from `docker-compose.yml` or `claudeboxed`.

## Security notes

- The container runs as a **non-root** user (`claude`, uid 1000 by default, remapped at runtime).
- `--unsafe` / `--dangerously-skip-permissions` bypasses Claude's interactive approval prompts. Only use it inside containers with trusted repositories — the container boundary is your protection.
- SSH keys, git config, and AWS credentials are mounted **read-only**.
- `GH_TOKEN` is only passed into the container when set in the host environment.
- Your host filesystem outside `$PWD` is not accessible to Claude.
- The Docker socket is mounted so Claude can build/run containers. This grants root-equivalent access to the host Docker daemon — only use in trusted environments.
- Scope AWS credentials to a dedicated profile with minimum required permissions.
- Configure credential-bearing MCP servers at the user level (`~/.claude/`), not in project-level `.mcp.json` files.
- Do not commit `.env` or `.mcp.json` — they may contain API keys and tokens. Both are in `.gitignore`.
