#!/bin/bash
# CI-specific defaults for config generation
# These are used in the GitHub Actions workflow to generate a baseline config

# Export default values for envsubst in templates
# shellcheck disable=SC2034
export IP_PREFIXES="v4: $headscale_ipv4_prefix_default
v6: $headscale_ipv6_prefix_default"

export PUBLIC_SERVER_URL="https://example.com"
export PUBLIC_LISTEN_PORT="443"
export HEADSCALE_DNS_BASE_DOMAIN="example.com"
export HEADSCALE_OVERRIDE_LOCAL_DNS="true"
export MAGIC_DNS="true"
export IP_ALLOCATION="sequential"
export HEADSCALE_EXTRA_RECORDS_PATH="/data/headscale/extra-records.json"
export EPHEMERAL_NODE_INACTIVITY_TIMEOUT="30m"
