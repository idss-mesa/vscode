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

# Version arguments for easier updates
ARG CUDA_VERSION="12-5"
ARG NVIDIA_DRIVER_VERSION="535"
ARG MINICONDA_VERSION="latest"
ARG GCM_VERSION="2.7.3"
ARG GO_VERSION="1.25.5"

# System dependencies: upstream cyverse-vice/vscode set plus the MESA stack
# (python3-venv for the /opt/mesa venv, gettext for envsubst, tini as PID 1,
# s3fs/fuse for OSN mounts, terminal niceties for the landing screen)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        lsb-release apt-transport-https ca-certificates curl wget gnupg \
        libfreetype6-dev pkg-config libx11-dev gcc gettext less \
        software-properties-common apt-utils glances htop nvtop nano \
        sudo pciutils unzip zstd git tmux tini socat bubblewrap \
        python3 python3-venv python3-pip \
        locales figlet lolcat s3fs fuse && \
    locale-gen en_US.UTF-8 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Node.js 22 (MESA standard; upstream used 23)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# User setup: the linuxserver base has no uid 1000, so create vscode:1000.
# HOME stays /config (code-server's settings/extensions dir in this base).
RUN (getent group 1000 > /dev/null || groupadd -g 1000 vscode) && \
    (id -u vscode > /dev/null 2>&1 || useradd -m -d /home/vscode -u 1000 -g 1000 -s /bin/bash vscode) && \
    usermod -aG sudo vscode && \
    echo "vscode ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/vscode/data-store /config/.irods && \
    chown -R vscode:1000 /home/vscode /config

# CUDA toolkit and NVIDIA drivers
RUN wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y cuda-toolkit-${CUDA_VERSION} nvidia-driver-${NVIDIA_DRIVER_VERSION} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Miniconda and Mamba
RUN curl -sSLo /tmp/Miniconda3.sh https://repo.anaconda.com/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh && \
    bash /tmp/Miniconda3.sh -b -p /opt/conda && \
    rm /tmp/Miniconda3.sh && \
    /opt/conda/bin/conda config --set channel_priority strict && \
    /opt/conda/bin/conda install -y mamba -n base -c conda-forge --override-channels && \
    /opt/conda/bin/conda clean -afy && \
    chown -R vscode:1000 /opt/conda

# Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

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

# Git Credential Manager
RUN wget -q https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-x64-${GCM_VERSION}.deb -O /tmp/gcm.deb && \
    dpkg -i /tmp/gcm.deb && rm -f /tmp/gcm.deb
ENV GCM_CREDENTIAL_STORE=cache

# Go, then the iRODS MCP server (stdio MCP access to the CyVerse Data Store)
# https://github.com/idss-mesa/irods-mcp-server
RUN wget -q -c https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz -O - | tar -xz -C /usr/local && \
    git clone --depth 1 https://github.com/idss-mesa/irods-mcp-server /tmp/irods-mcp-server && \
    cd /tmp/irods-mcp-server && \
    CGO_ENABLED=0 GOPATH=/tmp/go GOCACHE=/tmp/go-cache /usr/local/go/bin/go build -o /usr/local/bin/irods-mcp-server ./cmd/main.go && \
    cd / && rm -rf /tmp/irods-mcp-server /tmp/go /tmp/go-cache

# GoCommands https://learning.cyverse.org/ds/gocommands/
RUN cd /usr/local/bin && \
    GOCMD_VER=$(curl -L -s https://raw.githubusercontent.com/cyverse/gocommands/main/VERSION.txt) && \
    curl -L -s https://github.com/cyverse/gocommands/releases/download/${GOCMD_VER}/gocmd-${GOCMD_VER}-linux-${TARGETARCH}.tar.gz | tar zxvf -

# AWS CLI
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# mesa-mcp and mesa-ducklake (https://github.com/idss-mesa) in a dedicated venv,
# isolated from /opt/conda so user installs there cannot break them.
# cyverse-login hardcodes /opt/mesa/bin/python3 for iRODS password obfuscation.
RUN /usr/bin/python3 -m venv /opt/mesa && \
    /opt/mesa/bin/pip install --no-cache-dir \
      git+https://github.com/idss-mesa/mesa-ducklake.git \
      git+https://github.com/idss-mesa/mesa-mcp.git && \
    ln -s /opt/mesa/bin/mesa-ducklake /usr/local/bin/

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
RUN npm config set prefix /config/.npm-global && \
    npm install -g @anthropic-ai/claude-code @openai/codex @musistudio/claude-code-router \
        @modelcontextprotocol/server-filesystem && \
    npm cache clean --force

# Antigravity CLI (agy, replaces Gemini CLI) and OpenCode
RUN mkdir -p /config/.cache/antigravity/staging && \
    curl -fsSL https://antigravity.google/cli/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path

# VS Code extensions (Cline = saoudrizwan.claude-dev)
RUN /app/code-server/bin/code-server --install-extension ms-python.python && \
    /app/code-server/bin/code-server --install-extension vscode-icons-team.vscode-icons && \
    /app/code-server/bin/code-server --install-extension ms-toolsai.jupyter && \
    /app/code-server/bin/code-server --install-extension saoudrizwan.claude-dev

# Shell: MESA prompt + landing screen; gocmd upgrade is time-boxed so a slow
# network never hangs terminal spawns
RUN echo ". /etc/profile.d/mesa-prompt.sh" >> /config/.bashrc && \
    echo 'if [[ $- == *i* ]] && [ -r /etc/motd ]; then /etc/motd; fi' >> /config/.bashrc && \
    printf '\n# upgrade GoCommands\ntimeout 10 sudo gocmd upgrade > /dev/null 2>&1 || true\n' >> /config/.bashrc && \
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
