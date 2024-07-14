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

####
# Checks `$PUBLIC_LISTEN_PORT` is a valid port, or if unset defaults to `:443`
#
check_listen_port() {
	if [ -z "$PUBLIC_LISTEN_PORT" ]; then
		echo "INFO: Environment variable 'PUBLIC_LISTEN_PORT' is missing, defaulting to port 443"
		export PUBLIC_LISTEN_PORT=443
	else
		case "$PUBLIC_LISTEN_PORT" in
			'' | *[!0123456789]*) echo >&2 "ERROR: Environment variable 'PUBLIC_LISTEN_PORT' is not numeric."; abort_config=1;;
			0*[!0]*) echo >&2 "ERROR: Environment variable 'PUBLIC_LISTEN_PORT' has a leading zero."; abort_config=1;;
		esac

		if [ "$PUBLIC_LISTEN_PORT" -lt 1  ] || [ "$PUBLIC_LISTEN_PORT" -gt 65535 ] ; then
			echo "ERROR: Environment variable 'PUBLIC_LISTEN_PORT' must be a valid port within the range of 1-65535." >&2
			abort_config=1
		fi
	fi
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

	# abort if our listen port is invalid, or default to `:443` if it's unset
	check_listen_port

	check_env_var_populated "LITESTREAM_REPLICA_URL"
	if $? eq "0" ; then
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
	sed -i "s@\$PUBLIC_SERVER_URL@${PUBLIC_SERVER_URL}@" $headscale_config_path
	sed -i "s@\$PUBLIC_LISTEN_PORT@${PUBLIC_LISTEN_PORT}@" $headscale_config_path
	echo "INFO: Headscale configuration file created."

	if [ -z "$HEADSCALE_PRIVATE_KEY" ]; then
		echo "INFO: Headscale will generate a new private key."
	else
		echo "INFO: Using environment value for Headscale's private key."
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
check_needed_directories
DIRS_RETURN_CODE=$?
if [ "$DIRS_RETURN_CODE" -ne "0" ]; then
	echo "ERROR: Unable to create required configuration directories."
	export $abort_config=1
fi

check_config_files
CONFIGS_RETURN_CODE=$?
if [ "$CONFIGS_RETURN_CODE" -ne "0" ]; then
	echo "ERROR: We don't have enough information to run our services."
	export $abort_config=1
fi

if [ $abort_config -eq 0 ]; then
	echo "INFO: Starting Caddy using environment variables"
	caddy start --config "/etc/caddy/Caddyfile"

	echo "INFO: Attempt to restore previous Headscale database if there's a replica..."
	litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3
	
	echo "INFO: Starting Headscale using Litestream and our Environment Variables..."
	litestream replicate -exec 'headscale serve'
else
	echo "ERROR: Something went wrong. Exiting."
	return $abort_config
fi
