#!/bin/sh

TBB_INSTALL=/usr/local/lib/tor-browser
# shellcheck disable=SC2034
TBB_PROFILE=/etc/tor-browser/profile
# shellcheck disable=SC2034
TBB_EXT=/usr/local/share/tor-browser-extensions

# For strings it's up to the caller to add double-quotes ("") around
# the value.
set_mozilla_pref() {
    local file name value prefix
    file="${1}"
    name="${2}"
    value="${3}"
    # Sometimes we might want to do e.g. user_pref
    prefix="${4:-pref}"
    [ -e "${file}" ] && sed -i "/^${prefix}(\"${name}\",/d" "${file}"
    echo "${prefix}(\"${name}\", ${value});" >> "${file}"
}

exec_firefox_helper() {
    local binary="${1}"; shift

    export LD_LIBRARY_PATH="${TBB_INSTALL}"
    export FONTCONFIG_PATH="${TBB_INSTALL}/TorBrowser/Data/fontconfig"
    export FONTCONFIG_FILE="fonts.conf"
    export GNOME_ACCESSIBILITY=1

    # Don't let Tor Browser manage the tor daemon: we do it ourselves.
    export TOR_SKIP_LAUNCH=1
    # New in 9.5: Avoid overwriting user's dconf values. Fixes #27903.
    export GSETTINGS_BACKEND=memory

    # The Tor Browser often assumes that the current directory is
    # where the browser lives, e.g. for the fixed set of fonts set by
    # fontconfig above.
    cd "${TBB_INSTALL}"

    # From start-browser:
    unset SESSION_MANAGER

    exec "${TBB_INSTALL}"/"${binary}" "${@}"
}

exec_firefox() {
    exec_firefox_helper firefox.real "${@}"
}

guess_best_tor_browser_locale() {
    local long_locale short_locale similar_locale
    long_locale="$(echo "${LANG}" | sed -e 's/\..*$//' -e 's/_/-/')"
    short_locale="$(echo "${long_locale}" | cut -d"-" -f1)"
    if locale_is_supported_by_tor_browser "$long_locale"; then
        echo "${long_locale}"
        return
    elif locale_is_supported_by_tor_browser "$short_locale"; then
        echo "${short_locale}"
        return
    fi
    # If we use locale xx-YY and Tor Browser supports neither xx-YY nor xx,
    # there may be a similar locale xx-ZZ that we should use instead.
    # shellcheck disable=SC2012
    similar_locale=$(
        supported_tor_browser_locales | \
	    grep --max-count=1 --extended-regexp --line-regexp \
		 "${short_locale}-[A-Z]+" \
    ) || :
    if [ -n "${similar_locale:-}" ]; then
        echo "${similar_locale}"
        return
    fi

    echo 'en-US'
}

configure_best_tor_browser_locale() {
    local profile best_locale
    profile="${1}"
    best_locale="$(guess_best_tor_browser_locale)"
    cat "/etc/tor-browser/locale-profiles/${best_locale}.js" \
        >> "${profile}/prefs.js"
}

supported_tor_browser_locales() {
    7z e -tzip -- "${TBB_INSTALL}/omni.ja" res/multilocale.txt >/dev/null
    tr ',' "\n" < multilocale.txt
    rm multilocale.txt
}

locale_is_supported_by_tor_browser() {
    local mozilla_locale
    mozilla_locale="${1}"

    supported_tor_browser_locales \
        | grep --quiet --fixed-strings --line-regexp "$mozilla_locale"
}

set_firefox_content_process_count() {
    local profile="$1"
    local count="$2"

    set_mozilla_pref "${profile}/prefs.js" \
                     "dom.ipc.processCount" "$count" \
                     user_pref
}

configure_tor_browser_memory_usage() {
    local profile="${1}"

    # Unit: KiB
    system_ram=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)

    if [ "$system_ram" -lt "$((3 * 1024 * 1024))" ]; then
        set_firefox_content_process_count "$profile" 2
    fi
}
