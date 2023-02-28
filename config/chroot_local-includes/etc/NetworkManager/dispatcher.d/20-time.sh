#!/bin/sh

# Use HTP to ask more accurate time information to a few authenticated
# HTTPS servers.

set -e
set -u

# Get LIVE_USERNAME
# shellcheck source=../../live/config.d/username.conf
. /etc/live/config.d/username.conf

### Exit conditions

# Run only when the interface is not "lo":
if [ -z "$1" ] || [ "$1" = "lo" ]; then
	exit 0
fi

# Run whenever an interface gets "up", not otherwise:
if [ "$2" != "up" ]; then
	exit 0
fi

/usr/local/lib/systemctl-user "${LIVE_USERNAME}" \
  --user restart tails-htpdate-notify-user.service
