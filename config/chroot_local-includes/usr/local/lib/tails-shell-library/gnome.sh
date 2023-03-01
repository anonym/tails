# shellcheck shell=dash
GNOME_ENV_VARS="
DBUS_SESSION_BUS_ADDRESS
LANG
XDG_RUNTIME_DIR
XDG_CURRENT_DESKTOP
"

GNOME_ENV_FILE=/run/user/1000/gnome-env

gnome_env() {
  if [ -f "${GNOME_ENV_FILE}" ]; then
    xargs -0 -L1 -a "${GNOME_ENV_FILE}"
  fi
}

export_gnome_env() {
    local tmp_env_file
    tmp_env_file="$(mktemp)"
    local vars
    gnome_env > "${tmp_env_file}"
    # shellcheck disable=SC2163
    while read -r line; do
      if [ -n "${line}" ]; then
        export "${line}"
      fi
    done < "${tmp_env_file}"
    rm "${tmp_env_file}"
}
