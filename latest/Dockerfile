# MESA VS Code — built from cyverse-vice/vscode `latest`
# https://github.com/linuxserver/docker-code-server
FROM lscr.io/linuxserver/code-server:latest

LABEL org.label-schema.name="CyVerse VICE MESA VS Code" \
      org.label-schema.description="VS Code (code-server) with CUDA, Miniconda, agentic AI CLIs, and MESA MCP servers for CyVerse VICE" \
      org.label-schema.url="https://cyverse.org" \
      org.label-schema.vcs-url="https://github.com/idss-mesa/vscode" \
      org.label-schema.vendor="CyVerse" \
      org.label-schema.schema-version="1.0.0"

USER root

# Target architecture set by buildx (this image is amd64-only: CUDA + drivers)
ARG TARGETARCH=amd64

# Prevent interactive prompts and service starts during build
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

ENV TZ=America/Phoenix
ENV LC_ALL="en_US.UTF-8"
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone

# ---------------------------------------------------------------------------
# Pinned, checksum-verified downloads (2026-10 security review). Bump the
# version AND its hash together: a mismatch fails the build.
# ---------------------------------------------------------------------------
ARG CUDA_VERSION="12-5"
# Miniconda: a dated installer + sha256 from https://repo.anaconda.com/miniconda/
ARG MINICONDA_VERSION="py313_26.9.4-0"
ARG MINICONDA_SHA256=bc244e697ac4201db36f201274596989af7ac4f07610184b2a3dc62ed883010c
ARG GCM_VERSION="2.7.3"
ARG GCM_SHA256_X64=a5431e1b6f25aa8b424e747d880f86e74c739ad52e72c924a7b1a25d87ac7e72
ARG GO_VERSION="1.27.3"
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG NODE_VERSION=22.23.4
ARG GOCMD_VERSION=v0.12.5
ARG GOCMD_SHA256_AMD64=af551f8cb2f3f5df63fb3a8eb1bf605c7f27e50ec10283a5375190239db9f57a
ARG AWSCLI_VERSION=2.38.5
ARG AWSCLI_SHA256_X86_64=5def7d1b7e55d892f9a381bb2cb2081a685712464be0d36d5d706af0ac48d0d3
ARG DUCKDB_SHA256_AMD64=c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc
# Ollama: pinned tarball from the GitHub release (sha256sum.txt), never install.sh
# (install.sh bakes an `ollama` system user, a systemd unit and, when it sees no
# GPU, the cuda-drivers userspace). gpu/Dockerfile reuses it when identical.
ARG OLLAMA_VERSION=0.40.11
ARG OLLAMA_SHA256=7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d
ARG CLAUDE_CODE_VERSION=2.1.310
ARG CODEX_VERSION=0.164.0
ARG CCR_VERSION=3.1.3
ARG MCP_FS_VERSION=2.0.1
ARG OPENCODE_VERSION=1.19.4

# System dependencies: upstream cyverse-vice/vscode set plus the MESA stack
# (python3-venv for the /opt/mesa venv, gettext for envsubst, tini as PID 1,
# s3fs/fuse for OSN mounts, terminal niceties for the landing screen)
# `apt-get upgrade` first: the linuxserver base is not rebuilt against Ubuntu
# security updates between its releases (openssl, linux-libc-dev, ... were behind)
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        lsb-release apt-transport-https ca-certificates curl wget gnupg \
        libfreetype6-dev pkg-config libx11-dev gcc gettext less \
        software-properties-common apt-utils glances htop nvtop nano \
        sudo pciutils unzip zstd xz-utils git tmux tini socat bubblewrap \
        python3 python3-venv python3-pip \
        locales figlet lolcat s3fs fuse && \
    locale-gen en_US.UTF-8 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Node.js 22 from the official tarball, verified against nodejs.org's SHASUMS256.txt
# (replaces the unpinned `curl deb.nodesource.com/setup_22.x | bash`)
RUN curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " node-v${NODE_VERSION}-linux-x64.tar.xz$" | sed 's|  .*|  /tmp/node.tar.xz|' | sha256sum -c - && \
    tar -xJ -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' -f /tmp/node.tar.xz && \
    rm -f /tmp/node.tar.xz && node --version && npm --version

# User setup: the linuxserver base has no uid 1000, so create vscode:1000.
# HOME stays /config (code-server's settings/extensions dir in this base).
RUN (getent group 1000 > /dev/null || groupadd -g 1000 vscode) && \
    (id -u vscode > /dev/null 2>&1 || useradd -m -d /home/vscode -u 1000 -g 1000 -s /bin/bash vscode) && \
    usermod -aG sudo vscode && \
    echo "vscode ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/vscode/data-store /config/.irods && \
    chown -R vscode:1000 /home/vscode /config

# CUDA toolkit only. The NVIDIA driver userspace is NOT installed any more: the
# container runtime injects the host's driver, and the baked R580 userspace that
# `nvidia-driver-535` (a transitional package on noble) pulled in broke NVML on
# R535 hosts and added ~1.1 GB plus setuid nvidia-modprobe. gpu/Dockerfile keeps
# its purge step as a guard in case a future base ships one.
RUN wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends cuda-toolkit-${CUDA_VERSION} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Miniconda and Mamba (pinned installer + sha256)
RUN curl -sSLo /tmp/Miniconda3.sh https://repo.anaconda.com/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh && \
    echo "${MINICONDA_SHA256}  /tmp/Miniconda3.sh" | sha256sum -c - && \
    bash /tmp/Miniconda3.sh -b -p /opt/conda && \
    rm /tmp/Miniconda3.sh && \
    /opt/conda/bin/conda config --set channel_priority strict && \
    /opt/conda/bin/conda install -y mamba -n base -c conda-forge --override-channels && \
    /opt/conda/bin/conda clean -afy && \
    chown -R vscode:1000 /opt/conda

# Security floors in the conda base env (Trivy, 2026-10): PyJWT < 2.14, anyio < 4.14.2,
# brotlicffi < 1.2.1, certifi < 2026.10.19, filelock < 4.2.1, urllib3 < 2.8 carry fixed
# HIGH/CRITICAL CVEs; the miniconda installer ships older builds.
RUN /opt/conda/bin/pip install --no-cache-dir --upgrade \
        "PyJWT>=2.14" "anyio>=4.14.2" "brotlicffi>=1.2.1.0" "certifi>=2026.10.19" "filelock>=4.2.1" "urllib3>=2.8" && \
    /opt/conda/bin/pip check && \
    /opt/conda/bin/conda clean -afy && chown -R vscode:1000 /opt/conda

# Ollama (pinned, sha256-checked tarball; see the ARG above)
RUN curl -fsSL -o /tmp/ollama.tar.zst "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst" && \
    echo "${OLLAMA_SHA256}  /tmp/ollama.tar.zst" | sha256sum -c - && \
    zstd -dc /tmp/ollama.tar.zst | tar -xf - -C /usr/local && rm -f /tmp/ollama.tar.zst && \
    /usr/local/bin/ollama --version 2>&1 | grep -F "${OLLAMA_VERSION}"

# Globus Connect Server
RUN curl -LOs https://downloads.globus.org/globus-connect-server/stable/installers/repo/deb/globus-repo_latest_all.deb && \
    dpkg -i globus-repo_latest_all.deb && \
    apt-get update && \
    apt-get install -y globus-connect-server54 && \
    rm globus-repo_latest_all.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Git Credential Manager (pinned + sha256)
RUN wget -q https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-x64-${GCM_VERSION}.deb -O /tmp/gcm.deb && \
    echo "${GCM_SHA256_X64}  /tmp/gcm.deb" | sha256sum -c - && \
    dpkg -i /tmp/gcm.deb && rm -f /tmp/gcm.deb
ENV GCM_CREDENTIAL_STORE=cache

# Go, then the iRODS MCP server (stdio MCP access to the CyVerse Data Store)
# https://github.com/idss-mesa/irods-mcp-server
RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" && \
    echo "${GO_SHA256_AMD64}  /tmp/go.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local -f /tmp/go.tgz && rm -f /tmp/go.tgz && \
    git clone --depth 1 https://github.com/idss-mesa/irods-mcp-server /tmp/irods-mcp-server && \
    cd /tmp/irods-mcp-server && \
    CGO_ENABLED=0 GOPATH=/tmp/go GOCACHE=/tmp/go-cache /usr/local/go/bin/go build -o /usr/local/bin/irods-mcp-server ./cmd/main.go && \
    cd / && rm -rf /tmp/irods-mcp-server /tmp/go /tmp/go-cache

# GoCommands (pinned + sha256; not self-upgraded from ~/.bashrc any more)
# https://learning.cyverse.org/ds/gocommands/
RUN curl -fsSL -o /tmp/gocmd.tgz "https://github.com/cyverse/gocommands/releases/download/${GOCMD_VERSION}/gocmd-${GOCMD_VERSION}-linux-${TARGETARCH}.tar.gz" && \
    echo "${GOCMD_SHA256_AMD64}  /tmp/gocmd.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local/bin -f /tmp/gocmd.tgz && rm -f /tmp/gocmd.tgz && gocmd --version

# AWS CLI (pinned + sha256)
RUN curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" && \
    echo "${AWSCLI_SHA256_X86_64}  /tmp/awscliv2.zip" | sha256sum -c - && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# mesa-mcp and mesa-ducklake (https://github.com/idss-mesa) in a dedicated venv,
# isolated from /opt/conda so user installs there cannot break them.
# cyverse-login hardcodes /opt/mesa/bin/python3 for iRODS password obfuscation.
# Pinned to release tags: DuckDB 2.0 (mesa-ducklake >= 0.2) writes catalogs
# DuckDB 1.x cannot open, and a changed ref also invalidates this layer's cache.
# The [ducklake] extra enforces mesa-mcp's mesa-ducklake>=0.2 floor; the
# assertion fails the build if the venv Python or DuckDB is too old.
ARG MESA_DUCKLAKE_REF=v0.2.0
ARG MESA_MCP_REF=v0.2.0
RUN /usr/bin/python3 -m venv /opt/mesa && \
    /opt/mesa/bin/pip install --no-cache-dir \
      "mesa-ducklake @ git+https://github.com/idss-mesa/mesa-ducklake@${MESA_DUCKLAKE_REF}" \
      "mesa-mcp[ducklake] @ git+https://github.com/idss-mesa/mesa-mcp@${MESA_MCP_REF}" && \
    /opt/mesa/bin/python -c "import sys, duckdb; from importlib.metadata import version as v; assert sys.version_info >= (3, 11), sys.version; assert duckdb.__version__.startswith('2.'), duckdb.__version__; print('mesa-mcp', v('mesa-mcp'), 'mesa-ducklake', v('mesa-ducklake'), 'duckdb', duckdb.__version__)" && \
    ln -s /opt/mesa/bin/mesa-ducklake /usr/local/bin/

# DuckDB 2.0 for users: the `duckdb` CLI on PATH and duckdb in the base conda Python.
# Same major as /opt/mesa, so catalogs mesa-ducklake writes (DuckDB 2-only)
# open here too.
ARG DUCKDB_VERSION=2.0.0
RUN DUCKDB_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo amd64) && \
    curl -fsSL -o /tmp/duckdb.tgz "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-cli-linux-${DUCKDB_ARCH}.tar.gz" && \
    echo "${DUCKDB_SHA256_AMD64}  /tmp/duckdb.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local/bin -f /tmp/duckdb.tgz duckdb && rm -f /tmp/duckdb.tgz && \
    duckdb --version | grep "^v${DUCKDB_VERSION} " && \
    /opt/conda/bin/pip install --no-cache-dir "duckdb==${DUCKDB_VERSION}" && \
    chown -R "$(stat -c %u:%g /opt/conda)" /opt/conda/lib/python3*/site-packages/duckdb* && \
    /opt/conda/bin/python -c "import duckdb; assert duckdb.__version__ == '${DUCKDB_VERSION}', duckdb.__version__"

# FUSE for non-root users and the /osn mount root
RUN echo "user_allow_other" >> /etc/fuse.conf && \
    chmod 644 /etc/fuse.conf && \
    mkdir -p /osn && chmod 755 /osn && chown 1000:1000 /osn

# Root-run steps above (HOME=/config) leave root-owned caches in /config
RUN chown -R 1000:1000 /config

USER vscode
ENV HOME=/config

# Agent CLIs: Claude Code, OpenAI Codex, Claude Code Router (AI Verde bridge),
# and the filesystem MCP server, into a user-local npm prefix
# Versions pinned (ARGs above); the agent configs run mcp-server-filesystem directly
RUN npm config set prefix /config/.npm-global && \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
        "@musistudio/claude-code-router@${CCR_VERSION}" "@modelcontextprotocol/server-filesystem@${MCP_FS_VERSION}" && \
    npm cache clean --force && \
    test -x /config/.npm-global/bin/mcp-server-filesystem

# Antigravity CLI (agy, replaces Gemini CLI) and OpenCode
RUN mkdir -p /config/.cache/antigravity/staging && \
    curl -fsSL https://antigravity.google/cli/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path --version "${OPENCODE_VERSION}" && \
    /config/.opencode/bin/opencode --version | grep -F "${OPENCODE_VERSION}"

# VS Code extensions (Cline = saoudrizwan.claude-dev)
RUN /app/code-server/bin/code-server --install-extension ms-python.python && \
    /app/code-server/bin/code-server --install-extension vscode-icons-team.vscode-icons && \
    /app/code-server/bin/code-server --install-extension ms-toolsai.jupyter && \
    /app/code-server/bin/code-server --install-extension saoudrizwan.claude-dev

# Shell: MESA prompt + landing screen (no per-shell `sudo gocmd upgrade`: gocmd is
# pinned at build time; a root-run self-updater on every terminal was a supply-chain path)
RUN echo ". /etc/profile.d/mesa-prompt.sh" >> /config/.bashrc && \
    echo 'if [[ $- == *i* ]] && [ -r /etc/motd ]; then /etc/motd; fi' >> /config/.bashrc && \
    printf 'set-option -g status off\nset -g mouse on\n' >> /config/.tmux.conf

ENV PATH="/config/.local/bin:/config/.npm-global/bin:/config/.opencode/bin:/usr/local/go/bin:/opt/conda/bin:/usr/games:${PATH}"

EXPOSE 8080

WORKDIR /home/vscode/data-store

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:8080/ || exit 1

# ---------------------------------------------------------------------------
# Config / assets last so edits rebuild in seconds without busting the heavy
# install layers above.
# ---------------------------------------------------------------------------
COPY --chmod=755 01-custom /etc/motd
COPY mesa-prompt.sh /etc/profile.d/mesa-prompt.sh
COPY --chmod=755 entry.sh /bin/entry.sh
COPY --chmod=755 mesa-init.sh /usr/local/bin/mesa-init.sh
COPY --chmod=755 osn-mount.sh /usr/local/bin/osn-mount.sh
COPY --chmod=755 configs/aiverde-setup.sh /usr/local/bin/aiverde-setup
COPY --chmod=755 configs/cyverse-login.sh /usr/local/bin/cyverse-login
COPY --chmod=755 configs/mesa-mcp-shim.sh /usr/local/bin/mesa-mcp

COPY --chown=1000:1000 config.yaml /config/.config/code-server/config.yaml
COPY --chown=1000:1000 configs/claude.json /config/.claude.json
COPY --chown=1000:1000 configs/codex-config.toml /config/.codex/config.toml
COPY --chown=1000:1000 configs/opencode.json /config/.config/opencode/opencode.json
COPY --chown=1000:1000 configs/antigravity-mcp_config.json /config/.gemini/config/mcp_config.json
COPY --chown=1000:1000 cline_mcp_settings.json /config/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json

# COPY --chown does not chown the parent dirs it creates
RUN sudo chown -R 1000:1000 /config

ENTRYPOINT ["bash", "/bin/entry.sh"]
