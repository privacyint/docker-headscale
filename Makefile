SHELL := /bin/bash

DEFAULT_SMOKE_TEST_IMAGE := headscale:latest
DEFAULT_SMOKE_TEST_CONTAINER := headscale-container
DEFAULT_SMOKE_TEST_HOST := 127.0.0.1
DEFAULT_SMOKE_TEST_PORT := 8008
DEFAULT_HADOLINT_IMAGE := hadolint/hadolint:v2.12.0-alpine
DEFAULT_SHELLCHECK_IMAGE := koalaman/shellcheck:v0.10.0

.DEFAULT_GOAL := help

.PHONY: help check-curl check-docker check-envsubst build lint-docker lint-shell render-fly-config render-azure-container-apps render-headscale-config check-config-drift check clean smoke-test

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make build                       Build the Docker image locally' \
	  '  make lint-docker                 Lint Dockerfile with hadolint' \
	  '  make lint-shell                  Lint shell scripts with shellcheck' \
	  '  make render-fly-config           Render fly.toml from templates/fly.template.toml' \
	  '  make render-azure-container-apps Render azure-container-apps.yaml from templates/azure-container-apps.template.yaml' \
	  '  make render-headscale-config     Render generated-config.yaml from templates/headscale.template.yaml' \
	  '  make check-config-drift          Compare rendered config against upstream Headscale config' \
	  '  make check                       Run the local validation suite' \
	  '  make clean                       Remove generated local artefacts' \
	  '  make smoke-test                  Build the image and run local smoke tests'

check-curl:
	@command -v curl >/dev/null || { \
		echo 'curl is required for upstream config checks.'; \
		exit 1; \
	}

check-docker:
	@command -v docker >/dev/null || { \
		echo 'docker is required for image builds and containerised linters.'; \
		exit 1; \
	}

check-envsubst:
	@command -v envsubst >/dev/null || { \
		echo 'envsubst is required to render deployment templates. Install gettext first.'; \
		exit 1; \
	}

build: check-docker
	@set -euo pipefail; \
	image="$${SMOKE_TEST_IMAGE:-$(DEFAULT_SMOKE_TEST_IMAGE)}"; \
	echo "Building Docker image: $${image}"; \
	docker build -t "$${image}" .

lint-docker: check-docker
	@set -euo pipefail; \
	image="$${HADOLINT_IMAGE:-$(DEFAULT_HADOLINT_IMAGE)}"; \
	format="$${HADOLINT_FORMAT:-tty}"; \
	output_file="$${HADOLINT_OUTPUT_FILE:-}"; \
	echo "Running hadolint using $${image}"; \
	if [[ -n "$${output_file}" ]]; then \
		docker run --rm -i -v "$${PWD}:/workdir" -w /workdir --entrypoint hadolint "$${image}" \
			--format "$${format}" Dockerfile > "$${output_file}"; \
		printf '%s\n' "Wrote $${output_file}"; \
	else \
		docker run --rm -i -v "$${PWD}:/workdir" -w /workdir --entrypoint hadolint "$${image}" \
			--format "$${format}" Dockerfile; \
	fi

lint-shell: check-docker
	@set -euo pipefail; \
	image="$${SHELLCHECK_IMAGE:-$(DEFAULT_SHELLCHECK_IMAGE)}"; \
	set -- scripts/*.sh; \
	if [[ "$${1}" == 'scripts/*.sh' ]]; then \
		echo 'No shell scripts found under scripts/'; \
		exit 0; \
	fi; \
	echo "Running shellcheck using $${image}"; \
	docker run --rm -i -v "$${PWD}:/workdir" -w /workdir --entrypoint shellcheck "$${image}" \
		--shell=bash "$${@}"

render-fly-config: check-envsubst
	@: $${FLY_APP:?Set FLY_APP}
	@: $${PUBLIC_SERVER_URL:?Set PUBLIC_SERVER_URL}
	@: $${HEADSCALE_DNS_BASE_DOMAIN:?Set HEADSCALE_DNS_BASE_DOMAIN}
	@envsubst < templates/fly.template.toml > fly.toml
	@printf '%s\n' 'Wrote fly.toml'

render-azure-container-apps: check-envsubst
	@: $${LOCATION:?Set LOCATION}
	@: $${CONTAINER_APP_NAME:?Set CONTAINER_APP_NAME}
	@: $${CONTAINER_APP_ENVIRONMENT_ID:?Set CONTAINER_APP_ENVIRONMENT_ID}
	@: $${CONTAINER_IMAGE:?Set CONTAINER_IMAGE}
	@: $${STORAGE_MOUNT_NAME:?Set STORAGE_MOUNT_NAME}
	@: $${PUBLIC_SERVER_URL:?Set PUBLIC_SERVER_URL}
	@: $${HEADSCALE_DNS_BASE_DOMAIN:?Set HEADSCALE_DNS_BASE_DOMAIN}
	@envsubst < templates/azure-container-apps.template.yaml > azure-container-apps.yaml
	@printf '%s\n' 'Wrote azure-container-apps.yaml'

render-headscale-config: check-envsubst
	@set -euo pipefail; \
	source scripts/defaults.sh; \
	source scripts/ci-defaults.sh; \
	envsubst < templates/headscale.template.yaml > generated-config.yaml; \
	printf '%s\n' 'Wrote generated-config.yaml'

check-config-drift: check-curl render-headscale-config
	@set -euo pipefail; \
	version="$$(awk -F'"' '/^ARG HEADSCALE_VERSION=/{ print $$2; exit }' Dockerfile)"; \
	cleanup() { \
		rm -f ignored_keys.txt local_all_keys.txt upstream_all_keys.txt upstream_all_keys_norm.txt local_all_keys_norm.txt upstream_filtered_keys.txt temp_filtered.txt; \
	}; \
	trap cleanup EXIT; \
	echo "Downloading upstream Headscale config for v$${version}"; \
	curl --fail --silent --show-error -o upstream-config.yaml \
		"https://raw.githubusercontent.com/juanfont/headscale/refs/tags/v$${version}/config-example.yaml"; \
	extract_keys() { \
		grep -E '^[[:space:]]*[^#\-].*:' "$$1" | \
			sed 's/:[[:space:]]*.*$$//' | \
			sed 's/^[[:space:]]*//' | \
			sort -u; \
	}; \
	get_ignored_keys() { \
		awk '/# DIFF_IGNORE/ { gsub(/^[[:space:]]*#?[[:space:]]*/, ""); sub(/:.*# DIFF_IGNORE.*/, ""); print }' \
			templates/headscale.template.yaml | \
			sort -u; \
	}; \

	get_ignored_keys > ignored_keys.txt; \
	extract_keys generated-config.yaml > local_all_keys.txt; \
	extract_keys upstream-config.yaml > upstream_all_keys.txt; \
	sed -E 's/^[[:space:]]*#?[[:space:]]*//' upstream_all_keys.txt | sed 's/[[:space:]]*$$//' | sort -u > upstream_all_keys_norm.txt; \
	sed -E 's/^[[:space:]]*#?[[:space:]]*//' local_all_keys.txt | sed 's/[[:space:]]*$$//' | sort -u > local_all_keys_norm.txt; \
	cp upstream_all_keys_norm.txt upstream_filtered_keys.txt; \
	while IFS= read -r ignore_key; do \
		if [[ -n "$${ignore_key}" ]]; then \
			grep -v "^$${ignore_key}$$" upstream_filtered_keys.txt > temp_filtered.txt || true; \
			mv temp_filtered.txt upstream_filtered_keys.txt; \
		fi; \
	done < ignored_keys.txt; \
	sort -u upstream_filtered_keys.txt -o upstream_filtered_keys.txt; \
	comm -23 upstream_filtered_keys.txt local_all_keys_norm.txt > new-options.txt; \
	echo "Local keys: $$(wc -l < local_all_keys_norm.txt)"; \
	echo "Upstream filtered keys: $$(wc -l < upstream_filtered_keys.txt)"; \
	if [[ -s new-options.txt ]]; then \
		echo 'New configuration keys found:'; \
		cat new-options.txt; \
		exit 1; \
	fi; \
	rm -f new-options.txt; \
	echo 'No new configuration keys found'

check: lint-docker lint-shell check-config-drift

clean:
	@rm -f generated-config.yaml upstream-config.yaml new-options.txt azure-container-apps.yaml fly.toml hadolint-results.sarif

smoke-test: build
	@set -euo pipefail; \
	image="$${SMOKE_TEST_IMAGE:-$(DEFAULT_SMOKE_TEST_IMAGE)}"; \
	container="$${SMOKE_TEST_CONTAINER:-$(DEFAULT_SMOKE_TEST_CONTAINER)}"; \
	host="$${SMOKE_TEST_HOST:-$(DEFAULT_SMOKE_TEST_HOST)}"; \
	port="$${SMOKE_TEST_PORT:-$(DEFAULT_SMOKE_TEST_PORT)}"; \
	admin_gui_html="$$(mktemp)"; \
	redirect_headers="$$(mktemp)"; \
	cleanup() { \
		rm -f "$${admin_gui_html}" "$${redirect_headers}"; \
		docker stop "$${container}" >/dev/null 2>&1 || true; \
		docker rm "$${container}" >/dev/null 2>&1 || true; \
	}; \
	trap cleanup EXIT; \
	docker rm -f "$${container}" >/dev/null 2>&1 || true; \
	echo "Starting container: $${container}"; \
	docker run -d --name "$${container}" \
		-p "$${host}:$${port}:8008" \
		--env LITESTREAM_REPLICA_URL="$${SMOKE_TEST_LITESTREAM_REPLICA_URL:-DISABLED_I_KNOW_WHAT_IM_DOING}" \
		--env PUBLIC_SERVER_URL="$${PUBLIC_SERVER_URL:-https://headscale.example.com}" \
		--env HEADSCALE_DNS_BASE_DOMAIN="$${HEADSCALE_DNS_BASE_DOMAIN:-example.com}" \
		--env CADDY_FRONTEND="$${CADDY_FRONTEND:-DISABLE_HTTPS}" \
		"$${image}" >/dev/null; \
	echo 'Running version checks'; \
	docker exec "$${container}" headscale version; \
	docker exec "$${container}" litestream version; \
	docker exec "$${container}" caddy version; \
	echo "Checking listener on port 8008 inside the container"; \
	docker exec "$${container}" sh -c "netstat -tuln | grep ':8008 '"; \
	echo "Waiting for admin GUI on http://$${host}:$${port}/admin/"; \
	for attempt in $$(seq 1 30); do \
		if curl --silent --show-error --fail "http://$${host}:$${port}/admin/" > "$${admin_gui_html}"; then \
			break; \
		fi; \
		sleep 2; \
		if [[ "$${attempt}" -eq 30 ]]; then \
			echo 'Admin GUI did not become ready in time'; \
			docker logs "$${container}"; \
			exit 1; \
		fi; \
	done; \
	echo 'Checking admin redirect and content'; \
	curl --silent --show-error --fail \
		--dump-header "$${redirect_headers}" \
		--output /dev/null \
		"http://$${host}:$${port}/admin"; \
	tr -d '\r' < "$${redirect_headers}" | grep -qi '^location: /admin/$$'; \
	grep -qi '<!doctype html>' "$${admin_gui_html}"; \
	grep -qi 'data-sveltekit-preload-data="hover"' "$${admin_gui_html}"; \
	grep -qi 'assets: "/admin"' "$${admin_gui_html}"; \
	echo 'Smoke test passed'
