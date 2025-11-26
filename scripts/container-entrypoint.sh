#!/bin/bash

# shellcheck disable=SC2310  # Functions in our if conditions disable set -e by design
# shellcheck disable=SC2154  # Environment variables provided at runtime, error checking is done in functions

set -euo pipefail

# Helper scripts
declare helper_scripts=(
	"defaults.sh"
	"logging.sh"
	"variables-check.sh"
	"file-operations.sh"
)

# Global flags
abort_config=false
litestream_enabled=true
https_enabled=true

# Caddyfile block placeholders 
ACME_EAB_BLOCK=""
CLOUDFLARE_ACME_BLOCK=""
SECURITY_HEADERS_BLOCK=""

#######################################
# Set default or validate PUBLIC_LISTEN_PORT
#######################################
check_public_listen_port() {
	check_env_var_or_set_default "PUBLIC_LISTEN_PORT" "${public_listen_port_default}"
	validate_port "PUBLIC_LISTEN_PORT"
}

#######################################
# Autodetect GOMAXPROCS settings
# Attempts to read CPU limits from cgroup v2 or v1, falling back to nproc
# If no limits are found, defaults to 2
# If the detected value is below 1 or above 32, it will be clamped to that range
# Globals:
#   `GOMAXPROCS`
#######################################
autodetect_gomaxprocs() {
	local max_procs=""

	# Try to read from cgroup v2 first (modern Docker/Kubernetes)
	if [[ -f "/sys/fs/cgroup/cpu.max" ]]; then
		local cpu_quota="" cpu_period=""
		if read -r cpu_quota cpu_period < /sys/fs/cgroup/cpu.max 2>/dev/null; then
			if [[ "${cpu_quota}" != "max" ]] && [[ "${cpu_period}" =~ ^[0-9]+$ ]] && [[ "${cpu_period}" -gt 0 ]]; then
				max_procs=$(( (cpu_quota + cpu_period - 1) / cpu_period ))
			fi
		fi
	fi

	# Fallback to cgroup v1
	if [[ -z "${max_procs}" ]] && [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ]] && [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_period_us" ]]; then
		local quota period
		quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
		period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
		if [[ "${quota}" -gt 0 ]] && [[ "${period}" -gt 0 ]]; then
			max_procs=$(( (quota + period - 1) / period ))
		fi
	fi

	# Final fallback to nproc (system CPU count)
	if [[ -z "${max_procs}" ]] || [[ "${max_procs:-0}" -lt 1 ]]; then
		max_procs=$(nproc 2>/dev/null || echo "2")
	fi

	# Clamp GOMAXPROCS to a safe range
	if [[ "${max_procs:-1}" -lt 1 ]]; then
		max_procs=1
		log_warn "GOMAXPROCS was below minimum, clamped to 1"
	elif [[ "${max_procs:-1}" -gt 32 ]]; then
		max_procs=32
		log_warn "GOMAXPROCS was above maximum, clamped to 32"
	fi

	export GOMAXPROCS="${max_procs}"
	log_info "Auto-detected GOMAXPROCS=${max_procs}"
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
	if env_var_is_defined "GOMAXPROCS"; then
		check_env_var_or_set_default "GOMAXPROCS" "${headscale_gomaxprocs_default}" "^[1-9][0-9]*$" "Invalid 'GOMAXPROCS'. Must be a positive integer."
	else
		autodetect_gomaxprocs
	fi
}

#######################################
# Validate Litestream replica URL
# Globals:
#   `litestream_enabled`
#######################################
check_litestream_replica_url() {
	require_env_var "LITESTREAM_REPLICA_URL" || return

	case "${LITESTREAM_REPLICA_URL^^}" in
		DISABLED_I_KNOW_WHAT_IM_DOING)
			litestream_enabled=false
			;;
		S3://*)
			require_env_var "LITESTREAM_ACCESS_KEY_ID"
			require_env_var "LITESTREAM_SECRET_ACCESS_KEY"
			;;
		ABS://*)
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
	if ! env_var_is_defined "HEADSCALE_OIDC_ISSUER"; then
		log_info "OIDC is not enabled, skipping OIDC validation."
		return
	fi

	require_env_var "HEADSCALE_OIDC_CLIENT_ID"
	require_env_var "HEADSCALE_OIDC_CLIENT_SECRET"
}

#######################################
# Validate extra DNS records settings
#######################################
validate_extra_records() {
    check_env_var_or_set_default "HEADSCALE_EXTRA_RECORDS_PATH" "${headscale_extra_records_path_default}"

    # Ensure the directory exists
    local records_dir
    records_dir=$(dirname "${HEADSCALE_EXTRA_RECORDS_PATH}")
    create_directory_if_not_exists "${records_dir}"

    # Create empty JSON file if it doesn't exist
    if [[ ! -f "${HEADSCALE_EXTRA_RECORDS_PATH}" ]]; then
        if ! echo '[]' > "${HEADSCALE_EXTRA_RECORDS_PATH}"; then
            log_error "Unable to create extra records file at '${HEADSCALE_EXTRA_RECORDS_PATH}'"
            return
        fi
        log_info "Created empty extra records file at '${HEADSCALE_EXTRA_RECORDS_PATH}'"
    fi

    # Validate it's readable
    if [[ ! -r "${HEADSCALE_EXTRA_RECORDS_PATH}" ]]; then
        log_error "Extra records file '${HEADSCALE_EXTRA_RECORDS_PATH}' is not readable"
    fi
}

#######################################
# Validate IP address settings
#######################################
check_ip_address_settings() {
	check_env_var_or_set_default "IP_ALLOCATION" "${headscale_ip_allocation_default}" "^(sequential|random)$" "Invalid 'IP_ALLOCATION'. Must be either 'sequential' (default) or 'random'."
	check_env_var_or_set_default "IPV6_ONLY" "${headscale_ipv6_only_default}" "^(true|false)$" "Invalid 'IPV6_ONLY'. Must be 'true' or 'false'."
	check_env_var_or_set_default "IPV6_PREFIX" "${headscale_ipv6_prefix_default}"

	if [[ "${IPV6_ONLY}" == "true" ]]; then
		export IP_PREFIXES="v6: ${IPV6_PREFIX}"
	else
		check_env_var_or_set_default "IPV4_PREFIX" "${headscale_ipv4_prefix_default}"
		export IP_PREFIXES="v4: ${IPV4_PREFIX}
  v6: ${IPV6_PREFIX}"
	fi
}

#######################################
# Perform all Headscale environment variable checks
#######################################
check_headscale_environment_vars() {
	log_info "Checking Headscale environment variables..."
	check_public_listen_port
	configure_gomaxprocs
	check_litestream_replica_url
	validate_oidc_settings
	validate_extra_records
	check_ip_address_settings
	check_env_var_or_set_default "HEADSCALE_OVERRIDE_LOCAL_DNS" "true" "^(true|false)$" "Invalid 'HEADSCALE_OVERRIDE_LOCAL_DNS'. Must be 'true' (default) or 'false'."
	check_env_var_or_set_default "MAGIC_DNS" "${headscale_magic_dns_default}" "^(true|false)$" "Invalid 'MAGIC_DNS'. Must be 'true' or 'false'."
	require_env_var "PUBLIC_SERVER_URL"
	require_env_var "HEADSCALE_DNS_BASE_DOMAIN"
}

#######################################
# Create our Headscale configuration file
#######################################
create_headscale_config() {
	# Ensure all template variables are exported for envsubst
    local template_vars=(
        "ACME_EAB_BLOCK"
        "CLOUDFLARE_ACME_BLOCK"
        "SECURITY_HEADERS_BLOCK"
        "PUBLIC_SERVER_URL"
        "PUBLIC_LISTEN_PORT"
        "HEADSCALE_DNS_BASE_DOMAIN"
        "HEADSCALE_OVERRIDE_LOCAL_DNS"
        "MAGIC_DNS"
        "IP_PREFIXES"
        "IP_ALLOCATION"
        "HEADSCALE_EXTRA_RECORDS_PATH"
    )
	for var in "${template_vars[@]}"; do
		export "${var}=${!var}"
	done

	create_config_from_template "${headscale_config}" "Headscale configuration file"
}

#######################################
# Create our Caddyfile
#######################################
create_caddyfile() {
	if ${https_enabled}; then
		create_config_from_template "${caddyfile_https}" "Caddy HTTPS configuration file"
	else
		create_config_from_template "${caddyfile_cleartext}" "Caddy HTTP configuration file"
	fi
}

#######################################
# Validate ZeroSSL EAB credentials if provided and modify Caddyfile as needed
#######################################
check_zerossl_eab() {
	if env_var_is_defined "ACME_EAB_KEY_ID" || env_var_is_defined "ACME_EAB_MAC_KEY"; then
		require_env_var "ACME_EAB_KEY_ID"
		require_env_var "ACME_EAB_MAC_KEY"

		# Use a heredoc to avoid accidental quoting/escaping issues and preserve formatting
		ACME_EAB_BLOCK=$(cat <<EOF
acme_ca https://acme.zerossl.com/v2/DV90
acme_eab {
	key_id ${ACME_EAB_KEY_ID}
	mac_key ${ACME_EAB_MAC_KEY}
}
EOF
)
		export ACME_EAB_BLOCK
	else
		export ACME_EAB_BLOCK=""
	fi
}

#######################################
# Validate the Cloudflare API Key if provided and modify Caddyfile as needed
#######################################
check_cloudflare_dns_api_key() {
    if env_var_is_defined "CF_API_TOKEN" ; then
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
    # shellcheck disable=SC2034  # Used via nameref in array_to_caddy_block
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
    # shellcheck disable=SC2034  # Used via nameref in array_to_caddy_block
    local minimal_headers=(
        "X-Frame-Options \"DENY\""
        "X-Content-Type-Options \"nosniff\""
    )
    
	# Note: For documentation on security headers, see:
	# - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
	# - https://owasp.org/www-project-secure-headers/
	
	# Helper function to convert array to multi-line string for Caddy config
	array_to_caddy_block() {
		local -n headers_array=${1}
		local result=""
		for header in "${headers_array[@]}"; do
			result+=$'\t\t\t'"${header}"$'\n'
		done
		echo "${result}"
	}
	
	# Convert arrays to multi-line strings for Caddy config with exact formatting
	local default_headers_string minimal_headers_string
	default_headers_string=$(array_to_caddy_block default_headers)
	minimal_headers_string=$(array_to_caddy_block minimal_headers)
	
	# Handle preset values
    local headers
    case "${SECURITY_HEADERS:-DEFAULT}" in
        "DEFAULT")
            headers="${default_headers_string}"
            ;;
        "MINIMAL")
            headers="${minimal_headers_string}"
            ;;
        "DISABLED")
            export SECURITY_HEADERS_BLOCK=""
            log_warn "Security headers have been explicitly disabled"
            return
            ;;
        *)
            headers="${SECURITY_HEADERS}"
            ;;
    esac
    
    # Basic validation: check if headers contain at least one valid header pattern
    if ! [[ "${headers}" =~ [A-Za-z-]+[[:space:]]+ ]]; then
        log_warn "Invalid header format detected, falling back to defaults"
        headers="${default_headers_string}"
    fi
    
    export SECURITY_HEADERS_BLOCK=$'\n\t\theader {\n'"${headers}"$'\t\t}'
}

#######################################
# Validate Caddy environment variables
#######################################
check_caddy_environment_variables() {
	configure_security_headers

	if env_var_is_defined "CADDY_FRONTEND" && [[ "${CADDY_FRONTEND}" = "DISABLE_HTTPS" ]]; then
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
		create_directory_if_not_exists "${dir}"
	done
}

#######################################
# Handle Noise private key
#######################################
reuse_or_create_noise_private_key() {
	local key_path="/data/noise_private.key"

	if [[ -f "${key_path}" ]]; then
		chmod 600 "${key_path}"
		return
	fi

	if env_var_is_defined "HEADSCALE_NOISE_PRIVATE_KEY"; then
	    printf '%s' "${HEADSCALE_NOISE_PRIVATE_KEY}" > "${key_path}"
        chmod 600 "${key_path}"
	else
		log_info "Generating new Noise private key - existing clients will need to re-authenticate"
	fi
}

#######################################
# Create our configuration files
#######################################
check_config_files() {
	check_headscale_environment_vars

	check_caddy_environment_variables

	# Ensure all template variables are exported for envsubst
	local template_vars=(
		"ACME_EAB_BLOCK"
		"CLOUDFLARE_ACME_BLOCK"
		"SECURITY_HEADERS_BLOCK"
		"PUBLIC_SERVER_URL"
		"PUBLIC_LISTEN_PORT"
		"HEADSCALE_DNS_BASE_DOMAIN"
		"HEADSCALE_OVERRIDE_LOCAL_DNS"
		"MAGIC_DNS"
		"IP_ALLOCATION"
		"HEADSCALE_EXTRA_RECORDS_PATH"
	)
	for var in "${template_vars[@]}"; do
		export "${var}=${!var}"
	done

	create_headscale_config

	create_caddyfile

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
	log_info "Server URL: ${PUBLIC_SERVER_URL}"
	log_info "Tailnet Base Domain: ${HEADSCALE_DNS_BASE_DOMAIN}"
	log_info "Public Listening Port: ${PUBLIC_LISTEN_PORT}"
	log_info "GOMAXPROCS: ${GOMAXPROCS}"

	log_feature_status "HTTPS Mode" "${https_enabled}" "" "warn"
	log_feature_status "Litestream" "${litestream_enabled}" "${LITESTREAM_REPLICA_URL}" "warn"
	log_feature_status "Magic DNS" "${MAGIC_DNS}"

	log_info "IP Allocation: ${IP_ALLOCATION}"
	if [[ "${IPV6_ONLY}" == "true" ]]; then
		log_feature_status "IPv6 Only" true ""
	else
		log_info "IPv4 Prefix: ${IPV4_PREFIX}"
	fi
	log_info "IPv6 Prefix: ${IPV6_PREFIX}"

	if env_var_is_defined "HEADSCALE_OIDC_ISSUER"; then
		log_feature_status "OIDC" true "${HEADSCALE_OIDC_ISSUER}"
		if env_var_is_defined "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT"; then
			log_feature_status "OIDC Domain Hint" true "${HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT}"
		else
			log_feature_status "OIDC Domain Hint" false ""
		fi
	fi

	if ${https_enabled}; then
		if env_var_is_defined "CF_API_TOKEN"; then
			log_info "DNS Challenge: Cloudflare"
		else
			log_info "DNS Challenge: HTTP-01"
		fi
		if env_var_is_defined "ACME_EAB_KEY_ID"; then
			log_feature_status "ACME EAB" true "ZeroSSL"
		else
			log_feature_status "ACME EAB" false "Let's Encrypt"
		fi
	fi

	if [[ -n "${SECURITY_HEADERS_BLOCK}" ]]; then
		log_feature_status "Security Headers" true "${SECURITY_HEADERS:-DEFAULT}"
	else
		log_feature_status "Security Headers" false "" "warn"
	fi

	log_info "=============================="
}

#######################################
# Start Caddy service
#######################################
start_caddy_service() {
	log_info "Starting Caddy using our environment variables."

	if ${https_enabled}; then
		caddy start --config "${caddyfile_https}" || {
			log_error "Failed to start Caddy with HTTPS config"
			return
		}
	else
		caddy start --config "${caddyfile_cleartext}" || {
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
	if ${litestream_enabled}; then
		log_info "Attempt to restore previous Headscale database if there's a replica"
		litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 ||
			log_warn "No replica found, or unable to restore database."

		log_info "Starting Headscale using Litestream and our Environment Variables..."
		exec litestream replicate -exec "headscale serve"
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

	if ${abort_config} ; then
		log_error "Configuration validation failed. Exiting."
		exit
	fi

	# Here we... here we... here we go!!!
	display_configuration_summary

	start_caddy_service

	start_headscale_service
}

helpers_dir="$(dirname "${BASH_SOURCE[0]}")"

for helper_script in "${helper_scripts[@]}"; do
    helper="${helpers_dir}/${helper_script}"
	if [[ -r "${helper}" ]]; then
		# shellcheck source=/dev/null
		source "${helper}"
	else
		echo "Missing helper file: ${helper}" >&2
		exit 1
	fi
done

run
