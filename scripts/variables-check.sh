#!/bin/bash

#######################################
# Check if an environment variable is defined. This explicitly includes `null` and `empty string`.
# Arguments:
#   $1 - Variable name
# Returns:
#   `true` if defined, otherwise `false`
#######################################
env_var_is_defined() {
	# Only allow variable names with letters, numbers, and underscores, not starting with a number
	if ! [[ "${1}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
		log_error "Invalid environment variable name: '${1}'"
		return
	fi

	# Consider a variable defined if it is set in the environment, even if the value is an empty string.
	# ${param+word} expands to 'word' when the parameter is set (even if null), otherwise empty.
	[[ "${!1+set}" == "set" ]]
}

#######################################
# Check if an environment variable is populated with a non-empty value.
# Arguments:
#   $1 - Variable name
# Returns:
#   `true` if populated, otherwise `false`
#######################################
env_var_is_populated() {
	# Reuse variable name validation and unset handling from env_var_is_defined.
	env_var_is_defined "${1}" && [[ -n "${!1}" ]]
}

#######################################
# Ensure an environment variable is populated
# Arguments:
#   $1 - Variable name
# Returns:
#   `true` if populated, otherwise `false`
#######################################
require_env_var() {
	env_var_is_defined "${1}" || log_error "Environment variable '${1}' is required"
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
	local var_name="${1}"
	local default_value="${2}"
	local pattern="${3:-}"
	local error_msg="${4:-}"
	
	# Set default value if variable is not populated
	if ! env_var_is_defined "${var_name}"; then
		export "${var_name}"="${default_value}"
	fi
	
	# Validate with regex if pattern provided
	if [[ -n "${pattern}" && ! "${!var_name}" =~ ${pattern} ]]; then
		log_error "${error_msg:-"Invalid '${var_name}' value: '${!var_name}'"}"
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
    local port="${1}"

    # Make sure our port is numeric
    if ! [[ "${!port}" =~ ^[0-9]+$ ]]; then
        log_error "Port '${port}' is not numeric."
    fi

    # Check no leading zeros (except for port '0')
    if [[ "${!port}" =~ ^0[0-9]+$ ]]; then
        log_error "Port '${port}' has a leading zero."
    fi

    # Check port is within valid range
    if [[ "${!port}" -lt 1 ]] || [[ "${!port}" -gt 65535 ]]; then
        log_error "Port '${port}' must be a valid port within the range of 1-65535."
    fi
}
