platform = linux/amd64
repo = harbor.cyverse.org/vice/mesa-vscode
tag = latest
context = latest
repotag = $(repo):$(tag)

.PHONY: build push run rmi pull-base build-gpu test-gpu push-gpu run-gpu

build:
	docker buildx build --rm --platform "$(platform)" -t "$(repotag)" --load "$(context)/"

push:
	docker push "$(repotag)"

run:
	docker run --rm -p 8080:8080 -e IPLANT_USER=$$USER "$(repotag)"

rmi:
	docker rmi "$(repotag)"

# ---- NVIDIA GPU variant (gpu/) — layers on the CPU image above ----
# Build/test/push from a host with an NVIDIA GPU + nvidia-container-toolkit
# (e.g. the A100 build server):  make pull-base build-gpu test-gpu push-gpu
gpu_repotag = $(repo):gpu
base_image = $(repo):latest

pull-base:        ## fetch the published CPU image the GPU layer builds FROM
	docker pull "$(base_image)"

build-gpu:        ## BASE_IMAGE defaults to the CPU image (run `make build` first to layer on a local CPU build)
	docker buildx build --rm --platform "$(platform)" --build-arg BASE_IMAGE="$(base_image)" -t "$(gpu_repotag)" --load gpu/
	@docker image inspect -f 'built on $(base_image): {{.Id}} {{.RepoDigests}}' "$(base_image)" 2>/dev/null || true

test-gpu:         ## GPU smoke test (needs an NVIDIA GPU + nvidia-container-toolkit); GPU=<index|all> picks the device
	gpu/test-gpu.sh "$(gpu_repotag)"

push-gpu:
	docker push "$(gpu_repotag)"

run-gpu:          ## loopback only: code-server has no password outside VICE (VICE's cas-proxy does auth); remote: ssh -L 8080:127.0.0.1:8080 <gpu-host>
	docker run --rm --gpus all -p 127.0.0.1:8080:8080 -e IPLANT_USER=$$USER "$(gpu_repotag)"
