#!/bin/sh

# Rationale: Tor needs a somewhat accurate clock to work.
# If the clock is wrong enough to prevent it from opening circuits,
# we set the time to the middle of the valid time interval found
# in the Tor consensus, and we restart it.
# In any case, we use HTP to ask more accurate time information to
# a few authenticated HTTPS servers.

set -e
set -u

# Get LIVE_USERNAME
. /etc/live/config.d/username.conf

# Import export_gnome_env().
. /usr/local/lib/tails-shell-library/gnome.sh

# Import tor_control_*(), tor_is_working(), TOR_LOG, TOR_DIR
. /usr/local/lib/tails-shell-library/tor.sh

### Init variables

TORDATE_DIR=/run/tordate
TORDATE_DONE_FILE=${TORDATE_DIR}/done
INOTIFY_TIMEOUT=60

### Exit conditions

# Run only when the interface is not "lo":
if [ -z "$1" ] || [ "$1" = "lo" ]; then
	exit 0
fi

# Run whenever an interface gets "up", not otherwise:
if [ "$2" != "up" ]; then
	exit 0
fi

# Do not run twice
if [ -e "$TORDATE_DONE_FILE" ]; then
	exit 0
fi


### Functions

log() {
	logger -t time "$@"
}

wait_for_working_tor() {
	local waited=0

	log "Waiting for Tor to be working..."
	while ! tor_is_working; do
		if [ "$waited" -lt ${INOTIFY_TIMEOUT} ]; then
			sleep 2
			waited=$((waited + 2))
		else
			log "Timed out waiting for Tor to be working"
			return 1
		fi
	done
	log "Tor is now working."
}

start_notification_helper() {
	export_gnome_env
	exec /bin/su -c /usr/local/lib/tails-htp-notify-user "$LIVE_USERNAME" &
}


### Main

start_notification_helper

wait_for_working_tor

touch "$TORDATE_DONE_FILE"

log "Restarting htpdate"
systemctl restart htpdate.service
log "htpdate service restarted with return code $?"
