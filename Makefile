# See `make help`. All real work lives in scripts/.
SHELL := /usr/bin/env bash
export PATH := $(CURDIR)/.bin:$(PATH)

.DEFAULT_GOAL := help

.PHONY: help tools build lock matrix lint clean

help: ## Show this help
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

tools: ## Download pinned apko and yq into ./.bin (sha256 verified)
	scripts/tools.sh $(if $(LINT),lint)

build: ## make build IMAGE=go STREAM=1.27 [VARIANT=dev] [PUSH=1] (no STREAM for static)
	@test -n "$(IMAGE)" || { echo "usage: make build IMAGE=go STREAM=1.27 [VARIANT=dev] [PUSH=1]  (STREAM is empty for unversioned images: make build IMAGE=static)" >&2; exit 2; }
	PUSH=$(or $(PUSH),0) scripts/build.sh "$(IMAGE)" "$(STREAM)" $(VARIANT)

lock: ## Render and lock only; prints the resolved version (no STREAM for static)
	@test -n "$(IMAGE)" || { echo "usage: make lock IMAGE=go STREAM=1.27 [VARIANT=dev]  (STREAM is empty for unversioned images)" >&2; exit 2; }
	LOCK_ONLY=1 scripts/build.sh "$(IMAGE)" "$(STREAM)" $(VARIANT)

matrix: ## Print the build matrix JSON (filters: IMAGE=, STREAM=)
	@scripts/matrix.sh

lint: ## shellcheck and actionlint, when installed (make tools LINT=1 installs them)
	@if command -v shellcheck >/dev/null; then shellcheck -x -P SCRIPTDIR scripts/*.sh images/*/test.sh && echo "shellcheck ok"; else echo "shellcheck not found, skipping"; fi
	@if command -v actionlint >/dev/null; then actionlint && echo "actionlint ok"; else echo "actionlint not found, skipping"; fi

clean: ## Remove ./out
	rm -rf out
