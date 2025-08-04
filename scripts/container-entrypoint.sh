#!/bin/bash

set -euo pipefail

# Global flags
abort_config=false
litestream_enabled=true
https_enabled=true
caddyfile_cleartext=/etc/caddy/Caddyfile-http
caddyfile_https=/etc/caddy/Caddyfile-https
headscale_config="/etc/headscale/config.yaml"
ACME_EAB_BLOCK="" # Placeholder for ACME EAB block in Caddyfile
CLOUDFLARE_ACME_BLOCK="" # Placeholder for Cloudflare ACME block in Caddyfile
SECURITY_HEADERS_BLOCK="" # Placeholder for security headers block in Caddyfile

#######################################
# Log with different levels
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message to log
#######################################
log_with_level() {
    local level="$1"
    local message="$2"
    local timestamp;

	timestamp=$(date +"%Y-%m-%d %H:%M:%S")

	case "${level^^}" in
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
	env_var_is_populated "$1" || log_error "Environment variable '$1' is required"
}

########################################
# Create a directory if it doesn't exist
# Arguments:
#   $1 - Directory path
# Side Effects:
#   Calls log_error and sets abort_config=true on failure
########################################
create_directory_if_not_exists() {
	local dir="$1"
	if [ ! -d "$dir" ]; then
		mkdir -p "$dir" || log_error "Unable to create directory '$dir'."
	fi
}

########################################
# Check environment variable is set, or default (and optionally validate with regex - now you have two problems)
# Arguments:
#   $1 - Variable name
#   $2 - Default value
#   $3 - Validation regex pattern (optional)
#   $4 - Error message for invalid values (optional)
########################################
check_env_var_or_set_default() {
	local var_name="$1"
	local default_value="$2"
	local pattern="${3:-}"
	local error_msg="${4:-}"
	
	# Set default value if variable is not populated
	if ! env_var_is_populated "$var_name"; then
		export "$var_name"="$default_value"
	fi
	
	# Validate with regex if pattern provided
	if [[ -n "$pattern" && ! "${!var_name}" =~ $pattern ]]; then
		log_error "${error_msg:-"Invalid '$var_name' value: '${!var_name}'"}"
	fi
}

########################################
# Log enabled/disabled status for configuration summary
# Arguments:
#   $1 - Feature name
#   $2 - Boolean condition (true/false)
#   $3 - Optional additional info when enabled
#   $4 - Optional: "warn" to use log_warn when disabled, otherwise uses log_info
########################################
log_feature_status() {
	local feature="$1"
	local condition="$2"
	local extra_info="${3:-}"
	local warn_on_false="${4:-}"
	
	if $condition; then
		log_info "$feature: enabled${extra_info:+ ($extra_info)}"
	else
		if [[ "$warn_on_false" == "warn" ]]; then
			log_warn "$feature: disabled"
		else
			log_info "$feature: disabled"
		fi
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
    local port="$1"

    # Make sure our port is numeric
    if ! [[ "${!port}" =~ ^[0-9]+$ ]]; then
        log_error "Port '$port' is not numeric."
        return
    fi

    # Check no leading zeros (except for port '0')
    if [[ "${!port}" =~ ^0[0-9]+$ ]]; then
        log_error "Port '$port' has a leading zero."
        return
    fi

    # Check port is within valid range
    if [ "${!port}" -lt 1 ] || [ "${!port}" -gt 65535 ]; then
        log_error "Port '$port' must be a valid port within the range of 1-65535."
        return
    fi
}

#######################################
# Generic configuration file creator with template substitution
# Arguments:
#   $1 - Target config file path
#   $2 - Description for logging
#   $3 - File permissions (optional, defaults to 600)
#######################################
create_config_from_template() {
    local config_path="$1"
    local description="$2"
    local permissions="${3:-600}"
    local temp_config_path
    
    temp_config_path=$(mktemp) || {
        log_error "Unable to create temporary file for $description"
		return
    }

    if envsubst < "$config_path" > "$temp_config_path"; then
        chmod "$permissions" "$temp_config_path"
        if mv "$temp_config_path" "$config_path"; then
            return
        else
            log_error "Unable to move $description to final location"
            rm -f "$temp_config_path"
        fi
    else
        log_error "Unable to generate $description"
        rm -f "$temp_config_path"
    fi

	return
}

#######################################
# Set default or validate PUBLIC_LISTEN_PORT
#######################################
check_public_listen_port() {
	check_env_var_or_set_default "PUBLIC_LISTEN_PORT" "443"
	validate_port "PUBLIC_LISTEN_PORT"
}

#######################################
# Configure GOMAXPROCS for headscale to utilise available CPUs
# Either set manually or auto-detected
# Globals:
#   `GOMAXPROCS`
# Returns:
#   `true` on success, `false` on error
#######################################
configure_gomaxprocs() {
	local max_procs=""
	
	if env_var_is_populated "GOMAXPROCS"; then
		if ! [[ "$GOMAXPROCS" =~ ^[1-9][0-9]*$ ]]; then
			log_error "Invalid GOMAXPROCS value: '$GOMAXPROCS'. Must be a positive integer."
			return
		fi
		max_procs="$GOMAXPROCS"
	else
		# Auto-detect available CPUs
		# Try to read from cgroup v2 first (modern Docker/Kubernetes)
		if [ -f "/sys/fs/cgroup/cpu.max" ]; then
			local cpu_quota cpu_period
			read -r cpu_quota cpu_period < /sys/fs/cgroup/cpu.max
			if [ "$cpu_quota" != "max" ] && [ "$cpu_period" -gt 0 ]; then
				max_procs=$(( (cpu_quota + cpu_period - 1) / cpu_period ))
			fi
		fi

		# Fallback to cgroup v1
		if [ -z "$max_procs" ] && [ -f "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ] && [ -f "/sys/fs/cgroup/cpu/cpu.cfs_period_us" ]; then
			local quota period
			quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
			period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
			if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
				max_procs=$(( (quota + period - 1) / period ))
			fi
		fi

		# Final fallback to nproc (system CPU count)
		if [ -z "$max_procs" ] || [ "${max_procs:-0}" -lt 1 ]; then
			max_procs=$(nproc 2>/dev/null || echo "2")
		fi
	fi

	# Clamp GOMAXPROCS to a safe range
	if [ "${max_procs:-1}" -lt 1 ]; then
		max_procs=1
		log_warn "GOMAXPROCS was below minimum, clamped to 1"
	elif [ "${max_procs:-1}" -gt 32 ]; then
		max_procs=32
		log_warn "GOMAXPROCS was above maximum, clamped to 32"
	fi

	export GOMAXPROCS="$max_procs"
}

#######################################
# Validate Litestream replica URL
# Globals:
#   `litestream_enabled`
#######################################
check_litestream_replica_url() {
	require_env_var "LITESTREAM_REPLICA_URL" || return

	case "$LITESTREAM_REPLICA_URL" in
		DISABLED_I_KNOW_WHAT_IM_DOING)
			litestream_enabled=false
			;;
		s3://*)
			require_env_var "LITESTREAM_ACCESS_KEY_ID"
			require_env_var "LITESTREAM_SECRET_ACCESS_KEY"
			;;
		abs://*)
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
		require_env_var "HEADSCALE_OIDC_CLIENT_ID"
		require_env_var "HEADSCALE_OIDC_CLIENT_SECRET"
		env_var_is_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT" # Useful, not required
	fi
}

#######################################
# Set whether headscale should use Magic DNS
#######################################
set_magic_dns() {
	check_env_var_or_set_default "MAGIC_DNS" "true" "^(true|false)$" "Invalid 'MAGIC_DNS'. Must be 'true' or 'false'."
}

#######################################
# Set default headscale IP prefixes if not provided
#######################################
set_ip_prefixes() {
	check_env_var_or_set_default "IPV6_PREFIX" "fd7a:115c:a1e0::/48"
	check_env_var_or_set_default "IPV4_PREFIX" "100.64.0.0/10"
}

#######################################
# Set default headscale IP allocation if not provided, check it's valid
#######################################
set_ip_allocation() {
	check_env_var_or_set_default "IP_ALLOCATION" "sequential" "^(sequential|random)$" "Invalid 'IP_ALLOCATION'. Must be either 'sequential' (default) or 'random'."
}

#######################################
# Validate headscale-specific environment variables
#######################################
check_headscale_env_vars() {
	require_env_var "PUBLIC_SERVER_URL"
	require_env_var "HEADSCALE_DNS_BASE_DOMAIN"
	#This is for the v0.26.0 bump.
	if env_var_is_populated "HEADSCALE_POLICY_V1" ; then
		export HEADSCALE_POLICY_V1=1
		log_warn "Using Headscale policy version 1. Please migrate and remove this variable."
	fi
}

#######################################
# Perform all required environment variable checks
#######################################
check_required_environment_vars() {
	log_info "Checking required environment variables..."
	check_public_listen_port
	configure_gomaxprocs
	check_litestream_replica_url
	validate_oidc_settings
	set_ip_prefixes
	set_ip_allocation
	set_magic_dns
	check_headscale_env_vars
}

#######################################
# Validate ZeroSSL EAB credentials if provided and modify Caddyfile as needed
#######################################
check_zerossl_eab() {
	if env_var_is_populated "ACME_EAB_KEY_ID" || env_var_is_populated "ACME_EAB_MAC_KEY"; then
		require_env_var "ACME_EAB_KEY_ID"
		require_env_var "ACME_EAB_MAC_KEY"

		export ACME_EAB_BLOCK="acme_ca https://acme.zerossl.com/v2/DV90
        acme_eab {
            key_id ${ACME_EAB_KEY_ID}
            mac_key ${ACME_EAB_MAC_KEY}
        }"
	else
        export ACME_EAB_BLOCK=""
	fi
}

#######################################
# Validate the Cloudflare API Key if provided and modify Caddyfile as needed
#######################################
check_cloudflare_dns_api_key() {
    if env_var_is_populated "CF_API_TOKEN" ; then
		export CLOUDFLARE_ACME_BLOCK="tls {
			dns cloudflare ${CF_API_TOKEN}
		}"
    else
		export CLOUDFLARE_ACME_BLOCK=""
    fi
}

#######################################
# Configure security headers for Caddy
# Arguments:
#   None
# Environment Variables:
#   SECURITY_HEADERS - Custom headers, "DEFAULT", "MINIMAL", or "DISABLED"
# Globals:
#   SECURITY_HEADERS_BLOCK - Exported Caddy header block
# Returns:
#   `true` on success, `false` on error
#######################################
configure_security_headers() {
    # Modern security headers with sensible defaults
    local default_headers=(
        "X-Frame-Options \"DENY\""
        "X-Content-Type-Options \"nosniff\""
        "Referrer-Policy \"strict-origin-when-cross-origin\""
        "X-XSS-Protection \"1; mode=block\""
        "Permissions-Policy \"camera=(), microphone=(), geolocation=()\""
        "Cross-Origin-Embedder-Policy \"require-corp\""
        "Cross-Origin-Opener-Policy \"same-origin\""
    )
    
    # Minimal security headers for compatibility
    local minimal_headers=(
        "X-Frame-Options \"DENY\""
        "X-Content-Type-Options \"nosniff\""
    )
    
	# Note: For documentation on security headers, see:
	# - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
	# - https://owasp.org/www-project-secure-headers/
	
	# Helper function to convert array to multi-line string for Caddy config
	array_to_caddy_block() {
		local -n headers_array=$1
		local result=""
		for header in "${headers_array[@]}"; do
			result+=$'\t\t\t'"${header}"$'\n'
		done
		echo "$result"
	}
	
	# Convert arrays to multi-line strings for Caddy config with exact formatting
	local default_headers_string minimal_headers_string
	default_headers_string=$(array_to_caddy_block default_headers)
	minimal_headers_string=$(array_to_caddy_block minimal_headers)
	
	# Handle preset values
    local headers
    case "${SECURITY_HEADERS:-DEFAULT}" in
        "DEFAULT")
            headers="$default_headers_string"
            ;;
        "MINIMAL")
            headers="$minimal_headers_string"
            ;;
        "DISABLED")
            export SECURITY_HEADERS_BLOCK=""
            log_warn "Security headers have been explicitly disabled"
            return
            ;;
        *)
            headers="$SECURITY_HEADERS"
            ;;
    esac
    
    # Basic validation: check if headers contain at least one valid header pattern
    if ! [[ "$headers" =~ [A-Za-z-]+[[:space:]]+ ]]; then
        log_warn "Invalid header format detected, falling back to defaults"
        headers="$default_headers_string"
    fi
    
    export SECURITY_HEADERS_BLOCK=$'\n\t\theader {\n'"${headers}"$'\t\t}'
}

#######################################
# Validate Caddy-specific environment variables
#######################################
check_caddy_specific_environment_variables() {
	configure_security_headers || return
	
	if env_var_is_populated "CADDY_FRONTEND" && [ "${CADDY_FRONTEND}" = "DISABLE_HTTPS" ]; then
		https_enabled=false
		return
	fi

	require_env_var "ACME_ISSUANCE_EMAIL"
	check_cloudflare_dns_api_key
	check_zerossl_eab
}

#######################################
# CONFIGURATION CREATION FUNCTIONS  
#######################################

#######################################
# Create required directories
#######################################
check_needed_directories() {
	local directories=(
		"/var/run/headscale"
		"/data/headscale"
		"/data/caddy"
	)
	
	for dir in "${directories[@]}"; do
		create_directory_if_not_exists "$dir"
	done
}

#######################################
# Create Caddy HTTPS configuration file
#######################################
create_caddy_https_config() {
	create_config_from_template "$caddyfile_https" "Caddy HTTPS configuration file"
}

#######################################
# Create Caddy HTTP configuration file
#######################################
create_caddy_http_config() {
	create_config_from_template "$caddyfile_cleartext" "Caddy HTTP configuration file"
}

#######################################
# Create Headscale configuration file
#######################################
create_headscale_config() {
	create_config_from_template "$headscale_config" "Headscale configuration file"
}

#######################################
# Handle Noise private key
#######################################
reuse_or_create_noise_private_key() {
	local key_path="/data/noise_private.key"

	if [ -f "$key_path" ]; then
		chmod 600 "$key_path"
		return
	fi

	if env_var_is_populated "HEADSCALE_NOISE_PRIVATE_KEY"; then
	    printf '%s' "$HEADSCALE_NOISE_PRIVATE_KEY" > "$key_path"
        chmod 600 "$key_path"
	else
		log_info "Generating new Noise private key - existing clients will need to re-authenticate"
	fi
}

#######################################
# Create our configuration files
#######################################
check_config_files() {
	check_required_environment_vars

	check_caddy_specific_environment_variables

	# Ensure all template variables are exported for envsubst
	local template_vars=(
		"ACME_EAB_BLOCK"
		"CLOUDFLARE_ACME_BLOCK"
		"SECURITY_HEADERS_BLOCK"
	)
	for var in "${template_vars[@]}"; do
		export "$var"
	done

	create_caddy_https_config
	create_caddy_http_config

	create_headscale_config

	reuse_or_create_noise_private_key
}

#######################################
# SERVICE MANAGEMENT FUNCTIONS
#######################################

#######################################
# Display configuration summary
#######################################
display_configuration_summary() {
	log_info "=== Configuration Summary ==="
	log_info "Server URL: $PUBLIC_SERVER_URL"
	log_info "Tailnet Base Domain: $HEADSCALE_DNS_BASE_DOMAIN"
	log_info "Public Listening Port: $PUBLIC_LISTEN_PORT"
	log_info "GOMAXPROCS: $GOMAXPROCS"

	log_feature_status "HTTPS Mode" "$https_enabled" "" "warn"
	log_feature_status "Litestream" "$litestream_enabled" "$LITESTREAM_REPLICA_URL" "warn"
	log_feature_status "Magic DNS" "$MAGIC_DNS"

	log_info "IP Allocation: $IP_ALLOCATION"
	log_info "IPv4 Prefix: $IPV4_PREFIX"
	log_info "IPv6 Prefix: $IPV6_PREFIX"

	log_feature_status "OIDC" "$(env_var_is_populated "HEADSCALE_OIDC_ISSUER")" "${HEADSCALE_OIDC_ISSUER:-}"

	if $https_enabled; then
		if env_var_is_populated "CF_API_TOKEN"; then
			log_info "DNS Challenge: Cloudflare"
		else
			log_info "DNS Challenge: HTTP-01"
		fi
		if env_var_is_populated "ACME_EAB_KEY_ID"; then
			log_feature_status "ACME EAB" true "ZeroSSL"
		else
			log_feature_status "ACME EAB" false "Let's Encrypt"
		fi
	fi

	log_feature_status "Security Headers" "$([[ -n "$SECURITY_HEADERS_BLOCK" ]])" "${SECURITY_HEADERS:-DEFAULT}" "warn"

	log_info "=============================="
}

#######################################
# Start Caddy service
#######################################
start_caddy_service() {
	log_info "Starting Caddy using our environment variables."

	if $https_enabled; then
		caddy start --config "$caddyfile_https" || {
			log_error "Failed to start Caddy with HTTPS config"
			return
		}
	else
		caddy start --config "$caddyfile_cleartext" || {
			log_error "Failed to start Caddy with cleartext config"
			return
		}
	fi

	# Verify Caddy is actually running
	sleep 2
	if ! pgrep caddy > /dev/null; then
		log_error "Caddy failed to start properly"
		return
	fi
}

#######################################
# Start Headscale service
#######################################
start_headscale_service() {
	if $litestream_enabled; then
		log_info "Attempt to restore previous Headscale database if there's a replica"
		litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 ||
			log_warn "No replica found, or unable to restore database."

		log_info "Starting Headscale using Litestream and our Environment Variables..."
		exec litestream replicate -exec 'headscale serve'
	else
		log_info "Starting Headscale without Litestream"
		exec headscale serve
	fi
}

#######################################
# Main logic
#######################################
run() {
	check_needed_directories

	check_config_files

	if $abort_config ; then
		log_error "Configuration validation failed. Exiting."
		exit
	fi

	# Here we... here we... here we go!!!
	display_configuration_summary

	start_caddy_service

	start_headscale_service

	if [ -n "${DEBUG:-}" ] ; then
		log_info "Sleeping so you can connect and debug"
		# Allow us to start a terminal in the container for debugging
		sleep infinity
	fi

	exit 1
}

run
