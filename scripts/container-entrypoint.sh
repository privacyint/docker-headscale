#!/usr/bin/env sh

set -e

export abort_config=0

check_env_var() {
    var="$1"
	if [ -z "${!var}" ]; then
		echo "ERROR: Required environment variable '$var' is missing." >&2
		abort_config=1
	fi
}

check_listen_port() {
	if [ -z "$HEADSCALE_LISTEN_PORT" ]; then
		echo "INFO: Environment variable 'HEADSCALE_LISTEN_PORT' is missing, defaulting to port 443"
		HEADSCALE_LISTEN_PORT=443
	else
		case "$HEADSCALE_LISTEN_PORT" in
			'' | *[!0123456789]*) echo >&2 "ERROR: Environment variable 'HEADSCALE_LISTEN_PORT' is not numeric."; abort_config=1;;
			0*[!0]*) echo >&2 "ERROR: Environment variable 'HEADSCALE_LISTEN_PORT' has a leading zero."; abort_config=1;;
		esac

		if [ "$HEADSCALE_LISTEN_PORT" -lt 1  ] || [ "$HEADSCALE_LISTEN_PORT" -gt 65535 ] ]; then
			echo "ERROR: Environment variable 'HEADSCALE_LISTEN_PORT' must be a valid port within the range of 1-65535." >&2
			abort_config=1
		fi
	fi
}

check_data_directory() {
	mkdir -p /data
}

check_config_files() {
	local headscale_config_path=/etc/headscale/config.yaml
	local headscale_private_key_path=/data/private.key
	local headscale_noise_private_key_path=/data/noise_private.key

	echo "INFO: Creating our Headscale config using environment variables..."
	# abort if needed variables are missing
	check_env_var "HEADSCALE_SERVER_URL"
	check_env_var "HEADSCALE_BASE_DOMAIN"
	check_env_var "AZURE_BLOB_ACCOUNT_NAME"
	check_env_var "AZURE_BLOB_BUCKET_NAME"
	check_env_var "AZURE_BLOB_ACCESS_KEY"
	check_env_var "AZURE_DNS_SUBSCRIPTION_ID"
	check_env_var "AZURE_DNS_RESOURCE_GROUP_NAME"

	# abort if our listen port is invalid, or default to `:443` if it's unset
	check_listen_port ${HEADSCALE_LISTEN_PORT}

	if [ $abort_config -eq 0 ]; then
		sed -i "s@\$HEADSCALE_BASE_DOMAIN@$HEADSCALE_BASE_DOMAIN@" $headscale_config_path
		echo "INFO: Headscale configuration file created."
	else
		return $abort_config
	fi

	if [ ! -f $headscale_private_key_path ]; then
		if [ ! -z "$HEADSCALE_PRIVATE_KEY" ]; then
			echo -n "$HEADSCALE_PRIVATE_KEY" > $headscale_private_key_path
		fi
	fi

	if [ ! -f $headscale_noise_private_key_path ]; then
		if [ ! -z "$HEADSCALE_NOISE_PRIVATE_KEY" ]; then
			echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > $headscale_noise_private_key_path
		fi
	fi
}

check_socket_directory() {
	mkdir -p /var/run/headscale
}

if ! check_data_directory; then
	exit 1
fi

if ! check_config_files; then
	exit 1
fi

if ! check_socket_directory; then
	exit 1
fi

echo "INFO: Attempt to restore previous Headscale database if there's a replica..."
litestream restore -if-db-not-exists -if-replica-exists /data/headscale.sqlite3

echo "INFO: Starting Headscale using Litestream..."
exec litestream replicate -exec 'headscale serve'
