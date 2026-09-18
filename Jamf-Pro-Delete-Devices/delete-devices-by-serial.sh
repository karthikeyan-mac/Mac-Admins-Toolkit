#!/bin/bash

# Delete computers or mobile devices in Jamf Pro by serial number list.
# Author: Karthikeyan Marappan
#
# Key Functionalities:
# - Reads serial numbers from a text file, one per line.
# - Uses Jamf Pro API Roles and API Clients (OAuth client credentials).
# - Computers: looks up the Jamf Pro ID via the modern Jamf Pro API
#   (GET /api/v4/computers-inventory, filtered by serial number), then
#   deletes the record via DELETE /api/v4/computers-inventory/{id}. The
#   Classic API's serial-number delete (JSSResource/computers/serialnumber)
#   was deprecated by Jamf on 2025-02-11, and the v1-v3 computers-inventory
#   GET endpoints are deprecated too, so v4 is used for both the lookup and
#   the delete.
# - Mobile devices: as of this writing, Jamf Pro has no modern (non-Classic)
#   API endpoint that deletes a mobile device, so this uses the Classic API
#   DELETE /JSSResource/mobiledevices/serialnumber/{serial}. Revisit this if
#   Jamf ever adds a modern mobile-device delete endpoint.
# - Finally, invalidates the API token for security, whether the run
#   succeeded or failed partway through.
# - Always prints a summary (counts plus success/failure serial lists) at
#   the end of the run, even if the run stopped early (e.g. an invalid API
#   role, or an unexpected error) — in that case the summary also states
#   why the run stopped.
#
# - Every curl call retries transient network/server failures (curl's
#   --retry, which only retries connection-level failures and a small set
#   of 5xx/429 responses, never a completed 2xx/4xx result) rather than
#   leaving a flaky connection to fail the whole run.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions:
#   - Read Computers, Delete Computers, Read Mobile Devices, Delete Mobile Devices
#   (a single role covering both device types, since DEVICE_TYPE can be
#   switched without regenerating the API Client)
#
# Usage:
# - Credentials: never hard-code them. Export JAMF_URL, JAMF_CLIENT_ID, and
#   JAMF_CLIENT_SECRET in the environment before running, e.g.:
#     export JAMF_URL="https://yourorg.jamfcloud.com"
#     export JAMF_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#     export JAMF_CLIENT_SECRET="********"
#   If JAMF_CLIENT_SECRET is not exported, the script prompts for it on an
#   interactive terminal and refuses to run silently without one.
# - Override DEVICE_TYPE (computer|mobile), SERIAL_LIST (path to the serial
#   number file), and LOG_FILE via the environment; otherwise the defaults
#   below apply.
#
# *** Test against a non-production Jamf Pro environment first. ***

SCRIPT_VERSION="1.0.0"

set -euo pipefail
umask 077

# Environment variables override these values. Keep committed secrets empty.
SCRIPT_JAMF_URL="https://karthikeyan.jamfcloud.com/"
SCRIPT_JAMF_CLIENT_ID=""
SCRIPT_JAMF_CLIENT_SECRET=""
SCRIPT_DEVICE_TYPE="computer"                             # "computer" or "mobile"
SCRIPT_SERIAL_LIST="$HOME/Desktop/serialNumber.txt"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_delete_devices.log"

JAMF_URL="${JAMF_URL:-$SCRIPT_JAMF_URL}"
JAMF_CLIENT_ID="${JAMF_CLIENT_ID:-$SCRIPT_JAMF_CLIENT_ID}"
JAMF_CLIENT_SECRET="${JAMF_CLIENT_SECRET:-$SCRIPT_JAMF_CLIENT_SECRET}"
JAMF_URL="${JAMF_URL%/}"
deviceType="${DEVICE_TYPE:-$SCRIPT_DEVICE_TYPE}"
serialNumberList="${SERIAL_LIST:-$SCRIPT_SERIAL_LIST}"
logFile="${LOG_FILE:-$SCRIPT_LOG_FILE}"

[[ "$JAMF_URL" != "https://karthikeyan.jamfcloud.com" ]] || {
	echo "ERROR: Set JAMF_URL or replace the placeholder SCRIPT_JAMF_URL." >&2
	exit 1
}
[[ "$JAMF_CLIENT_ID" != "your-api-client-id" ]] || { echo "ERROR: Set JAMF_CLIENT_ID." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
[[ "$deviceType" == "computer" || "$deviceType" == "mobile" ]] || {
	echo "ERROR: DEVICE_TYPE must be 'computer' or 'mobile'." >&2
	exit 1
}
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

[[ -f "$serialNumberList" ]] || { echo "ERROR: Source file '$serialNumberList' does not exist." >&2; exit 1; }
[[ -s "$serialNumberList" ]] || { echo "ERROR: Source file '$serialNumberList' is empty." >&2; exit 1; }

# Prompt only for interactive runs when no secret was supplied.
if [[ -z "${JAMF_CLIENT_SECRET:-}" ]]; then
	[[ -t 0 ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET for non-interactive execution." >&2; exit 1; }
	read -r -s -p "Jamf API client secret: " JAMF_CLIENT_SECRET
	printf '\n' >&2
fi
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Jamf API client secret cannot be empty." >&2; exit 1; }

mkdir -p "$(dirname "$logFile")"
touch "$logFile"

countSuccess=0
countFailure=0
successSerial=()
failureSerial=()
runFailureReason=""

log() {
	echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$logFile"
}

# Captures a reason for an unexpected (not explicitly handled) error, so the
# final summary can explain why the run stopped short. Does not overwrite a
# reason a specific error path already set.
trap 'runFailureReason="${runFailureReason:-Unexpected error at line $LINENO (exit code $?).}"' ERR

printSummary() {
	log "---------------------------------------"
	log "Summary for $deviceType deletions"
	log "Successfully deleted: $countSuccess"
	if [[ ${#successSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${successSerial[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed deletions: $countFailure"
	if [[ ${#failureSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${failureSerial[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-delete-devices.XXXXXX")"
SECRET_FILE="$WORK_DIR/client-secret"
access_token=""

cleanup() {
	# Best-effort token invalidation on every exit path, success or failure.
	if [[ -n "$access_token" ]]; then
		local http_status
		http_status="$(curl --silent --show-error --retry 2 --retry-delay 2 \
			--write-out '%{http_code}' --output /dev/null \
			--request POST "$JAMF_URL/api/v1/auth/invalidate-token" \
			--header "Authorization: Bearer $access_token" || echo "000")"
		case "$http_status" in
			204) log "Token successfully invalidated." ;;
			401) log "Token already invalid." ;;
			*) log "WARNING: Unexpected response invalidating token: HTTP $http_status" ;;
		esac
	fi
	# Always show what happened, even when the run stopped early.
	printSummary
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Writes the client secret to a permission-restricted file so it never
# appears in the process list via curl's command-line arguments.
printf '%s' "$JAMF_CLIENT_SECRET" > "$SECRET_FILE"
unset JAMF_CLIENT_SECRET SCRIPT_JAMF_CLIENT_SECRET

getAccessToken() {
	log "Fetching Jamf API token..."
	local token_response="$WORK_DIR/token.json"
	local http_status

	http_status="$(curl --silent --show-error --retry 2 --retry-delay 2 \
		--write-out '%{http_code}' --output "$token_response" \
		--request POST "$JAMF_URL/api/v1/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--header "Accept: application/json" \
		--data-urlencode "client_id=$JAMF_CLIENT_ID" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret@$SECRET_FILE" || echo "000")"

	[[ "$http_status" =~ ^2[0-9][0-9]$ ]] || {
		runFailureReason="Failed to obtain a Jamf API access token (HTTP $http_status)."
		log "Error: Failed to obtain access token. HTTP code: $http_status"
		exit 1
	}

	access_token="$(plutil -extract access_token raw "$token_response" 2>/dev/null || true)"
	[[ -n "$access_token" ]] || {
		runFailureReason="Jamf Pro did not return a valid access token."
		log "Error: Failed to get valid access token."
		exit 1
	}
	log "Successfully obtained token."
}

# Looks up a computer's Jamf Pro ID by serial number using the modern
# Jamf Pro API. Sets `computerId`, or empties it if no match was found.
lookupComputerId() {
	local serialNumber="$1"
	local response="$WORK_DIR/lookup.json"
	local http_status

	http_status="$(curl --silent --show-error --retry 2 --retry-delay 2 \
		--write-out '%{http_code}' --output "$response" \
		--request GET "$JAMF_URL/api/v4/computers-inventory?section=GENERAL&filter=hardware.serialNumber==$serialNumber" \
		--header "Authorization: Bearer $access_token" \
		--header "Accept: application/json" || echo "000")"

	if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
		computerId=""
		return
	fi

	computerId="$(plutil -extract results.0.id raw "$response" 2>/dev/null || true)"
}

deleteDeviceBySerial() {
	local serialNumber="$1"
	local responseCode
	local computerId=""

	if [[ "$deviceType" == "computer" ]]; then
		lookupComputerId "$serialNumber"
		if [[ -z "$computerId" ]]; then
			countFailure=$((countFailure + 1))
			failureSerial+=("$serialNumber")
			log "Not found: No computer with serial: $serialNumber"
			return
		fi
		responseCode=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 2 \
			--request DELETE "${JAMF_URL}/api/v4/computers-inventory/${computerId}" \
			--header "Authorization: Bearer ${access_token}" \
			--header "Accept: application/json" || echo "000")
	else
		# No modern (non-Classic) Jamf Pro API endpoint deletes a mobile
		# device as of this writing; the Classic API remains required here.
		responseCode=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 2 \
			--request DELETE "${JAMF_URL}/JSSResource/mobiledevices/serialnumber/${serialNumber}" \
			--header "Authorization: Bearer ${access_token}" \
			--header "Accept: application/xml" || echo "000")
	fi

	if [[ "$responseCode" == 200 || "$responseCode" == 204 ]]; then
		countSuccess=$((countSuccess + 1))
		successSerial+=("$serialNumber")
		log "Deleted $deviceType with serial: $serialNumber"
	elif [[ "$responseCode" == 404 ]]; then
		countFailure=$((countFailure + 1))
		failureSerial+=("$serialNumber")
		log "Not found: No $deviceType with serial: $serialNumber"
	elif [[ "$responseCode" == 401 ]]; then
		countFailure=$((countFailure + 1))
		failureSerial+=("$serialNumber")
		runFailureReason="Unauthorized (401) deleting $deviceType with serial $serialNumber. Check the API Client's role privileges; remaining serial numbers were not attempted."
		log "Unauthorized to delete $deviceType with serial: $serialNumber. Check API role."
		exit 1
	else
		countFailure=$((countFailure + 1))
		failureSerial+=("$serialNumber")
		log "Failed to delete $deviceType with serial: $serialNumber. HTTP code: $responseCode"
	fi
}

processSerialNumbers() {
	log "Deleting $deviceType records by serial number..."
	while IFS= read -r serialNumber || [[ -n "$serialNumber" ]]; do
		[[ -z "$serialNumber" ]] && continue
		deleteDeviceBySerial "$serialNumber"
	done < "$serialNumberList"
}

main() {
	log "Script version: $SCRIPT_VERSION"
	getAccessToken
	processSerialNumbers
}

main
