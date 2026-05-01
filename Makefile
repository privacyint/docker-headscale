SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help check-envsubst render-fly-config render-azure-container-apps

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make render-fly-config           Render fly.toml from templates/fly.template.toml' \
	  '  make render-azure-container-apps Render azure-container-apps.yaml from templates/azure-container-apps.template.yaml'

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
