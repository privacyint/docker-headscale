#!/usr/bin/env bash

set -e

export abort_config=0

####
# Takes the name of an environment variable as a string, sets `$abort_config` to `1`
# if it's unset (also spits out a hopefully useful message to `stderr`). Returns a status.
#
check_env_var_populated() {
    var="$1"
	if [ -z "${!var}" ]; then
		echo "ERROR: Required environment variable '$var' is missing." >&2
		abort_config=1
		return 1
	fi
	return 0
}

#######################################
# Check a given environment variable is a "valid" port (1-65535)
# ARGUMENTS:
#   Variable to check
# RETURN:
#   0 if it's considered valid, non-zero on error.
#######################################
check_is_valid_port() {
    port="$1"
	case "${!port}" in
		'' | *[!0123456789]*) echo >&2 "ERROR: '$port' is not numeric."; return 1;;
		0*[!0]*) echo >&2 "ERROR: '$port' has a leading zero."; return 1;;
	esac

	if [ "${!port}" -lt 1  ] || [ "${!port}" -gt 65535 ] ; then
		echo "ERROR: '$port' must be a valid port within the range of 1-65535." >&2
		return 1
	fi

	return 0
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
	# abort if needed variables are missing
	check_env_var_populated "PUBLIC_SERVER_URL"
	check_env_var_populated "HEADSCALE_DNS_CONFIG_BASE_DOMAIN"
	check_env_var_populated "CF_API_TOKEN"
	check_env_var_populated "HEADSCALE_OIDC_ISSUER"
	check_env_var_populated "HEADSCALE_OIDC_CLIENT_ID"
	check_env_var_populated "HEADSCALE_OIDC_CLIENT_SECRET"
	check_env_var_populated "HEADSCALE_OIDC_EXTRA_PARAMS_DOMAIN_HINT"

	# If `PUBLIC_LISTEN_PORT` is set it needs to be valid
	if check_env_var_populated "PUBLIC_LISTEN_PORT" -eq "0" ; then
		if check_is_valid_port "PUBLIC_LISTEN_PORT" -ne "0" ; then
			abort_config=1
		fi
	fi

	if check_env_var_populated "LITESTREAM_REPLICA_URL" -eq "0" ; then
		if [[ ${LITESTREAM_REPLICA_URL:0:5} == "s3://" ]] ; then
			echo "INFO: Litestream uses S3-Alike storage."
			check_env_var_populated "LITESTREAM_ACCESS_KEY_ID"
			check_env_var_populated "LITESTREAM_SECRET_ACCESS_KEY"
		elif [[ ${LITESTREAM_REPLICA_URL:0:6} == "abs://" ]] ; then
			echo "INFO: Litestream uses Azure Blob storage."
			check_env_var_populated "LITESTREAM_AZURE_ACCOUNT_KEY"
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
