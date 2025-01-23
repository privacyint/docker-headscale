#!/usr/bin/env bash

set -e

abort_config=false
litestream_deliberately_disabled=false
caddy_deliberately_disabled=false

#######################################
# Echo out an INFO message
# ARGUMENTS:
#   Message
# OUTPUTS:
#   Message to `STDOUT`
#######################################
info_out() {
	echo "INFO: $1"
}

#######################################
# Echo out an ERROR message
# GLOBALS:
#   `abort_config` is set to `true`
# ARGUMENTS:
#   Message
# OUTPUTS:
#   Message to `STDERR`
# RETURNS:
#   `false`
#######################################
error_out() {
	echo >&2 "ERROR: $1"
	abort_config=true
	false
}

#######################################
# Check if an environment variable has been populated
# ARGUMENTS:
#   Variable to check
# OUTPUTS:
#   Writes to STDERR on failure
# RETURN:
#   `0` if the variable is populated, otherwise `false`
#######################################
global_var_is_populated() {
	var="$1"
	
	[ -n "${!var}" ] && return
	
	false
}

#######################################
# Check if a required environment variable has been populated, otherwise set
# `abort_config` to non-zero
# GLOBALS:
#   abort_config
# ARGUMENTS:
#   Variable to check
# OUTPUTS:
#   Writes to STDERR on failure
# RETURN:
#   `0` if the variable is populated, otherwise `false`
#######################################
required_global_var_is_populated() {
	var="$1"
	
	global_var_is_populated "$var" &>/dev/null && return
	
	error_out "Environment variable '$var' is required"
}

#######################################
# Check a given environment variable is a "valid" port (1-65535)
# ARGUMENTS:
#   Variable to check
# OUTPUTS:
#   Uses `error_out()` on failure
# RETURN:
#   `0` if it's considered valid, `false` on error.
#######################################
check_is_valid_port() {
	port="$1"
	case "${!port}" in
		'' | *[!0123456789]*) error_out "'$port' is not numeric." && return ;;
		0*[!0]*) error_out "'$port' has a leading zero." && return ;;
	esac

	if [ "${!port}" -lt 1  ] || [ "${!port}" -gt 65535 ] ; then
		error_out "'$port' must be a valid port within the range of 1-65535." && return
	fi
}

#######################################
# Checks whether `PUBLIC_LISTEN_PORT` is set and a "valid" port (1-65535)
# otherwise defaults to `PUBLIC_LISTEN_PORT` to `443`
#######################################
check_public_listen_port() {
	# If `PUBLIC_LISTEN_PORT` is set it needs to be valid
	if global_var_is_populated "PUBLIC_LISTEN_PORT" ; then
		check_is_valid_port "PUBLIC_LISTEN_PORT"
	else
		export PUBLIC_LISTEN_PORT=443
	fi
}

#######################################
# Checks `LITESTREAM_REPLICA_URL`
#######################################
check_litestream_replica_url() {
	if ! required_global_var_is_populated "LITESTREAM_REPLICA_URL" ; then
		error_out "'LITESTREAM_REPLICA_URL' must be populated"
		return
	fi		

	if [ "${LITESTREAM_REPLICA_URL}" = "DISABLED_I_KNOW_WHAT_IM_DOING" ] ; then
		info_out "This server is very deliberately ephemeral."
		litestream_deliberately_disabled=true
		return
	fi

	if [[ ${LITESTREAM_REPLICA_URL:0:5} == "s3://" ]] ; then
		info_out "Litestream uses S3-Alike storage."
		required_global_var_is_populated "LITESTREAM_ACCESS_KEY_ID"
		required_global_var_is_populated "LITESTREAM_SECRET_ACCESS_KEY"
	elif [[ ${LITESTREAM_REPLICA_URL:0:6} == "abs://" ]] ; then
		info_out "Litestream uses Azure Blob storage."
		required_global_var_is_populated "LITESTREAM_AZURE_ACCOUNT_KEY"
	else
		error_out "'LITESTREAM_REPLICA_URL' must start with either 's3://' OR 'abs://', or deliberately disabled by setting to 'DISABLED_I_KNOW_WHAT_IM_DOING'"
	fi
}

#######################################
# Checks our OIDC settings are in order, if set
#######################################
check_oidc_settings() {
	if global_var_is_populated "HEADSCALE_OIDC_ISSUER" ; then
		info_out "We're using OIDC issuance from '$HEADSCALE_OIDC_ISSUER'"
		required_global_var_is_populated "HEADSCALE_OIDC_CLIENT_ID"
		required_global_var_is_populated "HEADSCALE_OIDC_CLIENT_SECRET"
		global_var_is_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT" # Useful, not required
	fi
}

#######################################
# Check if we're using custom prefixes, or default
#######################################
check_ip_prefixes() {
	if ! global_var_is_populated "IPV6_PREFIX" ; then
		export IPV6_PREFIX="fd7a:115c:a1e0::/48"
	fi
	if ! global_var_is_populated "IPV4_PREFIX" ; then
		export IPV4_PREFIX="100.64.0.0/10"
	fi

	info_out "Using '$IPV6_PREFIX' and '$IPV4_PREFIX' as our subnets"
}

#######################################
# Check the require environment variables to start headscale
#######################################
check_headscale_env_vars() {
	required_global_var_is_populated "PUBLIC_SERVER_URL"
	required_global_var_is_populated "HEADSCALE_DNS_CONFIG_BASE_DOMAIN"
}

#######################################
# Run the various environment vars checks
#######################################
check_required_environment_vars() {
	info_out "Checking required environment variables..."
	check_public_listen_port
	check_litestream_replica_url
	check_oidc_settings
	check_ip_prefixes
	check_headscale_env_vars
}

create_headscale_config_from_environment_vars() {
	local headscale_config_path=/etc/headscale/config.yaml

	info_out "Creating Headscale configuration file from environment variables."

	sed -i "s@\$PUBLIC_SERVER_URL@${PUBLIC_SERVER_URL}@" $headscale_config_path || abort_config=1
	sed -i "s@\$PUBLIC_LISTEN_PORT@${PUBLIC_LISTEN_PORT}@" $headscale_config_path || abort_config=1
	sed -i "s@\$IPV6_PREFIX@${IPV6_PREFIX}@" $headscale_config_path || abort_config=1
	sed -i "s@\$IPV4_PREFIX@${IPV4_PREFIX}@" $headscale_config_path || abort_config=1
	sed -i "s@\$HEADSCALE_DNS_CONFIG_BASE_DOMAIN@${HEADSCALE_DNS_CONFIG_BASE_DOMAIN}@" $headscale_config_path || abort_config=1
}

reuse_or_create_noise_private_key() {
	local headscale_noise_private_key_path=/data/noise_private.key

	if [ -z "$HEADSCALE_NOISE_PRIVATE_KEY" ]; then
		info_out "Headscale will generate a new private noise key."
	else
		info_out "Using environment value for our private noise key."
		echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > $headscale_noise_private_key_path
	fi
}

check_caddy_specific_environment_variables() {
	local caddyfile=/etc/caddy/Caddyfile 

	if global_var_is_populated "CADDY_FRONTEND" ; then
		[ "${CADDY_FRONTEND}" = "DISABLED_I_KNOW_WHAT_IM_DOING" ] && caddy_deliberately_disabled=true
		return
	fi

	required_global_var_is_populated "CF_API_TOKEN"
	required_global_var_is_populated "ACME_ISSUANCE_EMAIL"

	if global_var_is_populated "ACME_EAB_KEY_ID" || global_var_is_populated "ACME_EAB_MAC_KEY"; then
		info_out "We're using ACME EAB credentials. Check they're both populated."
		required_global_var_is_populated "ACME_EAB_KEY_ID"
		required_global_var_is_populated "ACME_EAB_MAC_KEY"

		sed -iz "s@<<EAB>>@" \
			"acme_ca https://acme.zerossl.com/v2/DV90\n" \
			"acme_eab {\n" \
			"    key_id ${ACME_EAB_KEY_ID}\n" \
			"    mac_key ${ACME_EAB_MAC_KEY}\n" \
			" }@" $caddyfile || abort_config=1
	else
		info_out "No ACME EAB credentials provided"
		sed -i "s@<<EAB>>@@" $caddyfile || abort_config=1
	fi
}

####
# Checks our various environment variables are populated, and squirts them into their
# places, as required.
#
check_config_files() {
	check_required_environment_vars

	create_headscale_config_from_environment_vars

	reuse_or_create_noise_private_key

	check_caddy_specific_environment_variables
}

####
# Ensures our configuration directories exist
#
check_needed_directories() {
	mkdir -p /var/run/headscale || return
	mkdir -p /data/headscale || return
	mkdir -p /data/caddy || return
}

#---
# LOGIC STARTSHERE
#
run() {
	check_needed_directories || error_out "Unable to create required configuration directories."

	check_config_files || error_out "We don't have enough information to run our services."

	if ! $abort_config ; then
		if ! $caddy_deliberately_disabled ; then
			info_out "Starting Caddy using our environment variables" && \
			caddy start --config "/etc/caddy/Caddyfile"
		fi

		if ! $litestream_deliberately_disabled ; then
			info_out "Attempt to restore previous Headscale database if there's a replica" && \
			litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 && \
			\
			info_out "Starting Headscale using Litestream and our Environment Variables..." && \
			litestream replicate -exec 'headscale serve'
		else
			headscale serve
		fi

		return
	fi

	error_out "Something went wrong."
	if [ -n "$DEBUG" ] ; then
		info_out "Sleeping so you can connect and debug"
		# Allow us to start a terminal in the container for debugging
		sleep infinity
	fi

	error_out "Exiting with code ${abort_config}"
	exit "$abort_config"
}

run
