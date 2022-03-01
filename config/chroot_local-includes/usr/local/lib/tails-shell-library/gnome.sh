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
    # This is a useful hardening: this function is used in some security-sensitive context (tca-portal),
    # so we'd better be really sure we're getting the real process.
    # In particular, Tor Browser is _not_ in the main mount namespace, so this would exclude any of its
    # children from being matched.
    # While this helps, this option is still racy: the namespace is check after having retrieved the PID, so
    # it might be possible for an attacker that is not in the right namespace to fool us and circumvent this.
    # see https://gitlab.tails.boum.org/tails/tails/-/issues/18374
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
