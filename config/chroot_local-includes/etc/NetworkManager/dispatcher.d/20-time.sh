#!/bin/sh

# Use HTP to ask more accurate time information to a few authenticated
# HTTPS servers.

set -e
set -u

# Get LIVE_USERNAME
# shellcheck source=../../live/config.d/username.conf
. /etc/live/config.d/username.conf

# Import export_gnome_env().
# shellcheck source=../../../usr/local/lib/tails-shell-library/gnome.sh
. /usr/local/lib/tails-shell-library/gnome.sh

### Init variables

TORDATE_DIR=/run/tordate
TORDATE_DONE_FILE="${TORDATE_DIR}/done"

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

start_notification_helper() {
	export_gnome_env
	exec /bin/su -c /usr/local/lib/tails-htp-notify-user "$LIVE_USERNAME" &
}


### Main

start_notification_helper

touch "$TORDATE_DONE_FILE"

log "Restarting htpdate"
systemctl --no-block start htpdate.service
log "htpdate service started with return code $?"
