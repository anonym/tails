# shellcheck shell=dash
GNOME_ENV_VARS="
DBUS_SESSION_BUS_ADDRESS
LANG
XDG_RUNTIME_DIR
XDG_CURRENT_DESKTOP
"

GNOME_SHELL_ENV_FILE=/run/gnome-shell-environment/environ

gnome_env() {
  local vars

  if [ -f "${GNOME_SHELL_ENV_FILE}" ]; then
    # shellcheck disable=SC2086
    vars=$(tr '\0' '\n' < "${GNOME_SHELL_ENV_FILE}" | \
           grep -E "^($(echo ${GNOME_ENV_VARS} | tr ' ' '|'))=")
  fi

  if ! echo "${vars}" | grep -E "^DISPLAY="; then
    vars="${vars}
DISPLAY=:0"
  fi

  if ! echo "${vars}" | grep -E "^XAUTHORITY="; then
    for xauth in /run/user/1000/.mutter-Xwaylandauth.*; do
      vars="${vars}
XAUTHORITY=${xauth}"
      break
    done
  fi

  if ! echo "${vars}" | grep -E "^WAYLAND_DISPLAY="; then
    for wayland_display in /run/user/1000/wayland-*; do
      vars="${vars}
WAYLAND_DISPLAY=${wayland_display#/run/user/1000/}"
      break
    done
  fi

  echo "${vars}"
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
