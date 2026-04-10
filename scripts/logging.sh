#!/bin/bash

# shellcheck disable=SC2034 # This is a helper file

#######################################
# Log with different levels
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message to log
#######################################
log_with_level() {
    local level="${1}"
    local message="${2}"
    local timestamp;

    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "${level^^}" in
        ERROR)
            echo "[${timestamp}] ERROR: ${message}" >&2
            ;;
        WARN)
            echo "[${timestamp}] WARN: ${message}" >&2
            ;;
        *)
            echo "[${timestamp}] INFO: ${message}"
            ;;
    esac
}

#######################################
# Log an informational message
# Arguments:
#   `$1` - Message to log
#######################################
log_info() {
    log_with_level "INFO" "${1}"
}

#######################################
# Log a warning message
# Arguments:
#   `$1` - Message to log
#######################################
log_warn() {
    log_with_level "WARN" "${1}"
}

#######################################
# Log an error message
# Arguments:
#   `$1` - Message to log
# Returns:
#   `false`
#######################################
log_error() {
    log_with_level "ERROR" "${1}"
    false
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
	local feature="${1}"
	local condition="${2}"
	local extra_info="${3:-}"
	local warn_on_false="${4:-}"
	
	if ${condition}; then
		log_info "${feature}: enabled${extra_info:+ (${extra_info})}"
	else
		if [[ "${warn_on_false}" == "warn" ]]; then
			log_warn "${feature}: disabled"
		else
			log_info "${feature}: disabled"
		fi
	fi
}
