# ─────────────────────────────────────────────────────────────────────────────
# Claude Code Docker Container
# Supports: linux/amd64 (Intel/AMD) and linux/arm64 (Apple Silicon / ARM Linux)
#
# Volume permission strategy:
#   Runs as root, detects the uid/gid of the mounted /workspace at startup,
#   remaps the internal 'claude' user to match, then drops privileges.
#   This works on Linux (uid 1000 or any other) and macOS (uid 501) without
#   needing to rebuild the image per user.
#
# Included toolchains:
#   TypeScript  — tsc, ts-node, eslint, prettier
#                 LSP: typescript-language-server
#   Python      — mypy, ruff, black, pytest, uv
#                 LSP: pyright
#   Rust        — rustup, cargo, rustfmt, clippy
#                 LSP: rust-analyzer (via rustup component)
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-slim

LABEL maintainer="you"
LABEL description="Claude Code isolated development environment"

# ── System dependencies ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    openssh-client \
    ca-certificates \
    ripgrep \
    jq \
    gosu \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI (for building/running sibling containers via host socket) ──────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── TypeScript tools + LSP ────────────────────────────────────────────────────
RUN npm install -g \
    typescript \
    ts-node \
    eslint \
    prettier \
    typescript-language-server \
    @anthropic-ai/claude-code

# ── Python tools + LSP ────────────────────────────────────────────────────────
RUN pip3 install --no-cache-dir --break-system-packages \
    uv \
    mypy \
    ruff \
    black \
    pytest \
    pytest-cov \
    pyright

# ── Create the claude user (uid 1000 as a sensible default) ──────────────────
# The entrypoint remaps this to match the actual host user at runtime.
# The node base image has a 'node' user at uid 1000 — remove it first.
RUN userdel node 2>/dev/null || true \
    && groupadd --gid 1000 claude \
    && useradd --uid 1000 --gid claude --shell /bin/bash --create-home claude

# ── Working directory ─────────────────────────────────────────────────────────
WORKDIR /workspace

# ── Claude config directory ───────────────────────────────────────────────────
RUN mkdir -p /home/claude/.claude && chown -R claude:claude /home/claude/.claude

# ── Rust toolchain — installed as claude (rustup is per-user) ─────────────────
USER claude

ENV RUSTUP_HOME=/home/claude/.rustup \
    CARGO_HOME=/home/claude/.cargo \
    PATH=/home/claude/.cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile default \
    && rustup component add \
        rustfmt \
        clippy \
        rust-analyzer \
    && rustup target add \
        wasm32-unknown-unknown

RUN git config --global --add safe.directory /workspace
RUN echo 'source "$HOME/.cargo/env"' >> /home/claude/.bashrc

# ── Switch back to root for the entrypoint ────────────────────────────────────
USER root

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
