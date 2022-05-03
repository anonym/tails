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

### Exit conditions

# Run only when the interface is not "lo":
if [ -z "$1" ] || [ "$1" = "lo" ]; then
	exit 0
fi

# Run whenever an interface gets "up", not otherwise:
if [ "$2" != "up" ]; then
	exit 0
fi

### Functions

start_notification_helper() {
	export_gnome_env
	exec /bin/su -c /usr/local/lib/tails-htp-notify-user "$LIVE_USERNAME" &
}


### Main

start_notification_helper
