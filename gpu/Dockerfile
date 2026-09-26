# syntax=docker/dockerfile:1
# MESA VS Code — NVIDIA GPU variant. Adds a CUDA PyTorch env + Jupyter kernel,
# Ollama, GPU/CUDA VS Code extensions and GPU tooling on top of the published
# CPU image, and removes the NVIDIA driver userspace that image bakes in.
# See ../README.md "GPU variant (:gpu)".
ARG BASE_IMAGE=harbor.cyverse.org/vice/mesa-vscode:latest

# cuda-probe: tiny glibc-only helper used by mesa-gpu-env.sh and mesa-gpu-check
FROM ubuntu:24.04 AS cuda-probe
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY --chmod=644 common/cuda-probe.c /src/cuda-probe.c
RUN gcc -O2 -Wall -o /cuda-probe /src/cuda-probe.c -ldl

# Build-time-only inputs (bind-mounted, never in the image). A bind mount keeps
# the build context's modes, so copy them here with explicit ones: a checkout
# made under a restrictive umask must still be readable by the vscode user.
FROM scratch AS build-files
COPY --chmod=644 common/patch-agent-configs.py /patch-agent-configs.py

FROM ${BASE_IMAGE}

LABEL org.label-schema.name="CyVerse VICE MESA VS Code (NVIDIA GPU)" \
      org.label-schema.description="VS Code (code-server) with an NVIDIA GPU stack: CUDA 12.5 toolkit, PyTorch (CUDA 12.6) env and Jupyter kernel, Ollama, Nsight/clangd/CMake/Continue extensions, agentic AI CLIs and MESA MCP servers for CyVerse VICE" \
      org.label-schema.url="https://cyverse.org" \
      org.label-schema.vcs-url="https://github.com/idss-mesa/vscode" \
      org.label-schema.vendor="CyVerse" \
      org.label-schema.schema-version="1.0.0"

USER root
# RUN under bash -o pipefail, as in cli/jupyterlab: every pipe below fails the build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Each version ARG is declared just above the first RUN that uses it: an ARG is
# part of the cache key of every later RUN, so an Ollama or CUDA compat bump
# declared up here would re-run the ~8 GB PyTorch env layer. For the same reason
# the PyTorch env and extensions come first and the CUDA compat and Ollama
# layers after them.

# Un-bake the NVIDIA driver userspace. The CPU image's `nvidia-driver-535` is a
# transitional package on noble that installs the R580 userspace (libcuda /
# libnvidia-ml 580.178.04, DKMS source, X driver, ...). The NVIDIA runtime
# mounts the HOST driver's libs next to those and ldconfig prefers the newer
# baked copies, so on any host older than 580.178.04 (e.g. R535) NVML fails:
# "Failed to initialize NVML: Driver/library version mismatch". The package
# list is derived from dpkg, not hard-coded, and nothing is autoremoved; the
# CUDA 12.5 toolkit (cuda-* / nsight-* packages) must survive untouched.
RUN drv=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | \
          awk '$1 ~ /^.i/ && $2 ~ /^(nvidia-|libnvidia-|xserver-xorg-video-nvidia|libxnvctrl|screen-resolution-extra$|cuda-drivers)/ {print $2}') && \
    cuda_pkgs() { dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' 'cuda-*' 'nsight-*' | awk '$1 == "ii"'; } && \
    cuda_before=$(cuda_pkgs) && \
    printf 'Purging baked NVIDIA driver userspace:\n%s\n' "$drv" && \
    echo "$drv" | xargs -r apt-get purge -y && \
    if [ "$(cuda_pkgs)" != "$cuda_before" ]; then echo 'purging the driver removed CUDA toolkit packages' >&2; exit 1; fi && \
    dpkg-query -W -f='${db:Status-Abbrev}\n' 'cuda-toolkit-12-*' | grep '^ii' >/dev/null && \
    rm -f /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libcudadebugger.so* \
          /usr/lib/x86_64-linux-gnu/libnvidia-*.so* && \
    ldconfig && \
    if ldconfig -p | grep -E 'libcuda\.so|libnvidia-ml\.so'; then echo 'NVIDIA driver libraries are still in the linker cache' >&2; exit 1; fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# PyTorch env for GPU work, owned by vscode like the rest of /opt/conda. Python
# 3.13 (the base env is 3.14, which not every CUDA wheel supports yet). torch
# comes from the CUDA 12.6 index: it runs on any driver >= R525 (the T4/R535
# floor and R580+ A16/A100 nodes alike) and covers sm_50..sm_90. Plain PyPI
# torch is the CUDA 13 build and needs R580+. The later install is constrained
# to the exact torch/torchvision/triton/nvidia-* builds so nothing swaps them.
USER vscode
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126
ARG TORCH_VERSION=2.14.0
ARG TORCHVISION_VERSION=0.29.0
RUN /opt/conda/bin/mamba create -y -p /opt/conda/envs/pytorch -c conda-forge --override-channels python=3.13 pip && \
    /opt/conda/envs/pytorch/bin/pip install --no-cache-dir \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" --index-url "${TORCH_INDEX_URL}" && \
    /opt/conda/envs/pytorch/bin/pip freeze | grep -iE '^(torch|torchvision|triton|nvidia-[a-z0-9-]+)==' > /tmp/torch-constraints.txt && \
    grep -iE '^(torch|torchvision)==' /tmp/torch-constraints.txt > /tmp/torch-core.txt && \
    /opt/conda/envs/pytorch/bin/pip install --no-cache-dir -c /tmp/torch-constraints.txt --extra-index-url "${TORCH_INDEX_URL}" \
        transformers accelerate datasets peft sentence-transformers safetensors bitsandbytes \
        lightning timm torchmetrics cupy-cuda12x nvitop nvidia-ml-py huggingface_hub ollama ipykernel && \
    /opt/conda/envs/pytorch/bin/pip check && \
    /opt/conda/envs/pytorch/bin/pip freeze | grep -iE '^(torch|torchvision)==' | diff /tmp/torch-core.txt - && \
    kname=$(/opt/conda/envs/pytorch/bin/python -c 'import re, torch; v = re.match(r"\d+\.\d+", torch.__version__).group(); print(f"PyTorch {v} (CUDA {torch.version.cuda})")') && \
    /opt/conda/envs/pytorch/bin/python -m ipykernel install --user --name pytorch --display-name "$kname" && \
    rm -f /tmp/torch-constraints.txt /tmp/torch-core.txt && \
    /opt/conda/bin/mamba clean -afy

# VS Code extensions from Open VSX: NVIDIA Nsight (cuda-gdb debugging), clangd
# (C++/CUDA IntelliSense; Microsoft's cpptools is not on Open VSX), CMake Tools,
# and Continue (chat/edit with the local Ollama model). .cu/.cuh highlighting is
# built into code-server (cuda-cpp language).
RUN for ext in nvidia.nsight-vscode-edition llvm-vs-code-extensions.vscode-clangd ms-vscode.cmake-tools continue.continue; do \
        /app/code-server/bin/code-server --install-extension "$ext" && \
        /app/code-server/bin/code-server --list-extensions | grep -ix "$ext" >/dev/null || exit 1; \
    done && \
    rm -rf /config/.local/share/code-server/CachedExtensionVSIXs/* /config/.local/share/code-server/logs/*
USER root

# One pin for the CUDA forward-compat driver: the apt package
# (cuda-compat-13-4) and its versioned path (MESA_CUDA_COMPAT_DIR, read by
# /etc/profile.d/mesa-gpu-env.sh) both derive from it, so a bump cannot leave
# the env pointing at a directory that does not exist.
ARG CUDA_COMPAT_VERSION=13.4
ENV MESA_CUDA_COMPAT_DIR=/usr/local/cuda-${CUDA_COMPAT_VERSION}/compat

# NVIDIA apt repo (CUDA forward-compat driver only — never driver packages),
# nvtop, zstd; clangd + cmake + ninja back the clangd / CMake Tools extensions
# (C++/CUDA IntelliSense and builds). cuda-compat stays at its versioned path:
# /usr/local/cuda must keep resolving to the 12.x toolkit, never to cuda-13.x.
# The driver guard redirects grep instead of `grep -q`: under the pipefail SHELL
# above, an early grep exit SIGPIPEs dpkg and the check would silently pass.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl zstd nvtop \
        clangd cmake ninja-build && \
    curl -fsSL -o /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i /tmp/cuda-keyring.deb && rm -f /tmp/cuda-keyring.deb && \
    apt-get update && apt-get install -y --no-install-recommends "cuda-compat-$(printf '%s' "${CUDA_COMPAT_VERSION}" | tr . -)" && \
    test -e "${MESA_CUDA_COMPAT_DIR}/libcuda.so.1" && \
    test ! -e /usr/local/cuda/compat && \
    case "$(readlink -f /usr/local/cuda)" in /usr/local/cuda-12.*) ;; \
        *) echo "/usr/local/cuda -> $(readlink -f /usr/local/cuda): expected the CUDA 12 toolkit" >&2; exit 1 ;; esac && \
    if dpkg -l | grep -E '^ii +(nvidia-driver|nvidia-dkms|nvidia-utils|nvidia-compute-utils|libnvidia-(compute|gl|decode|encode|extra|fbc1|cfg1|common)|cuda-drivers)' >/dev/null; then \
        echo 'NVIDIA driver userspace must not be baked into the image' >&2; exit 1; fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Ollama (pinned, sha256-checked; never install.sh). The CPU image pipes
# install.sh: drop its unused `ollama` system user, home and systemd unit (no
# systemd in VICE). Its binary + runners (2.1 GB) are kept only when they are
# byte-identical to the pinned tarball, because replacing identical files in
# this child layer would duplicate them; otherwise the tarball replaces them.
# :latest pulls the newest Ollama on every (weekly) rebuild, so when the build
# log warns below, bump OLLAMA_VERSION + OLLAMA_SHA256 to the CPU image's
# version (hash: the release's sha256sum.txt) to keep :gpu ~2 GB smaller.
ARG OLLAMA_VERSION=0.34.4
ARG OLLAMA_SHA256=c238986e61d40c0cc5f4a9b9e40b9eea104350b77efa34741fc134e105cb9533
RUN rm -rf /usr/share/ollama /etc/systemd/system/ollama.service && \
    (! id ollama >/dev/null 2>&1 || userdel ollama) && \
    (! getent group ollama >/dev/null || groupdel ollama) && \
    curl -fsSL -o /tmp/ollama.tar.zst "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst" && \
    echo "${OLLAMA_SHA256}  /tmp/ollama.tar.zst" | sha256sum -c - && \
    mkdir /tmp/ollama && zstd -dc /tmp/ollama.tar.zst | tar -xf - -C /tmp/ollama && rm -f /tmp/ollama.tar.zst && \
    if cmp -s /tmp/ollama/bin/ollama /usr/local/bin/ollama && diff -r /tmp/ollama/lib/ollama /usr/local/lib/ollama >/dev/null; then \
        echo "CPU image's Ollama is identical to the v${OLLAMA_VERSION} tarball: keeping it"; \
    else \
        base_ver=$({ /usr/local/bin/ollama --version 2>&1 || true; } | sed -n 's/.*client version is //p'); \
        echo "WARNING: the CPU image ships Ollama ${base_ver:-(none)}, not v${OLLAMA_VERSION}: replacing it with the pinned tarball stores Ollama twice (~2 GB more). Set OLLAMA_VERSION/OLLAMA_SHA256 in gpu/Dockerfile to the CPU image's version to avoid that." >&2; \
        rm -rf /usr/local/bin/ollama /usr/local/lib/ollama && cp -a /tmp/ollama/. /usr/local/; \
    fi && \
    rm -rf /tmp/ollama && \
    mv /usr/local/bin/ollama /usr/local/bin/ollama.bin

# ---------------------------------------------------------------------------
# Scripts / config last so edits rebuild in seconds without busting the heavy
# layers above. Every COPY sets its mode (644 sourced/config, 755 executables)
# so the image does not depend on the build host's umask.
# ---------------------------------------------------------------------------
COPY --from=cuda-probe --chmod=755 /cuda-probe /usr/local/bin/cuda-probe
COPY --chmod=644 common/mesa-gpu-env.sh /etc/profile.d/mesa-gpu-env.sh
COPY --chmod=755 common/ollama-wrapper.sh /usr/local/bin/ollama
COPY --chmod=755 common/mesa-ollama-start.sh /usr/local/bin/mesa-ollama-start
COPY --chmod=755 common/mesa-gpu-entrypoint.sh /usr/local/bin/mesa-gpu-entrypoint
COPY --chmod=755 common/mesa-gpu-check.sh /usr/local/bin/mesa-gpu-check
COPY --chmod=755 common/ollama-setup.sh /usr/local/bin/ollama-setup
COPY --chmod=755 common/motd-gpu.sh /etc/mesa/motd-gpu.sh
COPY --chmod=644 gpu-check-nvcc.sh /etc/mesa/gpu-check.d/50-nvcc.sh
# apt refuses NVIDIA driver packages in a session: vscode has passwordless sudo
# and the NVIDIA apt repo is configured, so `sudo apt install cuda-drivers` /
# `cuda-12-x` / `nvidia-driver-*` would re-bake the userspace purged above and
# break NVML again (`cuda-toolkit-12-x` installs are unaffected). Shared file,
# see its header. (The build's own apt step is covered by the guard above.)
COPY --chmod=644 common/apt-no-nvidia-driver.pref /etc/apt/preferences.d/mesa-no-nvidia-driver

# Landing screen: the CPU splash (/etc/motd, run by ~/.bashrc) + the GPU panel,
# which (like the README) points at nvitop: it lives in the PyTorch env, so link
# it onto PATH (absolute shebang, works from any shell). The IDE inherits the
# entrypoint's forward-compat env; docker/kubectl exec shells do not, so
# interactive bash sources mesa-gpu-env.sh too (a no-op when MESA_GPU_ENV_DONE
# is inherited). The hook directory is created by COPY: set its mode explicitly.
RUN mv /etc/motd /etc/mesa/motd-base && \
    printf '#!/bin/bash\n/etc/mesa/motd-base\n/etc/mesa/motd-gpu.sh\n' > /etc/motd && chmod 755 /etc/motd && \
    chmod 755 /etc/mesa /etc/mesa/gpu-check.d && \
    ln -s /opt/conda/envs/pytorch/bin/nvitop /usr/local/bin/nvitop && nvitop --version && \
    printf '\n# MESA GPU: CUDA forward-compat env for shells not started by the IDE (docker/kubectl exec)\nif [ -r /etc/profile.d/mesa-gpu-env.sh ]; then . /etc/profile.d/mesa-gpu-env.sh; fi\n' >> /etc/bash.bashrc

# NVIDIA_VISIBLE_DEVICES is deliberately NOT set: docker --gpus / the k8s
# device plugin set it for containers that were allocated a GPU.
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
    OLLAMA_KEEP_ALIVE=5m OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 CUDA_CACHE_MAXSIZE=1073741824 \
    CUDA_HOME=/usr/local/cuda \
    PATH="/usr/local/cuda/bin:${PATH}" \
    MESA_TORCH_PYTHON=/opt/conda/envs/pytorch/bin/python

# User config (owned by vscode; COPY --chown does not chown the parent dirs it
# creates, so they are made by vscode first): register the local Ollama server
# with OpenCode + Codex, point Continue at it, CUDA defaults for clangd, and the
# PyTorch env as the default Python interpreter (Continue telemetry off, like
# code-server's --disable-telemetry).
USER vscode
RUN --mount=type=bind,from=build-files,source=/patch-agent-configs.py,target=/tmp/patch-agent-configs.py \
    python3 /tmp/patch-agent-configs.py --opencode /config/.config/opencode/opencode.json --codex /config/.codex/config.toml && \
    mkdir -p /config/.continue /config/.config/clangd
COPY --chown=1000:1000 --chmod=644 continue-config.yaml /config/.continue/config.yaml
COPY --chown=1000:1000 --chmod=644 clangd-config.yaml /config/.config/clangd/config.yaml
COPY --chown=1000:1000 --chmod=644 code-server-settings.json /config/.local/share/code-server/User/settings.json

WORKDIR /home/vscode/data-store

ENTRYPOINT ["/usr/local/bin/mesa-gpu-entrypoint", "bash", "/bin/entry.sh"]
