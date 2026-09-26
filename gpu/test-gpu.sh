#!/usr/bin/env bash
# test-gpu.sh — smoke test for the MESA VS Code NVIDIA GPU image (make test-gpu).
#
#   gpu/test-gpu.sh [IMAGE]            IMAGE defaults to harbor.cyverse.org/vice/mesa-vscode:gpu
#   GPU=1 gpu/test-gpu.sh IMAGE        GPU index to use (default 0; GPU=all = every GPU)
#   CPU_IMAGE=... gpu/test-gpu.sh      reference image for the informational T0
#                                      (default IMAGE with tag :latest, if present locally)
#
# Needs an NVIDIA GPU, docker and nvidia-container-toolkit (docker run --gpus).
# T3 pulls qwen3:0.6b (~0.5 GB) inside the test container; T4g/T4h run
# apt-get update against the live repos. Without network (apt-get update exits
# 0 anyway, but fetches no package lists) T4g and T4h SKIP their apt checks
# (shown in the summary). Containers are named
# mesa-gpu-vscode-*-<pid> and removed on exit; logs stay in $LOG_DIR.
# Exit status 0 = every test passed.
set -uo pipefail

IMAGE=${1:-harbor.cyverse.org/vice/mesa-vscode:gpu}
GPU=${GPU:-0}
CPU_IMAGE=${CPU_IMAGE:-${IMAGE%:*}:latest}
PORT=8080
START_TIMEOUT=${START_TIMEOUT:-300}
if [ "$GPU" = all ]; then GPUS=(--gpus all); else GPUS=(--gpus "device=$GPU"); fi
C_GPU=mesa-gpu-vscode-test-$$
C_NOGPU=mesa-gpu-vscode-nogpu-$$
C_APT=mesa-gpu-vscode-apt-$$
PIN_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common/apt-no-nvidia-driver.pref
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mesa-gpu-vscode-test.XXXXXX")

cleanup() { docker rm -f "$C_GPU" "$C_NOGPU" "$C_APT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

RESULTS=()
record() { # PASS|FAIL  name  detail
    RESULTS+=("$1|$2|$3")
    if [ "$1" = PASS ]; then printf '\e[32mPASS\e[0m %s — %s\n' "$2" "$3"; else printf '\e[31mFAIL\e[0m %s — %s\n' "$2" "$3"; fi
}
check() { # name  detail-on-success  command...   (output -> $LOG_DIR/<name>.log)
    local name=$1 detail=$2 log rc skip
    shift 2
    log="$LOG_DIR/${name%% *}.log"
    "$@" >"$log" 2>&1
    rc=$?
    sed 's/^/    /' "$log"
    # a passing test that skipped part of itself says so in the summary
    skip=$(grep -m1 '^SKIP' "$log")
    if [ $rc -eq 0 ]; then record PASS "$name" "$detail${skip:+ [$skip]}"; else record FAIL "$name" "exit $rc (see $log)"; fi
}
# Run a bash script (stdin) inside a container as the VICE user.
in_ctr() { timeout 900 docker exec -i -u 1000 "$1" bash -s; }

# Wait until code-server answers on its port and the container is still up.
wait_http() { # container
    local c=$1 hp code i=0
    hp=$(docker port "$c" "$PORT/tcp" | head -1)
    while [ $i -lt "$START_TIMEOUT" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
            echo "container exited:"; docker logs --tail 30 "$c" 2>&1
            return 1
        fi
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$hp/" || true)
        case "$code" in 200|302) echo "code-server on $hp answered HTTP $code after ${i}s"; return 0 ;; esac
        sleep 3; i=$((i + 3))
    done
    echo "no HTTP 200/302 from $hp within ${START_TIMEOUT}s"; docker logs --tail 30 "$c" 2>&1
    return 1
}

echo "== MESA VS Code GPU image test: $IMAGE (GPU=$GPU, logs in $LOG_DIR)"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not found (make build-gpu first)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# T0 (info only): the CPU image, if present locally, for comparison. While it
# bakes the R580 driver userspace, nvidia-smi fails there on hosts < 580.178.
# ---------------------------------------------------------------------------
if [ "$CPU_IMAGE" != "$IMAGE" ] && docker image inspect "$CPU_IMAGE" >/dev/null 2>&1; then
    echo; echo "-- T0 (info) CPU image $CPU_IMAGE with the same GPU:"
    docker run --rm "${GPUS[@]}" --entrypoint bash "$CPU_IMAGE" -c \
        'nvidia-smi -L 2>&1 | head -2; echo "  nvidia-smi rc=${PIPESTATUS[0]}"; echo "  libcuda.so.1 -> $(readlink -f "$(ldconfig -p | awk '\''$1 == "libcuda.so.1" {print $NF; exit}'\'')")"' \
        2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# T1 static: driver libs come from the host, nothing baked, toolkit layout
# ---------------------------------------------------------------------------
echo; echo "-- T1 static checks (docker run --gpus, no entrypoint)"
t1() {
    docker run --rm -i "${GPUS[@]}" --entrypoint bash "$IMAGE" -s <<'EOF'
fail=0
nvidia-smi -L || { echo "nvidia-smi failed"; fail=1; }
host=$(sed -nE 's/.*Kernel Module( for [a-z0-9_]+)?[[:space:]]+([0-9]+\.[0-9.]+).*/\2/p' /proc/driver/nvidia/version | head -1)
echo "host driver: $host"
for l in libcuda.so.1 libnvidia-ml.so.1; do
    r=$(readlink -f "$(ldconfig -p | awk -v l="$l" '$1 == l {print $NF; exit}')")
    echo "$l -> $r"
    case "$r" in *".so.$host") ;; *) echo "  $l is not the host driver's ($host)"; fail=1 ;; esac
done
baked=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 ~ /^.i/ && $2 ~ /^(nvidia-|libnvidia-|xserver-xorg-video-nvidia|cuda-drivers)/ {print $2}')
[ -z "$baked" ] || { echo "baked NVIDIA driver packages: $baked"; fail=1; }
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' 'cuda-toolkit-12-*' | grep '^ii' || { echo "cuda-toolkit-12-* missing"; fail=1; }
cuda=$(readlink -f /usr/local/cuda)
echo "/usr/local/cuda -> $cuda"
case "$cuda" in /usr/local/cuda-12.*) ;; *) echo "  expected the CUDA 12 toolkit"; fail=1 ;; esac
[ ! -e /usr/local/cuda/compat ] || { echo "/usr/local/cuda/compat exists (toolkit would force compat)"; fail=1; }
ls "$MESA_CUDA_COMPAT_DIR"/libcuda.so.1 || fail=1
[ -x /usr/local/bin/ollama.bin ] && ! id ollama >/dev/null 2>&1 && [ ! -e /usr/share/ollama ] && [ ! -e /etc/systemd/system/ollama.service ] \
    || { echo "old install.sh Ollama leftovers or pinned binary missing"; fail=1; }
echo "ollama: $(/usr/local/bin/ollama.bin --version 2>&1 | tail -1)"
exit $fail
EOF
}
check "T1 static" "nvidia-smi OK; libcuda/libnvidia-ml are the host driver's; no baked driver; /usr/local/cuda is 12.x" t1

# ---------------------------------------------------------------------------
# T2: start like VICE (uid 1000, IPLANT_USER, default entrypoint)
# ---------------------------------------------------------------------------
echo; echo "-- T2 start like VICE with a GPU"
docker run -d --name "$C_GPU" "${GPUS[@]}" --user 1000 -e IPLANT_USER=mesa-test \
    -p "127.0.0.1::$PORT" "$IMAGE" >/dev/null
check "T2 start (GPU)" "code-server answers on $PORT, container running" wait_http "$C_GPU"

# ---------------------------------------------------------------------------
# T3: shared diagnostics, including an Ollama model on the GPU
# ---------------------------------------------------------------------------
echo; echo "-- T3 mesa-gpu-check --ollama"
t3() { timeout 900 docker exec -u 1000 "$C_GPU" mesa-gpu-check --ollama; }
check "T3 mesa-gpu-check" "driver, CUDA, compat, torch, nvcc hook and Ollama (qwen3:0.6b 100% GPU) all pass" t3

# ---------------------------------------------------------------------------
# T4: VS Code image specifics
# ---------------------------------------------------------------------------
echo; echo "-- T4a nvcc: real SASS for sm_75 + sm_86 (A16) + this GPU"
t4a() {
    in_ctr "$C_GPU" <<'EOF'
fail=0
nvcc --version | tail -2
echo "CUDA_HOME=$CUDA_HOME -> $(readlink -f "$CUDA_HOME")"
cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 | tr -d '.[:space:]')
gencode=$(printf '%s\n' 75 86 "$cc" | sort -un | sed 's/.*/-gencode arch=compute_&,code=sm_&/' | tr '\n' ' ')
d=$(mktemp -d)
cat > "$d/axpy.cu" <<'CU'
#include <cstdio>
#include <cstdlib>
__global__ void axpy(float a, const float *x, float *y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = a * x[i] + y[i];
}
int main() {
    const int n = 1 << 20;
    size_t sz = n * sizeof(float);
    float *hx = (float *)malloc(sz), *hy = (float *)malloc(sz), *x, *y;
    for (int i = 0; i < n; i++) { hx[i] = (float)i; hy[i] = 1.0f; }
    int drv = 0, rt = 0;
    cudaDriverGetVersion(&drv); cudaRuntimeGetVersion(&rt);
    cudaError_t e = cudaMalloc(&x, sz);
    if (e == cudaSuccess) e = cudaMalloc(&y, sz);
    if (e == cudaSuccess) e = cudaMemcpy(x, hx, sz, cudaMemcpyHostToDevice);
    if (e == cudaSuccess) e = cudaMemcpy(y, hy, sz, cudaMemcpyHostToDevice);
    if (e == cudaSuccess) { axpy<<<(n + 255) / 256, 256>>>(2.0f, x, y, n); e = cudaGetLastError(); }
    if (e == cudaSuccess) e = cudaDeviceSynchronize();
    if (e == cudaSuccess) e = cudaMemcpy(hy, y, sz, cudaMemcpyDeviceToHost);
    if (e != cudaSuccess) { printf("driver API %d runtime %d: %s (%s)\n", drv, rt, cudaGetErrorName(e), cudaGetErrorString(e)); return 1; }
    printf("driver API %d runtime %d: y[12345]=%g (expected 24691)\n", drv, rt, hy[12345]);
    return hy[12345] == 24691.0f ? 0 : 1;
}
CU
echo "nvcc $gencode"
nvcc $gencode -o "$d/axpy" "$d/axpy.cu" || exit 1
elfs=$(cuobjdump --list-elf "$d/axpy")
echo "$elfs"
for a in 75 86 "$cc"; do echo "$elfs" | grep -q "sm_$a" || { echo "no sm_$a SASS"; fail=1; }; done
echo "session env (mesa-gpu-env.sh probe):"
( . /etc/profile.d/mesa-gpu-env.sh; echo "  MESA_CUDA_COMPAT=$MESA_CUDA_COMPAT"; "$d/axpy" ) || fail=1
echo "host driver only (no forward-compat):"
env -u LD_LIBRARY_PATH "$d/axpy" || fail=1
# Info only: PTX-only builds need a driver that can JIT CUDA 12.5 PTX (R555+)
# or the forward-compat driver that mesa-gpu-env.sh enables on older hosts.
nvcc -gencode "arch=compute_$cc,code=compute_$cc" -o "$d/ptx" "$d/axpy.cu" && {
    echo "info: PTX-only build, host driver only: $(env -u LD_LIBRARY_PATH "$d/ptx" 2>&1 | tail -1)"
    echo "info: PTX-only build, session env:      $( . /etc/profile.d/mesa-gpu-env.sh; "$d/ptx" 2>&1 | tail -1)"
}
rm -rf "$d"
exit $fail
EOF
}
check "T4a nvcc SASS kernel" "fatbin with sm_75+sm_86(+local) SASS runs with and without forward-compat" t4a

echo; echo "-- T4b VS Code extensions"
t4b() {
    in_ctr "$C_GPU" <<'EOF'
fail=0
list=$(/app/code-server/bin/code-server --list-extensions --show-versions)
echo "$list"
for e in nvidia.nsight-vscode-edition llvm-vs-code-extensions.vscode-clangd ms-vscode.cmake-tools continue.continue \
         ms-python.python ms-toolsai.jupyter saoudrizwan.claude-dev; do
    echo "$list" | grep -qi "^$e@" || { echo "missing extension: $e"; fail=1; }
done
for b in clangd cmake ninja; do command -v "$b" >/dev/null || { echo "missing $b (needed by the clangd / CMake Tools extensions)"; fail=1; }; done
# The landing screen and README point at both GPU monitors: they must be on the
# IDE's PATH (docker exec gets the same image PATH as pid 1), not only in the env.
for b in nvtop nvitop; do
    if p=$(command -v "$b"); then echo "$b: $p"; else echo "$b: not on PATH"; fail=1; fi
done
out=$(nvitop --once 2>&1); rc=$?
printf '%s\n' "$out" | head -8
[ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q 'Driver Version' || { echo "nvitop --once failed (rc=$rc)"; fail=1; }
exit $fail
EOF
}
check "T4b extensions" "Nsight, clangd, CMake Tools, Continue installed (+ Python, Jupyter, Cline); clangd/cmake/ninja and nvtop/nvitop on PATH; nvitop reads the GPU" t4b

echo; echo "-- T4c PyTorch env on the GPU"
t4c() {
    in_ctr "$C_GPU" <<'EOF'
. /etc/profile.d/mesa-gpu-env.sh
echo "MESA_TORCH_PYTHON=$MESA_TORCH_PYTHON MESA_CUDA_COMPAT=$MESA_CUDA_COMPAT"
"$MESA_TORCH_PYTHON" - <<'PY' || exit 1
import importlib, sys
import torch, torchvision
print(f"python {sys.version.split()[0]}  torch {torch.__version__}  torchvision {torchvision.__version__}  CUDA {torch.version.cuda}  cuDNN {torch.backends.cudnn.version()}")
assert "+cu" in torch.__version__, "not a CUDA build of torch"
assert torch.cuda.is_available(), "torch.cuda.is_available() is False"
print("device:", torch.cuda.get_device_name(0), "capability", torch.cuda.get_device_capability(0), "arch list", torch.cuda.get_arch_list())
x = torch.randn(2048, 2048, device="cuda", dtype=torch.float16)
assert torch.isfinite((x @ x).float().sum())
boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11], [50, 50, 60, 60]], dtype=torch.float32, device="cuda")
keep = torchvision.ops.nms(boxes, torch.tensor([0.9, 0.8, 0.7], device="cuda"), 0.5)
assert keep.tolist() == [0, 2], keep
mods = ("transformers accelerate datasets peft sentence_transformers safetensors bitsandbytes lightning timm "
        "torchmetrics cupy nvitop pynvml huggingface_hub ollama ipykernel").split()
vers = {m: getattr(importlib.import_module(m), "__version__", "?") for m in mods}
print("imports ok:", " ".join(f"{m}={v}" for m, v in vers.items()))
import cupy as cp
a = cp.arange(1_000_000, dtype=cp.float64)
assert float((a * 2).sum()) == 999999000000.0
print("cupy", cp.__version__, "elementwise + reduction on GPU ok (CUDA runtime", cp.cuda.runtime.runtimeGetVersion(), ")")
import bitsandbytes.functional as F
w = torch.randn(256, 256, device="cuda", dtype=torch.float16)
q, st = F.quantize_4bit(w)
err = (F.dequantize_4bit(q, st) - w).abs().mean().item()
assert err < 0.2, err
print(f"bitsandbytes 4-bit quantize/dequantize on GPU ok (mean abs err {err:.3f})")
import pynvml
pynvml.nvmlInit()
h = pynvml.nvmlDeviceGetHandleByIndex(0)
print("NVML ok:", pynvml.nvmlDeviceGetName(h), "driver", pynvml.nvmlSystemGetDriverVersion())
PY
echo "host driver only (LD_LIBRARY_PATH unset, no forward-compat):"
env -u LD_LIBRARY_PATH "$MESA_TORCH_PYTHON" -c 'import torch; assert torch.cuda.is_available(); print("  torch.cuda ok, sum", (torch.ones(1000, device="cuda") * 2).sum().item())'
EOF
}
check "T4c torch env" "torch +cu build sees the GPU (with and without compat); cupy, bitsandbytes, NVML, all ML packages import" t4c

echo; echo "-- T4d Jupyter kernel 'pytorch' (what ms-toolsai.jupyter launches)"
t4d() {
    in_ctr "$C_GPU" <<'EOF'
. /etc/profile.d/mesa-gpu-env.sh
"$MESA_TORCH_PYTHON" - <<'PY'
from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import start_new_kernel
spec = KernelSpecManager().get_kernel_spec("pytorch")
print(f"kernelspec 'pytorch': {spec.display_name!r} argv[0]={spec.argv[0]} dir={spec.resource_dir}")
assert spec.argv[0] == "/opt/conda/envs/pytorch/bin/python"
km, kc = start_new_kernel(kernel_name="pytorch", startup_timeout=120)
out = []
try:
    kc.execute_interactive("import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0), torch.__version__)",
                           output_hook=out.append, timeout=180)
finally:
    kc.stop_channels(); km.shutdown_kernel(now=True)
text = "".join(m["content"].get("text", "") for m in out if m["msg_type"] == "stream").strip()
print("kernel output:", text)
assert text.startswith("True"), text
PY
EOF
}
check "T4d Jupyter kernel" "kernelspec 'pytorch' starts and sees CUDA" t4d

echo; echo "-- T4e user config: settings.json, Continue, agent configs, ownership, IDE env"
t4e() {
    in_ctr "$C_GPU" <<'EOF'
fail=0
"$MESA_TORCH_PYTHON" - <<'PY' || fail=1
import json, tomllib, yaml
s = json.load(open("/config/.local/share/code-server/User/settings.json"))
assert s["python.defaultInterpreterPath"] == "/opt/conda/envs/pytorch/bin/python", s
assert s["continue.telemetryEnabled"] is False, s
print("settings.json python.defaultInterpreterPath =", s["python.defaultInterpreterPath"])
c = yaml.safe_load(open("/config/.continue/config.yaml"))
assert c["schema"] == "v1" and c["name"] and c["version"], c
m = c["models"][0]
assert (m["provider"], m["model"], m["apiBase"]) == ("ollama", "qwen3.5:9b", "http://127.0.0.1:11434"), m
print("continue config.yaml:", [(x["name"], x["provider"], x["model"], x.get("apiBase")) for x in c["models"]])
oc = json.load(open("/config/.config/opencode/opencode.json"))
assert oc["provider"]["ollama"]["options"]["baseURL"] == "http://127.0.0.1:11434/v1"
assert "aiverde" in oc["provider"] and oc["model"].startswith("aiverde/"), "CPU image defaults must be kept"
print("opencode providers:", list(oc["provider"]), "models:", list(oc["provider"]["ollama"]["models"]))
cx = tomllib.load(open("/config/.codex/config.toml", "rb"))
assert cx["oss_provider"] == "ollama" and "irods" in cx["mcp_servers"], cx
print("codex oss_provider =", cx["oss_provider"], "mcp_servers:", list(cx["mcp_servers"]))
PY
curl -fsS -m 5 http://127.0.0.1:11434/api/version && echo " <- Ollama API at Continue's apiBase" || { echo "Ollama not answering on 127.0.0.1:11434"; fail=1; }
for p in /config/.continue /config/.continue/config.yaml /config/.local/share/code-server/User/settings.json \
         /config/.config/clangd /config/.config/clangd/config.yaml \
         /config/.local/share/jupyter/kernels/pytorch /opt/conda/envs/pytorch /opt/conda/envs/pytorch/lib/python3.13/site-packages/torch \
         /config/.config/opencode/opencode.json /config/.codex/config.toml /config/.local/share/code-server/extensions; do
    o=$(stat -c %u "$p" 2>/dev/null)
    [ "$o" = 1000 ] || { echo "$p owned by uid '${o:-missing}', expected 1000"; fail=1; }
done
echo "ownership: config/env paths owned by uid 1000"
# The IDE and Ollama must inherit the entrypoint's CUDA environment.
api=$(cuda-probe --api 2>/dev/null)
want=0
[ -n "$api" ] && [ "$api" -lt 13 ] && LD_LIBRARY_PATH="$MESA_CUDA_COMPAT_DIR" cuda-probe >/dev/null 2>&1 && want=1
echo "host CUDA driver API $api -> forward-compat expected: $want"
for pid in 1 $(pgrep -u 1000 -f 'ollama.bin serve' | head -1); do
    envs=$(tr '\0' '\n' < "/proc/$pid/environ")
    ldp=$(printf '%s\n' "$envs" | sed -n 's/^LD_LIBRARY_PATH=//p')
    echo "pid $pid ($(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-60)): LD_LIBRARY_PATH=${ldp:-<unset>}"
    case ":$ldp:" in *":$MESA_CUDA_COMPAT_DIR:"*) got=1 ;; *) got=0 ;; esac
    [ "$got" = "$want" ] || { echo "  forward-compat state $got, expected $want"; fail=1; }
done
exit $fail
EOF
}
check "T4e config + env" "settings.json, Continue (Ollama qwen3.5:9b), OpenCode/Codex ollama wiring, uid 1000 ownership, IDE/Ollama env" t4e

echo; echo "-- T4f clangd understands CUDA sources (IntelliSense backend of the clangd extension)"
t4f() {
    in_ctr "$C_GPU" <<'EOF'
fail=0
d=$(mktemp -d); cd "$d" || exit 1
printf '#pragma once\n__device__ inline float one() { return 1.0f; }\n' > k.cuh
printf '#include <cstdio>\n#include "k.cuh"\n__global__ void k(float *y) { y[threadIdx.x] = one(); }\nint main() { float *y; cudaMalloc(&y, 4); k<<<1, 1>>>(y); return cudaDeviceSynchronize(); }\n' > k.cu
printf '__global__ void k(float *y) { y[threadIdx.x] = undefined_thing; }\n' > bad.cu
for f in k.cu k.cuh; do
    out=$(clangd --check="$f" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -E '^E\[|All checks' | cut -c1-200 | sed "s|^|$f: |"
    [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q 'All checks completed, 0 errors' || fail=1
done
# negative control: a real error must still be reported
out=$(clangd --check=bad.cu 2>&1)
printf '%s\n' "$out" | grep -q "undeclared identifier 'undefined_thing'" && echo "bad.cu: undeclared identifier reported (negative control ok)" || fail=1
cd / && rm -rf "$d"
exit $fail
EOF
}
check "T4f clangd CUDA" "clangd parses .cu/.cuh with 0 errors (config: sm_86) and still reports real errors" t4f

echo; echo "-- T4g apt pin: a session's 'sudo apt install' cannot re-bake the driver userspace"
t4g() {
    in_ctr "$C_GPU" <<'EOF'
fail=0
cat /etc/apt/preferences.d/mesa-no-nvidia-driver || exit 1
sudo -n timeout 300 apt-get update -qq >/dev/null 2>&1 || { echo "sudo apt-get update failed"; exit 1; }
# apt-get update exits 0 even when every fetch fails: look for package lists
compgen -G "/var/lib/apt/lists/*_Packages*" >/dev/null || { echo "SKIP T4g: apt-get update fetched no package lists (no network?)"; exit 0; }
nopin=(-o Dir::Etc::PreferencesParts=/nonexistent)
for p in cuda-drivers cuda-12-6; do
    # control: without the pin apt would install driver packages for $p
    n=$(apt-get "${nopin[@]}" install -s -y "$p" 2>/dev/null | grep -cE '^Inst (nvidia-|libnvidia-|cuda-drivers)')
    if apt-get install -s -y "$p" >/dev/null 2>&1; then
        echo "$p is installable despite the pin"; fail=1
    else
        echo "$p: blocked by the pin (unpinned it would install $n driver packages)"
    fi
    [ "$n" -gt 0 ] || { echo "  control failed: $p pulls no driver packages even without the pin"; fail=1; }
done
out=$(apt-get install -s -y cuda-toolkit-12-6 2>&1) || { echo "cuda-toolkit-12-6 is no longer installable"; fail=1; }
drv=$(printf '%s\n' "$out" | grep -E '^Inst (nvidia-|libnvidia-|cuda-drivers)')
[ -z "$drv" ] || { echo "cuda-toolkit-12-6 pulls driver packages: $drv"; fail=1; }
echo "cuda-toolkit-12-6: still installable ($(printf '%s\n' "$out" | grep -c '^Inst') packages, no driver packages)"
sudo -n rm -rf /var/lib/apt/lists/*
exit $fail
EOF
}
check "T4g apt driver pin" "cuda-drivers / cuda-12-6 blocked (they pull driver packages without the pin); cuda-toolkit-12-6 still installable" t4g

echo; echo "-- T4h apt pin file + apt-cache policy (throwaway root container)"
t4h() {
    local want
    want=$(sha256sum < "$PIN_SRC" | cut -d' ' -f1) || return 1
    echo "shared pin $PIN_SRC: sha256 $want"
    docker run --rm -i --name "$C_APT" --user 0 --entrypoint bash -e WANT="$want" "$IMAGE" -s <<'EOF'
fail=0
f=/etc/apt/preferences.d/mesa-no-nvidia-driver
st=$(stat -c '%a %U:%G' "$f") || exit 1
sum=$(sha256sum < "$f" | cut -d' ' -f1)
echo "$f: $st sha256 $sum"
[ "$st" = "644 root:root" ] || { echo "  expected mode 644 root:root"; fail=1; }
[ "$sum" = "$WANT" ] || { echo "  differs from gpu/common/apt-no-nvidia-driver.pref"; fail=1; }
# apt-get update exits 0 even when every fetch fails: "no network" = no package lists
timeout 300 apt-get update -qq >/dev/null 2>&1
if ! compgen -G "/var/lib/apt/lists/*_Packages*" >/dev/null; then
    echo "SKIP apt-cache policy: apt-get update fetched no package lists (no network?)"
    exit $fail
fi
pol=$(apt-cache policy nvidia-driver-580)
printf '%s\n' "$pol" | head -4
cand=$(printf '%s\n' "$pol" | sed -n 's/^ *Candidate: //p')
[ "$cand" = '(none)' ] || { echo "  nvidia-driver-580: Candidate: ${cand:-<not in the package lists>}, expected (none)"; fail=1; }
# control: without the pin apt has a candidate, so "(none)" is the pin's doing
nopin=$(mktemp -d)
ctl=$(apt-cache -o Dir::Etc::PreferencesParts="$nopin" policy nvidia-driver-580 | sed -n 's/^ *Candidate: //p')
echo "without the pin: Candidate: ${ctl:-<no package>}"
case "$ctl" in ''|'(none)') echo "  control failed: nvidia-driver-580 has no candidate even without the pin"; fail=1 ;; esac
exit $fail
EOF
}
check "T4h apt pin file" "pin file is the shared one, mode 644 root; apt-cache policy nvidia-driver-580: Candidate (none) (has one without the pin)" t4h

echo; echo "-- T4i docker exec 'bash -i' (non-login interactive): forward-compat env and nvitop"
t4i() {
    local ide out line compat ldp nv rc fail=0
    ide=$(docker exec "$C_GPU" sh -c "tr '\\0' '\\n' < /proc/1/environ" | sed -n 's/^MESA_CUDA_COMPAT=//p')
    echo "IDE env (pid 1, from the entrypoint): MESA_CUDA_COMPAT=${ide:-<unset>}"
    [ -n "$ide" ] || { echo "MESA_CUDA_COMPAT missing from the IDE environment"; return 1; }
    # docker exec starts from the image env (no entrypoint), like kubectl exec
    out=$(timeout 120 docker exec -u 1000 "$C_GPU" bash -i -c \
        'echo "@@ compat=${MESA_CUDA_COMPAT:-unset} ldp=${LD_LIBRARY_PATH:-} nvitop=$(command -v nvitop)"' 2>&1); rc=$?
    line=$(printf '%s\n' "$out" | grep '^@@ ' | tail -1)
    echo "bash -i (rc $rc): ${line:-<no output>}"
    [ $rc -eq 0 ] && [ -n "$line" ] || { printf '%s\n' "$out" | tail -5; return 1; }
    compat=$(printf '%s\n' "$line" | sed -n 's/.* compat=\([^ ]*\) .*/\1/p')
    ldp=$(printf '%s\n' "$line" | sed -n 's/.* ldp=\([^ ]*\) .*/\1/p')
    nv=$(printf '%s\n' "$line" | sed -n 's/.* nvitop=\(.*\)$/\1/p')
    [ "$compat" = "$ide" ] || { echo "  exec shell MESA_CUDA_COMPAT=$compat, IDE has $ide"; fail=1; }
    if [ "$compat" = 1 ]; then
        case ":$ldp:" in *:/usr/local/cuda-*/compat:*) ;; *) echo "  compat=1 but LD_LIBRARY_PATH has no compat dir"; fail=1 ;; esac
    fi
    [ -n "$nv" ] || { echo "  nvitop not on PATH in an interactive shell"; fail=1; }
    # scripts that run with set -e and source the rc files must be unaffected
    out=$(docker exec -u 1000 "$C_GPU" bash -e -c '. ~/.bashrc; echo "@@ ~/.bashrc under set -e ok"' 2>&1) \
        && printf '%s\n' "$out" | grep '^@@ ' || { echo "  set -e script sourcing ~/.bashrc failed: $(printf '%s\n' "$out" | tail -2)"; fail=1; }
    # PS1 set in the script (bash drops an inherited one when non-interactive) so
    # /etc/bash.bashrc runs through to the MESA line instead of returning early
    out=$(docker exec -u 1000 "$C_GPU" bash -e -c 'PS1="\$ "; . /etc/bash.bashrc; echo "@@ /etc/bash.bashrc under set -e ok compat=${MESA_CUDA_COMPAT:-unset}"' 2>&1)
    line=$(printf '%s\n' "$out" | grep '^@@ ')
    echo "${line:-  set -e script sourcing /etc/bash.bashrc failed: $(printf '%s\n' "$out" | tail -2)}"
    [ "$line" = "@@ /etc/bash.bashrc under set -e ok compat=$ide" ] || { echo "  expected compat=$ide"; fail=1; }
    return $fail
}
check "T4i exec shell env" "docker exec bash -i gets the IDE's MESA_CUDA_COMPAT (+ compat LD_LIBRARY_PATH) and nvitop on PATH; set -e scripts sourcing bashrc unaffected" t4i

# ---------------------------------------------------------------------------
# T5: no GPU — the IDE must still start; mesa-gpu-check reports it cleanly
# ---------------------------------------------------------------------------
echo; echo "-- T5 start WITHOUT a GPU"
docker run -d --name "$C_NOGPU" --user 1000 -e IPLANT_USER=mesa-test -p "127.0.0.1::$PORT" "$IMAGE" >/dev/null
t5() {
    wait_http "$C_NOGPU" || return 1
    local out rc env1
    out=$(timeout 600 docker exec -u 1000 "$C_NOGPU" mesa-gpu-check 2>&1); rc=$?
    printf '%s\n' "$out"
    echo "mesa-gpu-check exit status: $rc"
    [ $rc -ne 0 ] && [ $rc -lt 126 ] || { echo "expected a clean non-zero exit (missing GPU), got $rc"; return 1; }
    grep -q 'no NVIDIA GPU in this container' <<<"$out" || { echo "missing 'no NVIDIA GPU' report"; return 1; }
    # no `cmd | grep -q` under pipefail: an early grep exit could fail the pipe
    env1=$(docker exec -u 1000 "$C_NOGPU" sh -c "tr '\0' '\n' < /proc/1/environ") || { echo "cannot read the IDE environment"; return 1; }
    if grep -q '^LD_LIBRARY_PATH=.*compat' <<<"$env1"; then
        echo "forward-compat enabled without a GPU"; return 1
    fi
}
check "T5 no GPU" "code-server starts; mesa-gpu-check reports the missing GPU (non-zero, no crash); compat stays off" t5

# ---------------------------------------------------------------------------
echo
echo "== Summary: $IMAGE (GPU=$GPU)"
nfail=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r st name detail <<<"$r"
    printf '  %-4s  %-22s %s\n' "$st" "$name" "$detail"
    [ "$st" = PASS ] || nfail=$((nfail + 1))
done
echo "  logs: $LOG_DIR"
if [ $nfail -eq 0 ]; then echo "ALL ${#RESULTS[@]} TESTS PASSED"; else echo "$nfail of ${#RESULTS[@]} TESTS FAILED"; fi
[ $nfail -eq 0 ]
