#!/bin/bash

#######################################
# Generic configuration file creator with template substitution
# Arguments:
#   $1 - Target config file path
#   $2 - Description for logging
#   $3 - File permissions (optional, defaults to 600)
#######################################
create_config_from_template() {
    local config_path="${1}"
    local description="${2}"
    local permissions="${3:-600}"
    local temp_config_path
    
    temp_config_path=$(mktemp) || {
        log_error "Unable to create temporary file for ${description}"
		return
    }

    if envsubst < "${config_path}" > "${temp_config_path}"; then
        chmod "${permissions}" "${temp_config_path}"
        if mv "${temp_config_path}" "${config_path}"; then
            return
        else
            log_error "Unable to move ${description} to final location"
            rm -f "${temp_config_path}"
        fi
    else
        log_error "Unable to generate ${description}"
        rm -f "${temp_config_path}"
    fi

	return
}

########################################
# Create a directory if it doesn't exist
# Arguments:
#   $1 - Directory path
# Side Effects:
#   Calls log_error and sets abort_config=true on failure
########################################
create_directory_if_not_exists() {
	local dir="${1}"
	if [[ ! -d "${dir}" ]]; then
		mkdir -p "${dir}" || log_error "Unable to create directory '${dir}'."
	fi
}
