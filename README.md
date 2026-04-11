# claudeboxed

Run [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) in an isolated Docker container — works on Mac (Intel & Apple Silicon) and Linux.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image with Node 20, Python 3, Rust, and language tooling |
| `docker-compose.yml` | Compose services for interactive and unsafe modes |
| `claudeboxed` | Convenience shell script wrapping `docker run` |
| `entrypoint.sh` | Runtime uid/gid remapping so volume permissions work cross-platform |

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

### 2. Launch

```bash
# Interactive session in the current directory
./claudeboxed

# One-shot prompt
./claudeboxed "Write unit tests for src/parser.py"

# Skip permission prompts (container boundary is your protection)
./claudeboxed --unsafe

# Force rebuild the image before starting
./claudeboxed --build
```

The first run builds the Docker image automatically.

## Authentication

**claude.ai login (default):** The container mounts `~/.claude` and `~/.claude.json` from your host, so if you've already logged in on the host with `claude /login`, the session carries over — no API key needed.

**API key (alternative):** Set `ANTHROPIC_API_KEY` in your environment and pass it through by adding `-e ANTHROPIC_API_KEY` to the docker run flags, or uncomment the relevant line in `docker-compose.yml`.

## Using docker compose

```bash
# Build the image
docker compose build

# Interactive session
docker compose run --rm claude

# One-shot prompt
docker compose run --rm claude "Refactor the auth module"
```

> **Note:** When using `docker compose` directly (not the `claudeboxed` script), make sure `~/.claude` and `~/.claude.json` exist on your host first. The script creates these automatically, but Compose will create them as directories if missing, which breaks config parsing.

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
| `~/.ssh` | `/home/claude/.ssh` | SSH keys for git push/pull (read-only) |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket for building/running sibling containers |

## How it works

The container runs as root at startup only to remap the internal `claude` user's uid/gid to match the mounted workspace owner. This means:

- On Linux (uid 1000 or any other) and macOS (uid 501), volume permissions work without rebuilding the image
- After remapping, the entrypoint drops privileges via `gosu` and runs Claude Code as the `claude` user

## Included toolchains

The image ships with language servers and tooling for three ecosystems:

| Language | Tools | LSP |
|---|---|---|
| TypeScript | `tsc`, `ts-node`, `eslint`, `prettier` | `typescript-language-server` |
| Python | `mypy`, `ruff`, `black`, `pytest`, `uv` | `pyright` |
| Rust | `cargo`, `rustfmt`, `clippy` | `rust-analyzer` |

## Docker-in-Docker (sibling containers)

The host's Docker socket is mounted into the container, so Claude Code can build and run Docker containers. These are **sibling containers** — they run on the host Docker daemon, not nested inside the Claude Code container. This means:

- Containers Claude builds are visible to both you and Claude (`docker ps` works on both sides)
- Port mappings (`-p 3000:3000`) are exposed on the host, so you can access web apps from your browser
- From inside the Claude Code container, reach sibling containers via `host.docker.internal`

If you don't want Docker socket access, remove the `/var/run/docker.sock` volume mount from `docker-compose.yml` or `claudeboxed`.

## Security notes

- The container runs as a **non-root** user (`claude`, uid 1000 by default, remapped at runtime).
- `--unsafe` / `--dangerously-skip-permissions` bypasses Claude's interactive approval prompts. Only use it inside containers with trusted repositories — the container boundary is your protection.
- SSH keys are mounted **read-only**.
- Your host filesystem outside `$PWD` is not accessible to Claude.
- The Docker socket is mounted so Claude can build/run containers. This grants root-equivalent access to the host Docker daemon — only use in trusted environments.
- Do not commit `.env` or `.mcp.json` — they may contain API keys and tokens. Both are in `.gitignore`.
