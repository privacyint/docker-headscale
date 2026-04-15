#!/bin/bash
# CI-specific defaults for config generation
# These are used in the GitHub Actions workflow to generate a baseline config

# Export default values for envsubst in templates
# shellcheck disable=SC2034,SC2154
export IP_PREFIXES="v4: $headscale_ipv4_prefix_default
  v6: $headscale_ipv6_prefix_default"
export PUBLIC_SERVER_URL="example.com"
export PUBLIC_LISTEN_PORT="$public_listen_port_default"
export HEADSCALE_DNS_BASE_DOMAIN="example.com"
export HEADSCALE_OVERRIDE_LOCAL_DNS="$headscale_override_local_dns_default"
export MAGIC_DNS="$headscale_magic_dns_default"
export IP_ALLOCATION="$headscale_ip_allocation_default"
export HEADSCALE_EXTRA_RECORDS_PATH="$headscale_extra_records_path_default"
export EPHEMERAL_NODE_INACTIVITY_TIMEOUT="$headscale_ephemeral_node_inactivity_timeout_default"
export GLOBAL_NAMESERVERS_YAML="
      - 1.1.1.1
      - 1.0.0.1
      - 2606:4700:4700::1111
      - 2606:4700:4700::1001"
