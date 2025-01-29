#!/usr/bin/env bash

set -e

# Global flags
abort_config=false
litestream_disabled=false
caddy_disabled=false

#######################################
# Log an informational message
# Arguments:
#   $1 - Message to log
# Ouputs:
#   Message to `STDOUT`
#######################################
log_info() {
	echo "INFO: $1"
}

#######################################
# Log an error message and set abort flag
# Arguments:
#   $1 - Message to log
# Returns:
#   false
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
#   0 if populated, otherwise false
#######################################
env_var_is_populated() {
    [ -n "${!1}" ]
}

#######################################
# Ensure an environment variable is populated
# Arguments:
#   $1 - Variable name
# Globals:
#   abort_config
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
# Globals:
#   abort_config
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
	# If `PUBLIC_LISTEN_PORT` is set it needs to be valid
	if env_var_is_populated "PUBLIC_LISTEN_PORT" ; then
		validate_port "PUBLIC_LISTEN_PORT"
	else
		export PUBLIC_LISTEN_PORT=443
	fi
}

#######################################
# Validate Litestream replica URL
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
# Validate headscale-specific environment variables
#######################################
check_headscale_env_vars() {
	require_env_var "PUBLIC_SERVER_URL"
	require_env_var "HEADSCALE_DNS_CONFIG_BASE_DOMAIN"
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
        -e "s@\$PUBLIC_LISTEN_PORT@$PUBLIC_LISTEN_PORT@" \
        -e "s@\$IPV6_PREFIX@$IPV6_PREFIX@" \
        -e "s@\$IPV4_PREFIX@$IPV4_PREFIX@" \
        -e "s@\$HEADSCALE_DNS_CONFIG_BASE_DOMAIN@$HEADSCALE_DNS_CONFIG_BASE_DOMAIN@" \
		-e "s@\$MAGIC_DNS@$MAGIC_DNS@" \
        "$config_path" || log_error "Unable to generate Headscale configuration file"
}

#######################################
# Handle Noise private key
#######################################
reuse_or_create_noise_private_key() {
    local key_path="/data/noise_private.key"

    if env_var_is_populated "HEADSCALE_NOISE_PRIVATE_KEY"; then
        log_info "Using provided private Noise key."
        echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > "$key_path"
    else
        log_info "Generating a new private Noise key."
    fi
}

#######################################
# Validate ZeroSSL EAB credentials if provided and modify Caddyfile as needed
#######################################
check_zerossl_eab() {
	local caddyfile=/etc/caddy/Caddyfile 

	if env_var_is_populated "ACME_EAB_KEY_ID" || env_var_is_populated "ACME_EAB_MAC_KEY"; then
		log_info "We're using ACME EAB credentials. Check they're both populated."
		require_env_var "ACME_EAB_KEY_ID"
		require_env_var "ACME_EAB_MAC_KEY"

		sed -iz "s@<<EAB>>@acme_ca https://acme.zerossl.com/v2/DV90\nacme_eab {\n    key_id ${ACME_EAB_KEY_ID}\n    mac_key ${ACME_EAB_MAC_KEY}\n }@" $caddyfile || abort_config=1
	else
		log_info "No ACME EAB credentials provided"
		sed -i "s@<<EAB>>@@" $caddyfile || abort_config=1
	fi
}

#######################################
# Validate Caddy-specific environment variables
#######################################
check_caddy_specific_environment_variables() {
	if env_var_is_populated "CADDY_FRONTEND" ; then
		[ "${CADDY_FRONTEND}" = "DISABLED_I_KNOW_WHAT_IM_DOING" ] && caddy_disabled=true
		return
	fi

	require_env_var "CF_API_TOKEN"
	require_env_var "ACME_ISSUANCE_EMAIL"

	check_zerossl_eab
}

#######################################
# Create our configuration files
#######################################
check_config_files() {
	check_required_environment_vars

	create_headscale_config

	reuse_or_create_noise_private_key

	check_caddy_specific_environment_variables
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
		if ! $caddy_disabled ; then
			log_info "Starting Caddy using our environment variables" && \
			caddy start --config "/etc/caddy/Caddyfile"
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

		return
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
