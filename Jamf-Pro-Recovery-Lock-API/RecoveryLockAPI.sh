#!/bin/bash

# Script to Set/Remove Recovery Lock on Apple Silicon Macs using the Jamf Pro API.
# Works based on the 'lockMode' variable (Set/Remove) to configure Recovery Lock.
#
# Key Functionalities:
# - Retrieves the Mac's serial number.
# - Generates a 26-digit random Recovery Lock password.
# - Uses Jamf Pro API Roles and API Clients (OAuth client credentials).
# - Uses the Jamf Pro API to:
#   - Obtain an access token
#   - Fetch the computer's management ID
#   - Send the Set Recovery Lock MDM command based on 'lockMode'
# - If 'lockMode' is "Set", it enables Recovery Lock with a generated password.
# - If 'lockMode' is "Remove", it clears the Recovery Lock.
# - Finally, invalidates the API token for security, whether the run succeeded
#   or failed partway through.
#
# Requirements:
# - A Mac with Apple Silicon running macOS 11.5 or later.
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions:
#   - Send Set Recovery Lock Command
#   - View MDM Command Information
#   - Read Computers
#   - View Recovery Lock
#
# Usage:
# - Provide 'Set' or 'Remove' as parameter 4 in a Jamf policy, or export
#   LOCK_MODE=Set|Remove for a standalone run.
# - Credentials: never hard-code them. Export JAMF_URL, JAMF_CLIENT_ID, and
#   JAMF_CLIENT_SECRET in the environment before running, e.g.:
#     export JAMF_URL="https://yourorg.jamfcloud.com"
#     export JAMF_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#     export JAMF_CLIENT_SECRET="********"
#   If JAMF_CLIENT_SECRET is not exported, the script prompts for it on an
#   interactive terminal and refuses to run silently (e.g. from a Jamf
#   policy) without one. Jamf policy script parameters are visible in policy
#   logs, so do not pass the client secret as a policy parameter — inject it
#   into the environment through a mechanism your org already trusts (e.g. a
#   root-owned, permission-restricted secrets file sourced by a wrapper).
# - For details, refer:
#   https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html

set -euo pipefail
umask 077

# Environment variables override these values. Keep committed secrets empty.
SCRIPT_JAMF_URL="https://karthikeyan.jamfcloud.com"
SCRIPT_JAMF_CLIENT_ID="your-api-client-id"
SCRIPT_JAMF_CLIENT_SECRET=""
# Fallback lockMode when neither Jamf policy parameter 4 nor LOCK_MODE is set.
SCRIPT_LOCK_MODE="Set"

JAMF_URL="${JAMF_URL:-$SCRIPT_JAMF_URL}"
JAMF_CLIENT_ID="${JAMF_CLIENT_ID:-$SCRIPT_JAMF_CLIENT_ID}"
JAMF_CLIENT_SECRET="${JAMF_CLIENT_SECRET:-$SCRIPT_JAMF_CLIENT_SECRET}"
JAMF_URL="${JAMF_URL%/}"

[[ "$JAMF_URL" != "https://karthikeyan.jamfcloud.com" ]] || {
	echo "ERROR: Set JAMF_URL or replace the placeholder SCRIPT_JAMF_URL." >&2
	exit 1
}
[[ "$JAMF_CLIENT_ID" != "your-api-client-id" ]] || { echo "ERROR: Set JAMF_CLIENT_ID." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

# lockMode: Jamf policy parameter 4 takes priority, then LOCK_MODE from the
# environment, then the hard-coded SCRIPT_LOCK_MODE default above. Fail fast
# (before any API calls) if the resolved value isn't valid.
lockMode="${4:-${LOCK_MODE:-$SCRIPT_LOCK_MODE}}"
case "$lockMode" in
	Set|Remove) ;;
	*)
		echo "ERROR: Invalid lockMode '$lockMode'. Provide 'Set' or 'Remove' as Jamf policy parameter 4, export LOCK_MODE, or fix SCRIPT_LOCK_MODE." >&2
		exit 1
		;;
esac

# Prompt only for interactive runs when no secret was supplied.
if [[ -z "${JAMF_CLIENT_SECRET:-}" ]]; then
	[[ -t 0 ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET for non-interactive execution (e.g. a Jamf policy)." >&2; exit 1; }
	read -r -s -p "Jamf API client secret: " JAMF_CLIENT_SECRET
	printf '\n' >&2
fi
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Jamf API client secret cannot be empty." >&2; exit 1; }

serialNumber=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
[[ -n "$serialNumber" ]] || { echo "ERROR: Unable to determine this Mac's serial number." >&2; exit 1; }
random_number=$(printf "%d%05d%05d%05d%05d%05d" $((RANDOM % 10)) $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-recovery-lock.XXXXXX")"
SECRET_FILE="$WORK_DIR/client-secret"
access_token=""

cleanup() {
	# Best-effort token invalidation on every exit path, success or failure.
	if [[ -n "$access_token" ]]; then
		local http_status
		http_status="$(curl --silent --show-error --write-out '%{http_code}' --output /dev/null \
			--request POST "$JAMF_URL/api/v1/auth/invalidate-token" \
			--header "Authorization: Bearer $access_token" || echo "000")"
		case "$http_status" in
			204) echo "Token successfully invalidated" ;;
			401) echo "Token already invalid" ;;
			*) echo "WARNING: Unexpected response invalidating token: HTTP $http_status" >&2 ;;
		esac
	fi
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Writes the client secret to a permission-restricted file so it never
# appears in the process list via curl's command-line arguments.
printf '%s' "$JAMF_CLIENT_SECRET" > "$SECRET_FILE"
unset JAMF_CLIENT_SECRET SCRIPT_JAMF_CLIENT_SECRET

jamf_curl() {
	local description="$1"
	local output_file="$2"
	local http_status
	shift 2

	if ! http_status="$(curl --silent --show-error "$@" \
		--output "$output_file" --write-out '%{http_code}')"; then
		printf '\nERROR: Jamf connection failed while %s.\n' "$description" >&2
		exit 1
	fi

	if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
		printf 'ERROR: Jamf returned HTTP %s while %s.\n' "$http_status" "$description" >&2
		[[ -s "$output_file" ]] && cat "$output_file" >&2
		exit 1
	fi
}

getAccessToken() {
	local token_response="$WORK_DIR/token.json"

	jamf_curl "obtaining an OAuth access token" "$token_response" \
		--request POST "$JAMF_URL/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--header "Accept: application/json" \
		--data-urlencode "client_id=$JAMF_CLIENT_ID" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret@$SECRET_FILE"

	access_token="$(plutil -extract access_token raw "$token_response" 2>/dev/null)"
	[[ -n "$access_token" ]] || { echo "ERROR: OAuth token response did not include access_token. Check the Jamf API Client credentials and permissions." >&2; exit 1; }
}

getManagementId() {
	local inventory_response="$WORK_DIR/inventory.json"

	jamf_curl "fetching the computer's management ID" "$inventory_response" \
		--request GET "$JAMF_URL/api/v1/computers-inventory?section=GENERAL&filter=hardware.serialNumber==$serialNumber" \
		--header "Authorization: Bearer $access_token" \
		--header "Accept: application/json"

	managementID="$(plutil -extract results.0.general.managementId raw "$inventory_response" 2>/dev/null)"
	[[ -n "$managementID" ]] || {
		echo "ERROR: Failed to retrieve management ID. Check if the API Client has the required permission or that the serial number matches a computer in Jamf Pro." >&2
		exit 1
	}
}

sendRecoveryLockCommand() {
	local newPassword="$1"
	local command_body="$WORK_DIR/recovery-lock-command.json"
	local command_response="$WORK_DIR/recovery-lock-response.json"

	cat > "$command_body" <<EOF
{
	"clientData": [{ "managementId": "$managementID", "clientType": "COMPUTER" }],
	"commandData": { "commandType": "SET_RECOVERY_LOCK", "newPassword": "$newPassword" }
}
EOF

	jamf_curl "sending the Set Recovery Lock command" "$command_response" \
		--request POST "$JAMF_URL/api/v2/mdm/commands" \
		--header "Accept: application/json" \
		--header "Authorization: Bearer $access_token" \
		--header "Content-Type: application/json" \
		--data @"$command_body"

	echo "Recovery Lock ${lockMode} command sent for ${serialNumber}"
}

main() {
	getAccessToken
	getManagementId

	case "$lockMode" in
		Set) sendRecoveryLockCommand "$random_number" ;;
		Remove) sendRecoveryLockCommand "" ;;
	esac
}

main
