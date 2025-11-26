#!/bin/bash
# shellcheck disable=SC2034 # This is a defaults file
public_listen_port_default=443

headscale_extra_records_path_default="/data/headscale/extra-records.json"
headscale_magic_dns_default="true"
headscale_ipv6_only_default="false"
headscale_ipv6_prefix_default="fd7a:115c:a1e0::/48"
headscale_ipv4_prefix_default="100.64.0.0/10"
headscale_ip_allocation_default="sequential"
headscale_gomaxprocs_default=1
headscale_override_local_dns_default="true"

caddyfile_cleartext=/etc/caddy/Caddyfile-http
caddyfile_https=/etc/caddy/Caddyfile-https
headscale_config="/etc/headscale/config.yaml"
