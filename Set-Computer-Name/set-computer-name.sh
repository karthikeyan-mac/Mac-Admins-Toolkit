#!/bin/bash
# Set the Mac's name to <model>-<serial> (for example MacBookPro-XXXXXXXXXX)
# or to the serial number only.
# Author: Karthikeyan Marappan
#
# - NAME_FORMAT picks the format: "model-serial" (default) or "serial".
#   Set it in the environment, or edit SCRIPT_NAME_FORMAT below. The script
#   does not read positional parameters, because MDMs pass them differently.
# - Sets ComputerName, LocalHostName and HostName with scutil. Needs root.
# - The model name comes from system_profiler with spaces removed. The name
#   is then limited to letters, digits and hyphens and cut to 63 characters,
#   because LocalHostName and HostName reject anything else.
# - Does nothing when all three names already match.
# - Does not update MDM inventory. Let the MDM do that (in Jamf Pro, enable
#   Update Inventory in the policy).
#
# Exit codes: 0 = names set or already correct, 1 = error.

SCRIPT_NAME="set-computer-name.sh"
SCRIPT_VERSION="1.0.0"

# Name format: "model-serial" or "serial". NAME_FORMAT in the environment
# overrides this default.
SCRIPT_NAME_FORMAT="model-serial"

set -euo pipefail

# First line of output identifies the script and version.
echo "$SCRIPT_NAME - $SCRIPT_VERSION"

nameFormat="${NAME_FORMAT:-$SCRIPT_NAME_FORMAT}"
if [[ "$nameFormat" != "model-serial" && "$nameFormat" != "serial" ]]; then
	echo "ERROR: NAME_FORMAT must be \"model-serial\" or \"serial\", not \"$nameFormat\"." >&2
	exit 1
fi
echo "Name format: $nameFormat"

if [[ $EUID -ne 0 ]]; then
	echo "ERROR: Run as root. scutil --set needs root." >&2
	exit 1
fi

# Read the hardware overview once; it takes a second or more.
if ! hardwareInfo=$(/usr/sbin/system_profiler SPHardwareDataType); then
	echo "ERROR: system_profiler SPHardwareDataType failed." >&2
	exit 1
fi

# Split on ": " so the value is read whole, whatever its position on the line.
model=$(/usr/bin/awk -F': ' '/Model Name/ {print $2; exit}' <<< "$hardwareInfo" | /usr/bin/tr -d ' \t')
serialNumber=$(/usr/bin/awk -F': ' '/Serial Number/ {print $2; exit}' <<< "$hardwareInfo" | /usr/bin/tr -d ' \t')

# Stop rather than rename the Mac to "-", "MacBookPro-" or "-<serial>".
# The model is only needed for the model-serial format.
if [[ -z "$serialNumber" ]]; then
	echo "ERROR: Could not read the serial number." >&2
	exit 1
fi
if [[ "$nameFormat" == "model-serial" && -z "$model" ]]; then
	echo "ERROR: Could not read the model name." >&2
	exit 1
fi

if [[ "$nameFormat" == "serial" ]]; then
	rawName="$serialNumber"
else
	rawName="$model-$serialNumber"
fi
newName=$(printf '%s' "$rawName" | /usr/bin/tr -cd 'A-Za-z0-9-' | /usr/bin/cut -c1-63)

# scutil --get fails when a name is not set (HostName often is not), so an
# unset name reads as empty and is set below.
currentComputerName=$(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)
currentLocalHostName=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
currentHostName=$(/usr/sbin/scutil --get HostName 2>/dev/null || true)

if [[ "$currentComputerName" == "$newName" && "$currentLocalHostName" == "$newName" && "$currentHostName" == "$newName" ]]; then
	echo "Computer name is already $newName. Nothing to change."
	exit 0
fi

echo "Changing computer name from '${currentComputerName:-not set}' to '$newName'"

failed=0
for nameKey in ComputerName LocalHostName HostName; do
	if /usr/sbin/scutil --set "$nameKey" "$newName"; then
		echo "$nameKey set to $newName"
	else
		echo "ERROR: Could not set $nameKey." >&2
		failed=1
	fi
done

exit "$failed"
