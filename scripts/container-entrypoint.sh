#!/bin/bash

set -e

# Global flags
abort_config=false
litestream_disabled=false
cleartext_only=false
caddyfile_cleartext=/etc/caddy/Caddyfile-http
caddyfile_https=/etc/caddy/Caddyfile-https

#######################################
# Log an informational message
# Arguments:
#   `$1` - Message to log
# Ouputs:
#   Message to `STDOUT`
#######################################
log_info() {
	echo "INFO: $1"
}

#######################################
# Log an error message and set abort flag
# Arguments:
#   `$1` - Message to log
# Globals:
#   `abort_config`
# Returns:
#   `false`
# Ouputs:
#   Message to `STDERR`
#######################################
log_error() {
	echo >&2 "ERROR: $1"
	abort_config=true
	false
}

#######################################
# Check if an environment variable is populated
# Arguments:
#   $1 - Variable name
# Returns:
#   `true` if populated, otherwise `false`
#######################################
env_var_is_populated() {
	[ -n "${!1}" ]
}

#######################################
# Ensure an environment variable is populated
# Arguments:
#   $1 - Variable name
# Returns:
#   `true` if populated, otherwise `false`
#######################################
require_env_var() {
	if ! env_var_is_populated "$1"; then
		log_error "Environment variable '$1' is required"
	fi
}

#######################################
# Validate a port number
# Arguments:
#   $1 - Variable name containing the port
# Returns:
#   `true` if deemed valid, otherwise `false`
#######################################
validate_port() {
	port="$1"
	case "${!port}" in
		'' | *[!0123456789]*) log_error "'$port' is not numeric." && return ;;
		0*[!0]*) log_error "'$port' has a leading zero." && return ;;
	esac

	if [ "${!port}" -lt 1  ] || [ "${!port}" -gt 65535 ] ; then
		log_error "'$port' must be a valid port within the range of 1-65535." && return
	fi
}

#######################################
# Set default or validate PUBLIC_LISTEN_PORT
#######################################
check_public_listen_port() {
	export PUBLIC_LISTEN_PORT="${PUBLIC_LISTEN_PORT:-443}"
	validate_port "PUBLIC_LISTEN_PORT"
}

#######################################
# Validate Litestream replica URL
# Globals:
#   `litestream_disabled`
#######################################
check_litestream_replica_url() {
	if ! require_env_var "LITESTREAM_REPLICA_URL"; then
		return
	fi	

	case "$LITESTREAM_REPLICA_URL" in
		DISABLED_I_KNOW_WHAT_IM_DOING)
			log_info "Ephemeral server configuration enabled."
			litestream_disabled=true
			;;
		s3://*)
			log_info "Using S3-Alike storage for Litestream."
			require_env_var "LITESTREAM_ACCESS_KEY_ID"
			require_env_var "LITESTREAM_SECRET_ACCESS_KEY"
			;;
		abs://*)
			log_info "Using Azure Blob storage for Litestream."
			require_env_var "LITESTREAM_AZURE_ACCOUNT_KEY"
			;;
		*)
			log_error "Invalid 'LITESTREAM_REPLICA_URL'. Must start with 's3://', 'abs://', or be set to 'DISABLED_I_KNOW_WHAT_IM_DOING'."
			;;
	esac
}

#######################################
# Validate OIDC settings
#######################################
validate_oidc_settings() {
	if env_var_is_populated "HEADSCALE_OIDC_ISSUER" ; then
		log_info "We're using OIDC issuance from '$HEADSCALE_OIDC_ISSUER'"
		require_env_var "HEADSCALE_OIDC_CLIENT_ID"
		require_env_var "HEADSCALE_OIDC_CLIENT_SECRET"
		env_var_is_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT" # Useful, not required
	fi
}

#######################################
# Set whether headscale should use Magic DNS
#######################################
set_magic_dns() {
	export MAGIC_DNS="${MAGIC_DNS:-true}"
	log_info "Using Magic DNS: '$MAGIC_DNS'"
}

#######################################
# Set default headscale IP prefixes if not provided
#######################################
set_ip_prefixes() {
	export IPV6_PREFIX="${IPV6_PREFIX:-fd7a:115c:a1e0::/48}"
	export IPV4_PREFIX="${IPV4_PREFIX:-100.64.0.0/10}"
	log_info "Using subnets IPV6: '$IPV6_PREFIX', IPV4: '$IPV4_PREFIX'"
}

#######################################
# Set default headscale IP allocation if not provided, check it's valid
#######################################
set_ip_allocation() {
	export IP_ALLOCATION="${IP_ALLOCATION:-sequential}"

	log_info "Using ${IP_ALLOCATION} IP allocation"

	case "$IP_ALLOCATION" in
		sequential)
			;;
		random)
			;;
		*)
			log_error "Invalid 'IP_ALLOCATION'. Must be either 'sequential' (default) or 'random'."
			;;
	esac
}

#######################################
# Validate headscale-specific environment variables
#######################################
check_headscale_env_vars() {
	require_env_var "PUBLIC_SERVER_URL"
	require_env_var "HEADSCALE_DNS_CONFIG_BASE_DOMAIN"
	#This is for the v0.26.0 bump.
	if env_var_is_populated "HEADSCALE_POLICY_V1" ; then
		export HEADSCALE_POLICY_V1=1
		log_info "Using Headscale policy version 1. Please migrate and remove this variable."
	fi
}

#######################################
# Perform all required environment variable checks
#######################################
check_required_environment_vars() {
	log_info "Checking required environment variables..."
	check_public_listen_port
	check_litestream_replica_url
	validate_oidc_settings
	set_ip_prefixes
	set_ip_allocation
	set_magic_dns
	check_headscale_env_vars
}

#######################################
# Create Headscale configuration file
#######################################
create_headscale_config() {
	local config_path="/etc/headscale/config.yaml"

	log_info "Generating Headscale configuration file..."

	sed -i \
		-e "s@\$PUBLIC_SERVER_URL@$PUBLIC_SERVER_URL@" \
		-e "s@\$HEADSCALE_LISTEN_ADDRESS@$HEADSCALE_LISTEN_ADDRESS@" \
		-e "s@\$PUBLIC_LISTEN_PORT@$PUBLIC_LISTEN_PORT@" \
		-e "s@\$IPV6_PREFIX@$IPV6_PREFIX@" \
		-e "s@\$IPV4_PREFIX@$IPV4_PREFIX@" \
		-e "s@\$IP_ALLOCATION@$IP_ALLOCATION@" \
		-e "s@\$HEADSCALE_DNS_CONFIG_BASE_DOMAIN@$HEADSCALE_DNS_CONFIG_BASE_DOMAIN@" \
		-e "s@\$MAGIC_DNS@$MAGIC_DNS@" \
		"$config_path" || log_error "Unable to generate Headscale configuration file"
}

#######################################
# Handle Noise private key
#######################################
reuse_or_create_noise_private_key() {
	local key_path="/data/noise_private.key"

	if [ -f "$key_path" ]; then
		log_info "Using existing private Noise key on disk."
		return
	fi

	if env_var_is_populated "HEADSCALE_NOISE_PRIVATE_KEY"; then
		log_info "Using provided private Noise key from environment variable."
		echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > "$key_path"
	else
		log_info "Generating a new private Noise key."
	fi
}

#######################################
# Validate ZeroSSL EAB credentials if provided and modify Caddyfile as needed
#######################################
check_zerossl_eab() {
	if env_var_is_populated "ACME_EAB_KEY_ID" || env_var_is_populated "ACME_EAB_MAC_KEY"; then
		log_info "We're using ACME EAB credentials. Check they're both populated."
		require_env_var "ACME_EAB_KEY_ID"
		require_env_var "ACME_EAB_MAC_KEY"

		sed -iz \
		  "s@<<EAB>>@acme_ca https://acme.zerossl.com/v2/DV90\nacme_eab {\n	key_id ${ACME_EAB_KEY_ID}\n	mac_key ${ACME_EAB_MAC_KEY}\n }@" \
		  $caddyfile_https || abort_config=1
	else
		log_info "No ACME EAB credentials provided"
		sed -i "s@<<EAB>>@@" $caddyfile_https || abort_config=1
	fi
}

#######################################
# Validate the Cloudflare API Key if provided and modify Caddyfile as needed
#######################################
check_cloudflare_dns_api_key() {
	if env_var_is_populated "CF_API_TOKEN" ; then
		log_info "Using Cloudflare for ACME DNS Challenge."

		sed -iz \
		 "s@<<CLOUDFLARE_ACME>>@tls {\n	dns cloudflare $CF_API_TOKEN\n  }@" \
		  $caddyfile_https || abort_config=1
	else
		log_info "Using HTTP authentication for ACME DNS Challenge"
		sed -i "s@<<CLOUDFLARE_ACME>>@@" $caddyfile_https || abort_config=1
	fi
}

#######################################
# Validate Caddy-specific environment variables
#######################################
check_caddy_specific_environment_variables() {
	if env_var_is_populated "CADDY_FRONTEND" ; then
		[ "${CADDY_FRONTEND}" = "DISABLE_HTTPS" ] && cleartext_only=true
		return		
	fi

	require_env_var "ACME_ISSUANCE_EMAIL"
	check_cloudflare_dns_api_key
	check_zerossl_eab
}

#######################################
# Create our configuration files
#######################################
check_config_files() {
	check_required_environment_vars

	check_caddy_specific_environment_variables

	create_headscale_config

	reuse_or_create_noise_private_key
}

#######################################
# Create required directories
#######################################
check_needed_directories() {
	mkdir -p /var/run/headscale || return
	mkdir -p /data/headscale || return
	mkdir -p /data/caddy || return
}

#######################################
# Main logic
#######################################
run() {
	check_needed_directories || log_error "Unable to create required configuration directories."

	check_config_files || log_error "We don't have enough information to run our services."

	if ! $abort_config ; then
		log_info "Starting Caddy using our environment variables. HTTPS is $([ "$cleartext_only" ] && echo "disabled" || echo "enabled")."

		if $cleartext_only ; then
			caddy start --config "$caddyfile_cleartext"
		else
			caddy start --config "$caddyfile_https"
		fi

		if ! $litestream_disabled ; then
			log_info "Attempt to restore previous Headscale database if there's a replica" && \
			litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 && \
			\
			log_info "Starting Headscale using Litestream and our Environment Variables..." && \
			litestream replicate -exec 'headscale serve'
		else
			headscale serve
		fi
	fi

	log_error "Something went wrong."
	if [ -n "$DEBUG" ] ; then
		log_info "Sleeping so you can connect and debug"
		# Allow us to start a terminal in the container for debugging
		sleep infinity
	fi

	log_error "Exiting with code ${abort_config}"
	exit "$abort_config"
}

run
