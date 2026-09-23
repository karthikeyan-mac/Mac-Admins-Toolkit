#!/bin/bash
# Wait until the Dock is running, then run the commands added at the end.
# Use it to launch an app or run a script only after a user has logged in.
# Author: Karthikeyan Marappan
#
# - Waits with no time limit, on purpose: the script is meant to sit and wait
#   until someone logs in, however long that takes.
# - Any user's Dock ends the wait, on purpose. The Dock only runs inside a
#   logged-in GUI session.

SCRIPT_NAME="check-dock-status.sh"
SCRIPT_VERSION="1.0.0"

set -euo pipefail

# First line of output identifies the script and version.
echo "$SCRIPT_NAME - $SCRIPT_VERSION"

# Seconds between Dock checks.
CHECK_INTERVAL=5
# Seconds to wait after the Dock appears, so the rest of the user session
# (Finder, login items) has time to start before the commands below run.
SETTLE_DELAY=5

# pgrep exits 1 when no Dock is running; "|| true" keeps set -e from
# stopping the script so the loop can keep waiting.
dockStatus=$(/usr/bin/pgrep -x Dock || true)
echo "Waiting for Dock to launch"
while [[ "$dockStatus" == "" ]]
do
	echo "Dock is not loaded. Waiting"
	/bin/sleep "$CHECK_INTERVAL"
	dockStatus=$(/usr/bin/pgrep -x Dock || true)
done
/bin/sleep "$SETTLE_DELAY"
loggedinUser=$(/bin/ls -l /dev/console | /usr/bin/awk '{ print $3 }')
echo "Dock loaded with $dockStatus for user $loggedinUser"

# Add your scripts or commands here to execute after the Dock is loaded.
# When deployed through an MDM this script normally runs as root, so these
# commands run as root too. To run something as the logged-in user (open an
# app, change a user setting), use:
#   /bin/launchctl asuser "$(/usr/bin/id -u "$loggedinUser")" /usr/bin/sudo -u "$loggedinUser" <command>

exit 0
