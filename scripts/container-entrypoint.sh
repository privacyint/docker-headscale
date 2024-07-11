#!/usr/bin/env sh

set -e

export abort_config=0

####
# Takes the name of an environment variable as a string, sets `$abort_config` to `1`
# if it's unset (also spits out a hopefully useful message to `stderr`)
#
check_env_var_populated() {
    var="$1"
	if [ -z "${!var}" ]; then
		echo "ERROR: Required environment variable '$var' is missing." >&2
		abort_config=1
	fi
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

		if [ "$PUBLIC_LISTEN_PORT" -lt 1  ] || [ "$PUBLIC_LISTEN_PORT" -gt 65535 ] ]; then
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
	local caddy_config_path=/etc/caddy/Caddyfile
	local headscale_config_path=/etc/headscale/config.yaml
	local headscale_private_key_path=/data/private.key
	local headscale_noise_private_key_path=/data/noise_private.key

	echo "INFO: Checking required environment variables..."
	# abort if needed variables are missing
	check_env_var_populated "PUBLIC_SERVER_URL"
	check_env_var_populated "HEADSCALE_BASE_DOMAIN"
	check_env_var_populated "AZURE_BLOB_ACCOUNT_NAME"
	check_env_var_populated "AZURE_BLOB_BUCKET_NAME"
	check_env_var_populated "AZURE_BLOB_ACCESS_KEY"
	check_env_var_populated "CF_API_TOKEN"

	# abort if our listen port is invalid, or default to `:443` if it's unset
	check_listen_port

	echo "INFO: Creating Headscale configuration file from environment variables."
	sed -i "s@\$PUBLIC_SERVER_URL@$PUBLIC_SERVER_URL@" $headscale_config_path
	sed -i "s@\$PUBLIC_LISTEN_PORT@$PUBLIC_LISTEN_PORT@" $headscale_config_path
	echo "INFO: Headscale configuration file created."

	echo "INFO: Creating Caddy configuration file from environment variables."
	sed -i "s@\$PUBLIC_SERVER_URL@$PUBLIC_SERVER_URL@" $caddy_config_path
	sed -i "s@\$PUBLIC_LISTEN_PORT@$PUBLIC_LISTEN_PORT@" $caddy_config_path
	echo "INFO: Caddy configuration file created."

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
if [ ! check_needed_directories ]; then
	echo "ERROR: Unable to create required configuration directories."
	$abort_config=1
fi

if [ ! check_config_files ]; then
	echo "ERROR: We don't have enough information to run our services."
	$abort_config=1
fi

if [ $abort_config -eq 0 ]; then
	echo "INFO: Attempt to restore previous Headscale database if there's a replica..."
	litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3
	
	echo "INFO: Starting Headscale using Litestream and our Environment Variables..."
	litestream replicate -exec 'headscale serve' &

	echo "INFO: Starting Caddy"
	caddy start --config /etc/caddy/Caddyfile
else
	echo "ERROR: Something went wrong. Exiting."
	return $abort_config
fi
