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

tor_control_stem_wrapper() {
	local control_port
	control_port="$(tor_rc_lookup ControlPort \
	    | sed --regexp-extended 's/.*://')"
        python3 <<EOF
import stem
import stem.connection
import sys
try:
    controller = stem.connection.connect(
                   control_port=('127.0.0.1', '${control_port}')
                 )
    if controller == None:
        raise stem.SocketError("Cannot connect to Tor's control port")
    controller.authenticate()
$(
    echo "${1}" | while IFS= read line; do
        echo "    ${line}"
    done
)
    exit(0)
except Exception as e:
    print(f"{type(e).__name__}: {str(e).strip()}", file=sys.stderr)
    exit(1)
EOF
}

tor_control_getinfo() {
	tor_control_stem_wrapper "print(controller.get_info('${1}'))"
}

tor_control_getconf() {
	tor_control_stem_wrapper "print(controller.get_conf('${1}'))"
}

tor_control_setconf() {
	tor_control_stem_wrapper "controller.set_conf('${1}', '${2}')"
}

tor_bootstrap_progress() {
       local res
       res=$(tor_control_getinfo status/bootstrap-phase | \
                    sed --regexp-extended 's/^.* BOOTSTRAP PROGRESS=([[:digit:]]+) .*$/\1/')
       echo "${res:-0}"
}

# Only use this if you truly want a one-off check, otherwise consider
# using tor_wait_until_bootstrapped() which avoids firing up a new
# python interpreter for each check.
tor_is_working() {
	[ "$(tor_bootstrap_progress)" -eq 100 ] && \
	    [ "$(tor_control_getinfo status/enough-dir-info)" -eq 1 ]
}

tor_wait_until_bootstrapped() {
    local timeout
    timeout="${1:-0}"
    tor_control_stem_wrapper "
import time
stop_time = time.time() + ${timeout}
while ${timeout} <= 0 or time.time() < stop_time:
    try:
        try:
            progress = controller.get_info('status/bootstrap-phase').split()[2].split('=')[1]
        except ValueError:
            progress = '0'
        enough_dir_info = controller.get_info('status/enough-dir-info')
        if enough_dir_info == '1' and progress == '100':
            exit(0)
    except (stem.SocketClosed, stem.SocketError):
        controller.reconnect()
    time.sleep(1)
exit(1)
"
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
