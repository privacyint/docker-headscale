#!/usr/bin/env bash

set -e

export abort_config=0

#######################################
# Check if an environment variable has been populated
# GLOBALS:
#   abort_config
# ARGUMENTS:
#   Variable to check
#   Optional: Required (if non-zero, on failure sets `abort_config` to this value)
# OUTPUTS:
#   Writes to STOUT if `$2` is 0, otherwise writes to SDERR
# RETURN:
#   1 if the variable is populated
#######################################
global_global_var_is_populated() {
    var="$1"
    required="$2"
	if [ -z "${!var}" ] && [ -n "${required-}" ] ; then
		echo "ERROR: Required environment variable '$var' is required." >&2
		abort_config="${required}"
		return 0
	fi
	echo "INFO: Environment variable '$var' is empty"
	return 1
}

#######################################
# Check a given environment variable is a "valid" port (1-65535)
# ARGUMENTS:
#   Variable to check
# RETURN:
#   `1` if it's considered valid, `0` on error.
#######################################
is_valid_port() {
    port="$1"
	case "${!port}" in
		'' | *[!0123456789]*) echo >&2 "ERROR: '$port' is not numeric."; return 0;;
		0*[!0]*) echo >&2 "ERROR: '$port' has a leading zero."; return 0;;
	esac

	if [ "${!port}" -lt 1  ] || [ "${!port}" -gt 65535 ] ; then
		echo "ERROR: '$port' must be a valid port within the range of 1-65535." >&2
		return 0
	fi

	return 1
}

####
# Checks our various environment variables are populated, and squirts them into their
# places, as required.
#
check_config_files() {
	local headscale_config_path=/etc/headscale/config.yaml
	local headscale_private_key_path=/data/private.key
	local headscale_noise_private_key_path=/data/noise_private.key

	echo "INFO: Checking required environment variables..."
	global_var_is_populated "PUBLIC_SERVER_URL" yes
	global_var_is_populated "HEADSCALE_DNS_CONFIG_BASE_DOMAIN" yes
	global_var_is_populated "CF_API_TOKEN" yes
	global_var_is_populated "HEADSCALE_OIDC_ISSUER" yes
	global_var_is_populated "HEADSCALE_OIDC_CLIENT_ID" yes
	global_var_is_populated "HEADSCALE_OIDC_CLIENT_SECRET" yes
	global_var_is_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT" yes

	# If `PUBLIC_LISTEN_PORT` is set it needs to be valid
	if global_var_is_populated "PUBLIC_LISTEN_PORT" ; then
		if ! is_valid_port "PUBLIC_LISTEN_PORT" ; then
			abort_config=1
		fi
	fi

	if global_var_is_populated "LITESTREAM_REPLICA_URL" ; then
		if [[ ${LITESTREAM_REPLICA_URL:0:5} == "s3://" ]] ; then
			echo "INFO: Litestream uses S3-Alike storage."
			global_var_is_populated "LITESTREAM_ACCESS_KEY_ID" yes
			global_var_is_populated "LITESTREAM_SECRET_ACCESS_KEY" yes
		elif [[ ${LITESTREAM_REPLICA_URL:0:6} == "abs://" ]] ; then
			echo "INFO: Litestream uses Azure Blob storage."
			global_var_is_populated "LITESTREAM_AZURE_ACCOUNT_KEY" yes
		else
			echo "ERROR: 'LITESTREAM_REPLICA_URL' must start with either 's3://' OR 'abs://'" >&2
			abort_config=1
		fi
	fi

	echo "INFO: Creating Headscale configuration file from environment variables."
	sed -i "s@\$PUBLIC_SERVER_URL@${PUBLIC_SERVER_URL}@" $headscale_config_path || abort_config=1
	sed -i "s@\$PUBLIC_LISTEN_PORT@${PUBLIC_LISTEN_PORT}@" $headscale_config_path || abort_config=1

	if [ -z "$HEADSCALE_PRIVATE_KEY" ]; then
		echo "INFO: Headscale will generate a new private DERP key."
	else
		echo "INFO: Using environment value for Headscale's private DERP key."
		echo -n "$HEADSCALE_PRIVATE_KEY" > $headscale_private_key_path
	fi

	if [ -z "$HEADSCALE_NOISE_PRIVATE_KEY" ]; then
		echo "INFO: Headscale will generate a new private noise key."
	else
		echo "INFO: Using environment value for our private noise key."
		echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > $headscale_noise_private_key_path
	fi

	return $abort_config
}

####
# Ensures our configuration directories exist
#
check_needed_directories() {
	mkdir -p /var/run/headscale
	mkdir -p /data
}

#---
# LOGIC STARTSHERE
#
if ! check_needed_directories ; then
	echo >&2 "ERROR: Unable to create required configuration directories."
	abort_config=1
fi

if ! check_config_files ; then
	echo >&2 "ERROR: We don't have enough information to run our services."
	abort_config=1
fi

if [ ${abort_config} -eq 0 ] ; then
	echo "INFO: Attempt to restore previous Caddy database if there's a replica" && \
	litestream restore -if-db-not-exists -if-replica-exists /data/caddy.sqlite3 && \
    \
	echo "INFO: Starting Caddy using Litestream and our environment variables" && \
	litestream replicate -exec 'caddy start --config "/etc/caddy/Caddyfile"' && \
    \
	echo "INFO: Attempt to restore previous Headscale database if there's a replica" && \
	litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3 && \
    \
	echo "INFO: Starting Headscale using Litestream and our Environment Variables..." && \
	litestream replicate -exec 'headscale serve'
else
	echo >&2 "ERROR: Something went wrong."
	if [ ! -z "$DEBUG" ] ; then
		echo "Sleeping so you can connect and debug"
		# Allow us to start a terminal in the container for debugging
		sleep infinity
	fi

	echo >&2 "Exiting with code ${abort_config}"
	exit $abort_config
fi
