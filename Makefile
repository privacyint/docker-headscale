SHELL := /bin/bash

DEFAULT_SMOKE_TEST_IMAGE := headscale:latest
DEFAULT_SMOKE_TEST_CONTAINER := headscale-container
DEFAULT_SMOKE_TEST_HOST := 127.0.0.1
DEFAULT_SMOKE_TEST_PORT := 8008

.DEFAULT_GOAL := help

.PHONY: help check-envsubst render-fly-config render-azure-container-apps smoke-test

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make render-fly-config           Render fly.toml from templates/fly.template.toml' \
	  '  make render-azure-container-apps Render azure-container-apps.yaml from templates/azure-container-apps.template.yaml' \
	  '  make smoke-test                  Build the image and run local smoke tests'

check-envsubst:
	@command -v envsubst >/dev/null || { \
		echo 'envsubst is required to render deployment templates. Install gettext first.'; \
		exit 1; \
	}

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

smoke-test:
	@set -euo pipefail; \
	image="$${SMOKE_TEST_IMAGE:-$(DEFAULT_SMOKE_TEST_IMAGE)}"; \
	container="$${SMOKE_TEST_CONTAINER_NAME:-$(DEFAULT_SMOKE_TEST_CONTAINER)}"; \
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
	echo "Building Docker image: $${image}"; \
	docker build -t "$${image}" .; \
	echo "Starting container: $${container}"; \
	docker run -d --name "$${container}" \
		-p "$${host}:$${port}:8008" \
		--env LITESTREAM_REPLICA_URL="$${LITESTREAM_REPLICA_URL:-DISABLED_I_KNOW_WHAT_IM_DOING}" \
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
