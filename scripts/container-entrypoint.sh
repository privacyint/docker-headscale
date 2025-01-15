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

####
# Checks our various environment variables are populated, and squirts them into their
# places, as required.
#
check_config_files() {
	local headscale_config_path=/etc/headscale/config.yaml
	local headscale_noise_private_key_path=/data/noise_private.key

	info_out "Checking required environment variables..."

	# If `PUBLIC_LISTEN_PORT` is set it needs to be valid
	if global_var_is_populated "PUBLIC_LISTEN_PORT" ; then
		check_is_valid_port "PUBLIC_LISTEN_PORT"
	else
		export PUBLIC_LISTEN_PORT=443
	fi

	if global_var_is_populated "LITESTREAM_REPLICA_URL" ; then
		if [ "${LITESTREAM_REPLICA_URL}" = "DISABLED_I_KNOW_WHAT_IM_DOING" ] ; then
			info_out "This server is very deliberately ephemeral."
			litestream_deliberately_disabled=true
		else
			if required_global_var_is_populated "LITESTREAM_REPLICA_URL" ; then
				if [[ ${LITESTREAM_REPLICA_URL:0:5} == "s3://" ]] ; then
					info_out "Litestream uses S3-Alike storage."
					required_global_var_is_populated "LITESTREAM_ACCESS_KEY_ID"
					required_global_var_is_populated "LITESTREAM_SECRET_ACCESS_KEY"
				elif [[ ${LITESTREAM_REPLICA_URL:0:6} == "abs://" ]] ; then
					info_out "Litestream uses Azure Blob storage."
					required_global_var_is_populated "LITESTREAM_AZURE_ACCOUNT_KEY"
				else
					error_out "'LITESTREAM_REPLICA_URL' must start with either 's3://' OR 'abs://'"
				fi
			fi
		fi
	fi

	if global_var_is_populated "HEADSCALE_OIDC_ISSUER" ; then
		info_out "We're using OIDC issuance from '$HEADSCALE_OIDC_ISSUER'"
		required_global_var_is_populated "HEADSCALE_OIDC_CLIENT_ID"
		required_global_var_is_populated "HEADSCALE_OIDC_CLIENT_SECRET"
		global_var_is_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT" # Useful, not required
	fi

	if ! global_var_is_populated "IPV6_PREFIX" ; then
		export IPV6_PREFIX="fd7a:115c:a1e0::/48"
	fi
	if ! global_var_is_populated "IPV4_PREFIX" ; then
		export IPV4_PREFIX="100.64.0.0/10"
	fi
	
	info_out "Using '$IPV6_PREFIX' and '$IPV4_PREFIX' as our subnets"

	required_global_var_is_populated "PUBLIC_SERVER_URL"
	required_global_var_is_populated "HEADSCALE_DNS_CONFIG_BASE_DOMAIN"
	info_out "Creating Headscale configuration file from environment variables."
	sed -i "s@\$PUBLIC_SERVER_URL@${PUBLIC_SERVER_URL}@" $headscale_config_path || abort_config=1
	sed -i "s@\$PUBLIC_LISTEN_PORT@${PUBLIC_LISTEN_PORT}@" $headscale_config_path || abort_config=1
	sed -i "s@\$IPV6_PREFIX@${IPV6_PREFIX}@" $headscale_config_path || abort_config=1
	sed -i "s@\$IPV4_PREFIX@${IPV4_PREFIX}@" $headscale_config_path || abort_config=1

	if [ -z "$HEADSCALE_NOISE_PRIVATE_KEY" ]; then
		info_out "Headscale will generate a new private noise key."
	else
		info_out "Using environment value for our private noise key."
		echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > $headscale_noise_private_key_path
	fi

	if global_var_is_populated "CADDY_FRONTEND" ; then
		[ "${CADDY_FRONTEND}" = "DISABLED_I_KNOW_WHAT_IM_DOING" ] && caddy_deliberately_disabled=true
	else
		required_global_var_is_populated "CF_API_TOKEN"
	fi
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
