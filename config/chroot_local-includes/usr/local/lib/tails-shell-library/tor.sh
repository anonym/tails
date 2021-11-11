#!/bin/sh

TOR_RC_DEFAULTS=/usr/share/tor/tor-service-defaults-torrc
TOR_RC=/etc/tor/torrc
# shellcheck disable=SC2034
TOR_LOG=/var/log/tor/log
# shellcheck disable=SC2034
TOR_DIR=/var/lib/tor

tor_rc_lookup() {
    grep --no-filename "^${1}\s" "${TOR_RC_DEFAULTS}" "${TOR_RC}" | \
	sed --regexp-extended "s/^${1}\s+(.+)$/\1/" | tail -n1
}

tor_control_port() {
    tor_rc_lookup ControlPort | sed --regexp-extended 's/.*://'
}

tor_control_getinfo() {
    /usr/local/lib/tor_variable get --type=info "$1"
}

tor_control_getconf() {
    /usr/local/lib/tor_variable get --type=conf "$1"
}

tor_control_setconf() {
    /usr/local/lib/tor_variable set --type=conf "$1" "$2"
}

tor_bootstrap_progress() {
    local res
    res=$(tor_control_getinfo status/bootstrap-phase | \
              sed --regexp-extended 's/^.* BOOTSTRAP PROGRESS=([[:digit:]]+) .*$/\1/')
    echo "${res:-0}"
}

# Only use this if you truly want a one-off check, otherwise consider
# /usr/local/lib/tor_wait_until_bootstrapped which avoids firing up a
# new python interpreter for each check.
tor_is_working() {
    [ "$(tor_bootstrap_progress)" -eq 100 ] && \
	[ "$(tor_control_getinfo status/enough-dir-info)" -eq 1 ]
}

tor_append_to_torrc () {
    echo "${@}" >> "${TOR_RC}"
}

# Set a (possibly existing) option $1 to $2 in torrc. Shouldn't be
# used for options that can be set multiple times (e.g. the listener
# options). Does not support configuration entries split into multiple
# lines (with the backslash character).
tor_set_in_torrc () {
    sed -i "/^${1}\s/d" "${TOR_RC}"
    tor_append_to_torrc "${1} ${2}"
}
