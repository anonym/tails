# shellcheck shell=sh
GNOME_ENV_VARS="
DBUS_SESSION_BUS_ADDRESS
DISPLAY
LANG
XAUTHORITY
XDG_RUNTIME_DIR
XDG_CURRENT_DESKTOP
"

export_gnome_env() {
    # Get LIVE_USERNAME
    . /etc/live/config.d/username.conf
    local gnome_shell_pid

    # since POSIX shell doesn't have arrays, let's use argv as a "pgrepOpts" array
    set --
    # --ns only works if we are root
    [ "$(id -u)" = 0 ] && set -- --ns 1 --nslist mnt

    #shellcheck disable=SC2086
    gnome_shell_pid="$(pgrep --newest --euid "${LIVE_USERNAME}" \
            --full --exact /usr/bin/gnome-shell \
             "$@" )"
    set --

    if [ -z "${gnome_shell_pid}" ]; then
        return
    fi
    local tmp_env_file
    tmp_env_file="$(mktemp)"
    local vars
    # shellcheck disable=SC2086
    vars="($(echo ${GNOME_ENV_VARS} | tr ' ' '|'))"
    tr '\0' '\n' < "/proc/${gnome_shell_pid}/environ" | \
        grep -E "^${vars}=" > "${tmp_env_file}"
    # shellcheck disable=SC2163
    while read -r line; do export "${line}"; done < "${tmp_env_file}"
    rm "${tmp_env_file}"
}
