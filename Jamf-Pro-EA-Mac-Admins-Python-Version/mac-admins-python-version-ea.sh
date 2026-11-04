#!/bin/bash

# Jamf Pro Extension Attribute: Mac Admins Python version.
# Author: Karthikeyan Marappan
#
# Runs "managed_python3 --version" if the launcher exists and reports the
# version number, or "Not Installed" / "Unknown". Uses only macOS tools; no
# API calls or credentials. See README.md for setup.

SCRIPT_NAME="mac-admins-python-version-ea.sh"
SCRIPT_VERSION="1.0.0"

# First line of output identifies the script and version.
echo "$SCRIPT_NAME - $SCRIPT_VERSION"

# Path to the Mac Admins Python launcher. It is a symlink into
# /Library/ManagedFrameworks/Python, so a broken link fails the -x test below.
PYTHON_LAUNCHER="/usr/local/bin/managed_python3"

RESULT="Not Installed"

# -x follows symlinks, so a missing file or a broken link is treated as not installed.
if [[ -x "$PYTHON_LAUNCHER" ]]; then
	# Python 3 prints its version on stdout. 2>&1 also captures it if it goes to stderr.
	# A failing launcher is not fatal here: an empty version falls through to "Unknown".
	PYTHON_OUTPUT="$("$PYTHON_LAUNCHER" --version 2>&1 || true)"

	# Expected output is "Python 3.x.y". Keep only the number, so the EA value stays
	# simple and consistent for Smart Group criteria.
	PYTHON_VERSION="$(printf '%s\n' "$PYTHON_OUTPUT" | sed -n 's/^Python \([0-9][0-9.]*\).*/\1/p' | head -n 1)"

	if [[ -n "$PYTHON_VERSION" ]]; then
		RESULT="$PYTHON_VERSION"
	else
		# The launcher exists but did not report a version. Show "Unknown" so the
		# problem is visible in inventory, rather than reporting it as not installed.
		RESULT="Unknown"
	fi
fi

echo "<result>$RESULT</result>"
