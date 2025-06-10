#!/bin/bash

set -euo pipefail

# Global flags
abort_config=false
litestream_disabled=false
cleartext_only=false
caddyfile_cleartext=/etc/caddy/Caddyfile-http
caddyfile_https=/etc/caddy/Caddyfile-https

#######################################
# Log with different levels
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message to log
#######################################
log_with_level() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        ERROR)
            echo "[$timestamp] ERROR: $message" >&2
            ;;
        WARN)
            echo "[$timestamp] WARN: $message" >&2
            ;;
        *)
            echo "[$timestamp] INFO: $message"
            ;;
    esac
}

#######################################
# Log an informational message
# Arguments:
#   `$1` - Message to log
#######################################
log_info() {
    log_with_level "INFO" "$1"
}

#######################################
# Log a warning message
# Arguments:
#   `$1` - Message to log
#######################################
log_warn() {
    log_with_level "WARN" "$1"
}

#######################################
# Log an error message and set abort flag
# Arguments:
#   `$1` - Message to log
# Globals:
#   `abort_config`
# Returns:
#   `false`
#######################################
log_error() {
    log_with_level "ERROR" "$1"
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
    # Only allow variable names with letters, numbers, and underscores, not starting with a number
    if [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        [ -n "${!1-}" ]
    else
        log_error "Invalid environment variable name: '$1'"
    fi
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
    value="${!port}"

    # Make sure our port is numeric
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "Port '$port' is not numeric." && return
    fi

    # Check no leading zeros (except for port '0')
    if [[ "$value" =~ ^0[0-9]+$ ]]; then
        log_error "Port '$port' has a leading zero." && return
    fi

    # Check port is within valid range
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        log_error "Port '$port' must be a valid port within the range of 1-65535." && return
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
    local temp_config_path
    
    temp_config_path=$(mktemp) || {
        log_error "Unable to create temporary file"
        return
    }

    log_info "Generating Headscale configuration file..."

    if envsubst < "$config_path" > "$temp_config_path"; then
        chmod 600 "$temp_config_path"
        if mv "$temp_config_path" "$config_path"; then
            log_info "Headscale configuration file created successfully"
        else
            log_error "Unable to move Headscale configuration file"
            rm -f "$temp_config_path"
        fi
    else
        log_error "Unable to generate Headscale configuration file"
        rm -f "$temp_config_path"
    fi
}

#######################################
# Handle Noise private key
#######################################
reuse_or_create_noise_private_key() {
	local key_path="/data/noise_private.key"

	if [ -f "$key_path" ]; then
		log_info "Using existing private Noise key on disk."
		chmod 600 "$key_path"
		return
	fi

	if env_var_is_populated "HEADSCALE_NOISE_PRIVATE_KEY"; then
		log_info "Using provided private Noise key from environment variable."
	    printf '%s' "$HEADSCALE_NOISE_PRIVATE_KEY" > "$key_path"
        chmod 600 "$key_path"
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

		if ! sed -i \
		  "s@<<EAB>>@acme_ca https://acme.zerossl.com/v2/DV90\nacme_eab {\n	key_id ${ACME_EAB_KEY_ID}\n	mac_key ${ACME_EAB_MAC_KEY}\n }@" \
		  "$caddyfile_https"; then
			log_error "Failed to modify Caddyfile with ACME EAB credentials"
		fi
	else
		log_info "No ACME EAB credentials provided"
		if ! sed -i \
		  "s@<<EAB>>@@" \
		  "$caddyfile_https" ; then
			log_error "Failed to modify Caddyfile to remove ACME EAB placeholder"
		fi
	fi
}

#######################################
# Validate the Cloudflare API Key if provided and modify Caddyfile as needed
#######################################
check_cloudflare_dns_api_key() {
    if env_var_is_populated "CF_API_TOKEN" ; then
        log_info "Using Cloudflare for ACME DNS Challenge."

        if ! sed -i \
         "s@<<CLOUDFLARE_ACME>>@tls {\n	dns cloudflare $CF_API_TOKEN\n  }@" \
          "$caddyfile_https"; then
            log_error "Failed to configure Cloudflare DNS in Caddyfile"
        fi
    else
        log_info "Using HTTP authentication for ACME DNS Challenge"
        if ! sed -i "s@<<CLOUDFLARE_ACME>>@@" "$caddyfile_https"; then
            log_error "Failed to remove Cloudflare placeholder from Caddyfile"
        fi
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
	mkdir -p /var/run/headscale || log_error "Unable to create /var/run/headscale directory."
	mkdir -p /data/headscale || log_error "Unable to create /data/headscale directory."
	mkdir -p /data/caddy || log_error "Unable to create /data/caddy directory."
}

#######################################
# Main logic
#######################################
run() {
	check_needed_directories

	check_config_files

	if ! $abort_config ; then
		log_info "Starting Caddy using our environment variables. HTTPS is $([ "$cleartext_only" = true ] && echo "disabled" || echo "enabled")."

		if [ "$cleartext_only" = true ] ; then
			caddy start --config "$caddyfile_cleartext" || log_error "Failed to start Caddy with cleartext config"
		else
			caddy start --config "$caddyfile_https" || log_error "Failed to start Caddy with HTTPS config"
		fi

		# Make sure Caddy started successfully before starting headscale
        if ! $abort_config ; then
			if [ "$litestream_disabled" = false ] ; then
				log_info "Attempt to restore previous Headscale database if there's a replica"
				litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 ||
					log_warn "No replica found, or unable to restore database."

				log_info "Starting Headscale using Litestream and our Environment Variables..."
				exec litestream replicate -exec 'headscale serve'
			else
				log_info "Starting Headscale without Litestream"
				exec headscale serve
			fi
		fi
	fi

	log_error "Something went wrong."
	if [ -n "${DEBUG:-}" ] ; then
		log_info "Sleeping so you can connect and debug"
		# Allow us to start a terminal in the container for debugging
		sleep infinity
	fi

	exit 1
}

run
