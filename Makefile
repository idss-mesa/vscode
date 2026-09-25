platform = linux/amd64
repo = harbor.cyverse.org/vice/mesa-vscode
tag = latest
context = latest
repotag = $(repo):$(tag)

build:
	docker buildx build --rm --platform "$(platform)" -t "$(repotag)" --load "$(context)/"

push:
	docker push "$(repotag)"

run:
	docker run --rm -p 8080:8080 -e IPLANT_USER=$$USER "$(repotag)"

rmi:
	docker rmi "$(repotag)"
