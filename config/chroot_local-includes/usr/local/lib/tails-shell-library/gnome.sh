# shellcheck shell=dash
GNOME_ENV_VARS="
DBUS_SESSION_BUS_ADDRESS
DISPLAY
LANG
XAUTHORITY
XDG_RUNTIME_DIR
XDG_CURRENT_DESKTOP
"

export_gnome_env() {
    local tmp_env_file
    tmp_env_file="$(mktemp)"
    local vars
    # shellcheck disable=SC2086
    vars="($(echo ${GNOME_ENV_VARS} | tr ' ' '|'))"
    tr '\0' '\n' < "/run/gnome-shell-environment/environ" | \
        grep -E "^${vars}=" > "${tmp_env_file}"
    # shellcheck disable=SC2163
    while read -r line; do export "${line}"; done < "${tmp_env_file}"
    rm "${tmp_env_file}"
}
