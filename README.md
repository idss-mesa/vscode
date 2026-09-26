# MESA VS Code — CyVerse VICE

A browser [VS Code](https://github.com/coder/code-server) (code-server) workbench for the **MESA** project, built to run as a [CyVerse Discovery Environment (VICE)](https://cyverse.org/discovery-environment) app, with GPU support, the MESA agentic AI stack, and CyVerse Data Store tooling.

![harbor](https://github.com/idss-mesa/vscode/actions/workflows/harbor.yml/badge.svg) ![platforms](https://img.shields.io/badge/platforms-linux%2Famd64-blue) ![registry](https://img.shields.io/badge/registry-harbor.cyverse.org%2Fvice%2Fmesa--vscode-0a7bbb)

Built from the `latest` image in [cyverse-vice/vscode](https://github.com/cyverse-vice/vscode), with the MESA agentic stack from [idss-mesa/jupyterlab](https://github.com/idss-mesa/jupyterlab) layered on top.

## What's inside

| Category | Tools |
| --- | --- |
| **IDE** | code-server on port 8080 with Python, Jupyter, vscode-icons, and [Cline](https://github.com/cline/cline) extensions (Cline pre-loaded with the MESA MCP servers) |
| **GPU / ML** | NVIDIA CUDA 12.5 toolkit, `nvtop`, [Ollama](https://ollama.com/). `:latest` also bakes the NVIDIA R580 driver userspace (`nvidia-driver-535` is a transitional package on Ubuntu 24.04), which breaks `nvidia-smi`/NVML on hosts with an older driver — for GPU work use the [`:gpu` variant](#gpu-variant-gpu) |
| **Science** | Miniconda + Mamba (`/opt/conda`) |
| **Transfer** | Globus Connect Server 5.4 |
| **AI agent CLIs** | Claude Code (`claude`), OpenAI Codex (`codex`), OpenCode (`opencode`), Antigravity (`agy`), Claude Code Router (`ccr`) |
| **MCP servers** | `irods` (CyVerse Data Store), `mesa` ([mesa-mcp](https://github.com/idss-mesa/mesa-mcp) + [mesa-ducklake](https://github.com/idss-mesa/mesa-ducklake)), `formation` ([formation-mcp](https://github.com/idss-mesa/formation-mcp), CyVerse DE), `filesystem` — pre-registered for every agent CLI |
| **AI Verde** | `aiverde-setup` helper wires OpenCode + Claude Code (via `ccr`) to `https://llm-api.cyverse.ai` |
| **CyVerse data** | GoCommands (`gocmd`), iRODS config, `s3fs`/OSN mounts (`osn-mount.sh`), AWS CLI |
| **Dev** | GitHub CLI (`gh`), Git Credential Manager, Go 1.25, Node.js 22 |

Base image: `lscr.io/linuxserver/code-server:latest` (Ubuntu 24.04). Runs as `vscode` (uid 1000) with `HOME=/config`; VS Code opens `/data-store/iplant/home/$IPLANT_USER` when the Data Store is mounted, else `/home/vscode/data-store`.

## Run it

```bash
docker run --rm -p 8080:8080 -e IPLANT_USER=$USER harbor.cyverse.org/vice/mesa-vscode:latest
# with GPUs: use the GPU variant (see "GPU variant (:gpu)"); loopback only, as below
docker run --rm --gpus all -p 127.0.0.1:8080:8080 -e IPLANT_USER=$USER harbor.cyverse.org/vice/mesa-vscode:gpu
```

Then open <http://localhost:8080> (no password — VICE's ingress handles auth). In VICE, register the tool on port **8080**.

## DE tool settings

These live in the Discovery Environment, not in this repo, and must match the image. Change them only together with the Dockerfile.

| Setting | Value |
| --- | --- |
| DE app | **MESA VS Code** (`011736c4-b936-11f1-a4f5-008cfa5ae3e1`) |
| DE tool (version `1.0.0`) | `mesa-vscode` (`e2386a66-b935-11f1-a355-008cfa5ae3e1`) |
| Image | `harbor.cyverse.org/vice/mesa-vscode:latest` |
| Type | interactive (`interactive: true`) |
| Network mode | `bridge` (Terrain's default `none` gives an analysis that runs but never serves) |
| Skip /tmp mount | `true` (VNC/X and IPC sockets live in /tmp) |
| VICE proxy | `interactive_apps` = cas-proxy (`discoenv/cas-proxy`), as on the featured apps |
| Container port | **8080** |
| Working directory | `/home/vscode/data-store` (the Data Store CSI mount point; must match the Dockerfile `WORKDIR`) |
| UID | 1000 |
| Entrypoint override | none (the image's own startup script does the MESA per-user setup) |
| Max CPU | 16 cores (upstream `vice/vscode`) |
| Memory limit | 16 GiB (DE user cap; upstream 64 GiB) |

code-server runs with `--bind-addr 0.0.0.0:8080`; `config.yaml`'s `127.0.0.1:8080` is overridden.

## Sign in to CyVerse

```bash
cyverse-login          # your CyVerse username + password
```

Writes the standard iRODS credential files (`~/.irods/`) so GoCommands, the `mesa`
and `formation` MCP servers, and the agents all act as **you** — with write/own
access to your home and shared collections. Without it you get anonymous, public
read-only access.

For the hosted CyVerse Data Store MCP, **Claude Code** registers **two** servers:
`irods` points at the anonymous
[public endpoint](https://mcp-public.cyverse.ai/mcp) (public data under
`/iplant/home/shared`, no sign-in) and works out of the box; `irods-auth` points
at the [authenticated endpoint](https://mcp.cyverse.ai/mcp), which uses CyVerse's
pre-registered OAuth client (`mcp-client`). Sign in to `irods-auth` once per
session to reach your private home collection:

```bash
claude mcp login irods-auth --no-browser   # opens a kc.cyverse.org URL; paste the redirect back
```

For private-collection access under OpenCode, Codex, and Antigravity, rely on
`cyverse-login`: the bundled **local** `mesa`/iRODS MCP servers and `gocmd` read
your `~/.irods` credentials directly (no OAuth) and act as you. Restart an agent
after logging in so its MCP servers pick up the credentials.

## Connect AI Verde LLMs

Each user authenticates with their **own** institutional identity — no API key is baked into the image. Inside a terminal:

```bash
aiverde-setup          # paste your key from chat.cyverse.ai → Course → API Key
```

It validates the key against `/v1/models`, lists your models, and writes `~/.config/aiverde/env` (chmod 600). Then:

- **OpenCode** — uses the `aiverde` provider directly.
- **Claude Code** — uses `ccr` for non-Anthropic models (`ccr code`), or the native `ANTHROPIC_BASE_URL` env path if your course serves Anthropic models.
- **Codex** — *not* wired to AI Verde: Codex dropped Chat Completions support and AI Verde does not serve the Responses API. It runs on its own OpenAI auth.

## GPU variant (`:gpu`)

`harbor.cyverse.org/vice/mesa-vscode:gpu` layers an NVIDIA GPU stack on the published `:latest` image ([`gpu/Dockerfile`](gpu/Dockerfile)); everything above still applies. Target: the DE's **NVIDIA A16** nodes (Ampere, sm_86, 16 GB); tested on Tesla T4 (sm_75) with driver R535, the oldest branch it must support.

| Adds | Details |
| --- | --- |
| **Host driver, not a baked one** | Purges the NVIDIA R580 driver userspace that `:latest` bakes in (`nvidia-driver-535` is a transitional package on Ubuntu 24.04 that installs R580). `libcuda`/NVML come from the host driver the NVIDIA runtime injects, so `nvidia-smi`, `nvtop` and NVML work on any driver branch. An apt pin ([`/etc/apt/preferences.d/mesa-no-nvidia-driver`](gpu/common/apt-no-nvidia-driver.pref)) makes apt refuse `nvidia-driver-*`, the driver's `libnvidia-*` libraries and `cuda-drivers` (which `cuda-12-x` pulls in), so `sudo apt install` cannot re-bake it in a session; install `cuda-toolkit-12-x` instead. To install driver packages on purpose anyway, `sudo rm` that file first |
| **CUDA** | CUDA 12.5 toolkit on `PATH` (`nvcc`, `cuda-gdb`, `compute-sanitizer`, Nsight CLIs), `CUDA_HOME=/usr/local/cuda`; NVIDIA's CUDA 13.4 forward-compat driver (`cuda-compat-13-4`), enabled only when needed (below) |
| **PyTorch env** | `/opt/conda/envs/pytorch` (Python 3.13): PyTorch 2.14 + torchvision (CUDA 12.6 build), transformers, accelerate, datasets, peft, sentence-transformers, safetensors, bitsandbytes, lightning, timm, torchmetrics, CuPy, nvitop, huggingface_hub, ollama. The default VS Code interpreter and a Jupyter kernel **PyTorch 2.14 (CUDA 12.6)** |
| **Local LLMs** | [Ollama](https://ollama.com) 0.34.4 (pinned, sha256-checked tarball; the `install.sh` user and systemd unit are removed), started on `127.0.0.1:11434` at launch; `ollama-setup` wires Claude Code, Codex and OpenCode to it |
| **VS Code extensions** | NVIDIA Nsight (CUDA debugging), clangd (C++/CUDA IntelliSense; `~/.config/clangd/config.yaml` sets CUDA defaults for `.cu`/`.cuh`) and CMake Tools with `clangd`/`cmake`/`ninja`, [Continue](https://continue.dev) pre-configured for the local Ollama model (`~/.continue/config.yaml`) |
| **Diagnostics** | `mesa-gpu-check`, `nvtop`, `nvitop` (from the PyTorch env, linked onto `PATH`), a GPU panel on the terminal landing screen |

The GPU image is about **25.5 GB** uncompressed (CPU `:latest`: 16.2 GB). That includes ~1.1 GB of NVIDIA 580 driver userspace baked into the CPU image, which the GPU layer purges but cannot remove from the base layers (see *Size* below).

### Run it locally

```bash
docker run --rm --gpus all -p 127.0.0.1:8080:8080 -e IPLANT_USER=$USER harbor.cyverse.org/vice/mesa-vscode:gpu    # or: make run-gpu
```

Then open <http://localhost:8080>. The port is bound to loopback because code-server has no password outside VICE (in VICE the cas-proxy does auth) and `vscode` has passwordless `sudo`; on a remote GPU server, tunnel to it (`ssh -L 8080:127.0.0.1:8080 <gpu-host>`) instead of publishing it on all interfaces. Without a GPU it still starts (CPU only), and `mesa-gpu-check` says no GPU is attached.

`MESA_OLLAMA_AUTOSTART=0` (no Ollama server at launch) and `MESA_DISABLE_CUDA_COMPAT=1` (no forward-compat driver) are read once at container start, before `entry.sh` sources your `~/.env*` files, so setting them there has no effect. Set them as container environment variables instead: `docker run -e`, or an *Environment Variable* parameter on the DE app.

### Local LLMs (Ollama)

```bash
ollama-setup                                    # pull qwen3.5:9b (default) and print the agent commands
ollama-setup gpt-oss:20b                        # or another model
ollama launch claude --model qwen3.5:9b         # Claude Code on the local model
codex --oss --local-provider ollama -m qwen3.5:9b
opencode -m ollama/qwen3.5:9b
```

Continue's **Qwen3.5 9B (local GPU)** model needs the same `ollama-setup` first. Models that fit one 16 GB GPU: `qwen3.5:9b`, `gpt-oss:20b`, `gemma4:12b`, `qwen3:4b`; 30B+ models spill to the CPU. The context is 32768 tokens (`OLLAMA_CONTEXT_LENGTH`; Ollama's own default on one 16 GB GPU is 4096, too small for agents). Models live in `~/.ollama/models` on container disk and are gone when the analysis ends. `ollama stop <model>` frees the GPU memory for PyTorch; `MESA_OLLAMA_AUTOSTART=0` (a container variable, see above) skips the server at launch.

### Check the GPU

```bash
mesa-gpu-check            # driver, libcuda, forward-compat, PyTorch, nvcc kernel, Ollama
mesa-gpu-check --ollama   # also pull qwen3:0.6b and confirm it runs 100% on the GPU
```

### CUDA and driver compatibility

- **PyTorch** is the CUDA 12.6 build (cu126): it runs on any driver ≥ R525, i.e. both the R535 T4 test host and R580+ nodes, and covers sm_50–sm_90 (T4, A100, A16, H100; not Blackwell). A plain `pip install torch` from PyPI would pull the CUDA 13 build (needs R580+); add `--extra-index-url https://download.pytorch.org/whl/cu126` when installing packages that depend on torch.
- **Ollama 0.34.4** needs R550+ for its CUDA 12 runner and R580+ for CUDA 13; other CUDA 13 software needs R580+. On pre-R580 hosts, at startup `/etc/profile.d/mesa-gpu-env.sh` puts the forward-compat driver (`/usr/local/cuda-13.4/compat`) on `LD_LIBRARY_PATH`, but only when the host's CUDA driver API is < 13 **and** `cuInit` works with it (data-center GPUs such as A16, A100, T4). R580+ hosts are left alone. The IDE and its terminals inherit it from the entrypoint; `docker exec`/`kubectl exec` `bash -i` shells get it from `/etc/bash.bashrc`. Opt out with `MESA_DISABLE_CUDA_COMPAT=1` (a container variable, see above; on pre-R580 hosts Ollama then runs on the CPU; PyTorch and SASS-built kernels still use the GPU).
- **nvcc** (12.5): build real SASS for the GPUs you run on, e.g. `nvcc -gencode arch=compute_86,code=sm_86 ...` for the A16 (add `-gencode arch=compute_75,code=sm_75` for T4, `arch=compute_80,code=sm_80` for A100, or use `-arch=native`). PTX-only builds (`code=compute_XX`, and nvcc's default target on these GPUs) need a driver that can JIT CUDA 12.5 PTX (R555+) or the forward-compat driver, which is on by default on pre-R580 hosts; otherwise the kernel never runs (`cudaErrorUnsupportedPtxVersion`, silent unless you check launch errors).

### Build & publish from a GPU server

The GPU image is built `FROM` the published CPU image, so `docker build` needs no GPU. The build host needs Docker with buildx and ~60 GB free disk, plus an NVIDIA GPU and nvidia-container-toolkit for `make test-gpu`. On a GPU build host (e.g. the A100 server):

```bash
git clone https://github.com/idss-mesa/vscode.git && cd vscode
docker login harbor.cyverse.org
make pull-base build-gpu      # harbor.cyverse.org/vice/mesa-vscode:latest -> :gpu
make test-gpu GPU=0           # smoke test on GPU 0 (GPU=all for every GPU)
make push-gpu
```

- `make build build-gpu` layers on a fresh local CPU build instead of the published one.
- Build args (`docker buildx build --build-arg ...`): `BASE_IMAGE`, `TORCH_INDEX_URL` (move to `.../whl/cu130` once every node runs R580+), `TORCH_VERSION`, `TORCHVISION_VERSION`, `OLLAMA_VERSION` + `OLLAMA_SHA256`, `CUDA_COMPAT_VERSION`. `CUDA_COMPAT_VERSION` (13.4) is the single compat pin: it sets both the `cuda-compat-13-4` package and `MESA_CUDA_COMPAT_DIR` (`/usr/local/cuda-13.4/compat`), and the build fails if that directory has no `libcuda.so.1`.
- `gpu/test-gpu.sh` checks: host driver libs and nothing baked (T1), start as VICE does (T2), `mesa-gpu-check --ollama` (T3), nvcc SASS kernel, extensions + `nvtop`/`nvitop`, PyTorch env, Jupyter kernel, user config, clangd, the apt driver pin (T4a–g), the pin file and `apt-cache policy` (T4h; both apt checks are SKIPped without network), `docker exec bash -i` shells: forward-compat env as in the IDE and `nvitop` on `PATH` (T4i), and a start without a GPU (T5).
- CI alternative: the manual [`harbor-gpu`](.github/workflows/harbor-gpu.yml) workflow (Actions → harbor-gpu → Run workflow) builds on the digest of `:latest` and pushes `:gpu`, without a GPU test.
- `:gpu` is **not** rebuilt when `:latest` is: rebuild it after CPU image changes.
- Ollama drift: `:latest`'s weekly rebuild installs the newest Ollama. If `make build-gpu` then warns `the CPU image ships Ollama X, not v0.34.4`, the pinned tarball replaces it: `:gpu` grows by ~2.2 GB (to ~27.7 GB) and ships the older, pinned Ollama. To avoid that, set `ARG OLLAMA_VERSION` to the CPU image's version and `ARG OLLAMA_SHA256` to the `ollama-linux-amd64.tar.zst` line of that release's `sha256sum.txt` (`curl -fsSL https://github.com/ollama/ollama/releases/download/vX/sha256sum.txt`) in `gpu/Dockerfile`, then rebuild. Each version `ARG` is declared just above the first layer that uses it, and the CUDA compat and Ollama layers come after the PyTorch env, so an Ollama or `CUDA_COMPAT_VERSION` bump does not rebuild or re-push the 8.2 GB PyTorch layer.
- Size: about 25.5 GB uncompressed (CPU `:latest`: 16.2 GB); the GPU layers add 9.4 GB (PyTorch env 8.2 GB, CUDA compat + clangd/cmake 0.8 GB, extensions 0.4 GB). That is above the ~24 GB per-image budget only because of the CPU base: its baked driver packages (~1.1 GB) stay in the base layers, so purging them in a child layer saves nothing; dropping `nvidia-driver-*` from `latest/Dockerfile` would shrink both images. The CPU image's `install.sh` Ollama is reused when it is byte-identical to the pinned tarball, so it is not stored twice; the 25.5 GB assumes `:latest` still ships Ollama 0.34.4.

### DE tool settings (GPU)

The GPU DE app is a copy of **MESA VS Code** pointing at a GPU tool. [`gpu/de-tool.json`](gpu/de-tool.json) is the tool import body (Terrain admin `POST /terrain/admin/tools`; the GPU fields and the `/dev/shm` device are admin-only).

| Setting | Value |
| --- | --- |
| DE tool (version `1.0.0`) | `mesa-vscode-gpu` |
| Image | `harbor.cyverse.org/vice/mesa-vscode:gpu` |
| GPUs | `min_gpus` = `max_gpus` = **1** (with `min_gpus` unset the launch default of 0 gives no GPU) |
| GPU model | `gpu_models: ["NVIDIA-A16"]` (must be listed by `GET /terrain/tools/gpu-models`) |
| Shared memory | device `/dev/shm` → `4Gi` (RAM-backed, counts against memory; PyTorch DataLoader workers) |
| CPU / memory | 4–8 cores, 16–32 GiB |
| Everything else | as the CPU tool: port **8080**, working directory `/home/vscode/data-store`, UID 1000, network `bridge`, skip /tmp mount, cas-proxy; `pids_limit` 1024 (GPU tool) |

## Build

The build context is `latest/`:

```bash
make build             # linux/amd64 → harbor.cyverse.org/vice/mesa-vscode:latest
make run               # local smoke test
make push
```

The Dockerfile copies all config/asset files *after* the heavy layers, so editing configs rebuilds in seconds.

**CI:** pushes to `main` touching `latest/` — plus a weekly Sunday rebuild that tracks the upstream base image and agent-CLI releases — build and push `:latest` to Harbor ([`harbor.yml`](.github/workflows/harbor.yml)). hadolint lints both Dockerfiles on PRs and trivy scans the published `:latest` and `:gpu` images weekly, reporting to the repo Security tab (until `:gpu` is first pushed, its scan is skipped with a warning) ([`security.yml`](.github/workflows/security.yml)). Both need the `HARBOR_USERNAME` / `HARBOR_PASSWORD` repo secrets.

## Layout

```
latest/
  Dockerfile                    image definition (code-server + CUDA + conda + MESA agentic stack)
  entry.sh                      container entrypoint (mesa-init, restores .vscode-server / Cline settings, launches code-server under tini)
  config.yaml                   code-server config (auth: none)
  cline_mcp_settings.json       Cline MCP servers (irods, mesa, formation, filesystem)
  mesa-init.sh                  per-user startup (iRODS config, Data Store dotfile import, .env files, S3/OSN mounts)
  01-custom                     MESA ANSI splash screen (/etc/motd)
  mesa-prompt.sh                shell prompt (/etc/profile.d)
  osn-mount.sh                  s3fs mounts for OSN/S3 buckets
  configs/                      agent-CLI configs + aiverde-setup / cyverse-login / mesa-mcp shim
gpu/
  Dockerfile                    NVIDIA GPU variant (:gpu), built FROM the published :latest
  common/                       shared by the MESA GPU images, keep identical: cuda-probe, forward-compat env, Ollama wrapper/starter,
                                entrypoint prefix, mesa-gpu-check, ollama-setup, landing-screen GPU panel, agent-config patcher,
                                apt pin refusing NVIDIA driver packages
  gpu-check-nvcc.sh             mesa-gpu-check hook: builds and runs a CUDA kernel with nvcc
  continue-config.yaml          Continue extension config (local Ollama model)
  clangd-config.yaml            clangd user config: CUDA defaults for .cu/.cuh (sm_86)
  code-server-settings.json     VS Code user settings (PyTorch env as the Python interpreter, Continue telemetry off)
  test-gpu.sh                   GPU smoke test (make test-gpu)
  de-tool.json                  DE tool import body for mesa-vscode-gpu
Makefile                        local build/push/run (+ pull-base, build-gpu, test-gpu, push-gpu, run-gpu)
.github/workflows/              harbor.yml (build+push), harbor-gpu.yml (manual GPU build+push), security.yml (hadolint + trivy)
```

## Resources

- [CyVerse VICE apps](https://learning.cyverse.org/vice/) · [GoCommands](https://learning.cyverse.org/ds/gocommands/) · [AI Verde](https://aiverde-docs.cyverse.ai/) · [MESA docs](https://idss-mesa.github.io/docs/)
- Upstream: [cyverse-vice/vscode](https://github.com/cyverse-vice/vscode) · MESA org: <https://github.com/idss-mesa>
