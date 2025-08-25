#!/bin/bash

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
# Log an error message and set abort flag
# Arguments:
#   `$1` - Message to log
# Globals:
#   `abort_config`
# Returns:
#   `false`
#######################################
log_error() {
    log_with_level "ERROR" "${1}"
    # Ensure caller can rely on abort_config being set; the main script defines it but
    # if not present yet this will create it in the current shell environment.
    abort_config=true
    false
}
