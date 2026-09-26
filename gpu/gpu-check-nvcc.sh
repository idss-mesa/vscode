# shellcheck shell=bash disable=SC2154  # hdr/ok/bad/info and $have_gpu come from mesa-gpu-check
# /etc/mesa/gpu-check.d/50-nvcc.sh — mesa-vscode: CUDA toolkit section of
# mesa-gpu-check (sourced; uses its hdr/ok/bad/info helpers and $have_gpu).
# Builds a tiny kernel for the GPU in this container (nvcc -arch=native = real
# SASS, which runs on the host driver even without CUDA forward-compat) and
# checks that /usr/local/cuda is the 12.x toolkit, not the compat package.
hdr "CUDA toolkit (nvcc)"
if ! command -v nvcc >/dev/null 2>&1; then
    bad "nvcc not on PATH (expected /usr/local/cuda/bin)"
else
    _mesa_cuda=$(readlink -f "${CUDA_HOME:-/usr/local/cuda}")
    info "nvcc $(nvcc --version | sed -n 's/.*release \([0-9.]*\),.*/\1/p') in $_mesa_cuda"
    case "$_mesa_cuda" in
        */cuda-12.*) ;;
        *) bad "CUDA_HOME resolves to $_mesa_cuda, expected the CUDA 12 toolkit" ;;
    esac
    if [ "$have_gpu" = 1 ]; then
        _mesa_tmp=$(mktemp -d)
        cat > "$_mesa_tmp/axpy.cu" <<'EOF'
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
    cudaDeviceProp p;
    cudaError_t e = cudaGetDeviceProperties(&p, 0);
    if (e == cudaSuccess) e = cudaMalloc(&x, sz);
    if (e == cudaSuccess) e = cudaMalloc(&y, sz);
    if (e == cudaSuccess) e = cudaMemcpy(x, hx, sz, cudaMemcpyHostToDevice);
    if (e == cudaSuccess) e = cudaMemcpy(y, hy, sz, cudaMemcpyHostToDevice);
    if (e == cudaSuccess) { axpy<<<(n + 255) / 256, 256>>>(2.0f, x, y, n); e = cudaGetLastError(); }
    if (e == cudaSuccess) e = cudaDeviceSynchronize();
    if (e == cudaSuccess) e = cudaMemcpy(hy, y, sz, cudaMemcpyDeviceToHost);
    if (e != cudaSuccess) { printf("%s: %s\n", cudaGetErrorName(e), cudaGetErrorString(e)); return 1; }
    if (hy[12345] != 24691.0f) { printf("wrong result y[12345]=%g (expected 24691)\n", hy[12345]); return 1; }
    printf("axpy kernel correct on %s (sm_%d%d)\n", p.name, p.major, p.minor);
    return 0;
}
EOF
        if _mesa_out=$(cd "$_mesa_tmp" && nvcc -arch=native -o axpy axpy.cu 2>&1 && ./axpy 2>&1); then
            ok "nvcc -arch=native: $(printf '%s' "$_mesa_out" | tail -1)"
        else
            bad "nvcc kernel build/run failed: $(printf '%s' "$_mesa_out" | tail -1)"
        fi
        rm -rf "$_mesa_tmp"
    fi
    unset _mesa_cuda _mesa_tmp _mesa_out
fi
