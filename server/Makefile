.PHONY: help build start dev test clean docker

SHELL := /bin/bash

VERSION ?= latest
IMG_NAME ?= fuming/glance

BACKEND_OUT ?= bin/server

help:
	@echo "Targets:"
	@echo "  build     Build Go server -> $(BACKEND_OUT)"
	@echo "  start     Build then run server (http://127.0.0.1:1423/api/menu)"
	@echo "  dev       Run server with go run"
	@echo "  test      Run Go tests"
	@echo "  clean     Remove build artifacts"
	@echo "  docker    Build image $(IMG_NAME):$(VERSION)"

build:
	@set -euo pipefail; \
	mkdir -p "$$(dirname "$(BACKEND_OUT)")"; \
	go build -o "$(BACKEND_OUT)" .

start: build
	@set -euo pipefail; \
	if [ -f .env ]; then set -a && . ./.env && set +a; fi; \
	./"$(BACKEND_OUT)"

dev:
	@set -euo pipefail; \
	if [ -f .env ]; then set -a && . ./.env && set +a; fi; \
	go run .

test:
	go test ./...

clean:
	@rm -rf "$(BACKEND_OUT)"

docker:
	docker build -t $(IMG_NAME):$(VERSION) -t $(IMG_NAME):latest -f Dockerfile .
