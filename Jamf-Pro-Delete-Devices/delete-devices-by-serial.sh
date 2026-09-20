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
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that deletes (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script looks up each serial number and
#   reports what it WOULD delete, without deleting. Set DRY_RUN=no to delete.
# - Credentials: never hard-code them. Values are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret;
#   plain text, keep it chmod 600), then a prompt (client ID and secret are
#   entered with no echo). See the main README for the shared configuration.
# - Override DEVICE_TYPE (computer|mobile), SERIAL_LIST (path to the serial
#   number file), and LOG_FILE via the environment; otherwise the defaults
#   below apply.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
#
# *** Test against a non-production Jamf Pro environment first. ***

SCRIPT_NAME="delete-devices-by-serial.sh"
SCRIPT_VERSION="2.0.0"

set -euo pipefail
umask 077

# First line of output identifies the script and version.
BANNER="$SCRIPT_NAME - $SCRIPT_VERSION"
echo "$BANNER"

# Value order: environment variable, then these script defaults, then the
# preference domain below, then (for anything still empty) an interactive
# prompt. Keep secrets out of this file.
SCRIPT_JAMF_ENV=""                                        # prod | dev ; empty = ask (JAMF_ENV overrides)
SCRIPT_JAMF_URL=""                                        # e.g. https://yourorg.jamfcloud.com
SCRIPT_DEVICE_TYPE="computer"                             # "computer" or "mobile"
SCRIPT_SERIAL_LIST="$HOME/Desktop/serialNumber.txt"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_delete_devices.log"
SCRIPT_DRY_RUN="yes"                                      # yes = report only, delete nothing

# Shared toolkit preference domain (~/Library/Preferences/<domain>.plist).
# Shared keys are documented in the main README. DRY_RUN is deliberately NOT
# read from it, so a stored value can never turn a dry run into a real run.
PREF_DOMAIN="com.karthikmac.macadminstoolkit"

# --- Select the environment (prod or dev) ------------------------------------
# JAMF_ENV (environment variable), then SCRIPT_JAMF_ENV, then a prompt. Never
# defaulted silently: with no choice on a non-interactive run, the script stops.
ENV_SOURCE="JAMF_ENV variable"
JAMF_ENV="${JAMF_ENV:-}"
if [[ -z "$JAMF_ENV" && -n "$SCRIPT_JAMF_ENV" ]]; then
	JAMF_ENV="$SCRIPT_JAMF_ENV"
	ENV_SOURCE="script default"
fi
if [[ -z "$JAMF_ENV" && -t 0 ]]; then
	read -rp "Select environment (prod/dev): " JAMF_ENV
	ENV_SOURCE="prompt"
fi
JAMF_ENV=$(printf '%s' "$JAMF_ENV" | tr '[:upper:]' '[:lower:]')
case "$JAMF_ENV" in
	prod) ENV_PREFIX="Prod" ;;
	dev) ENV_PREFIX="Dev" ;;
	"") echo "ERROR: Set JAMF_ENV to prod or dev." >&2; exit 1 ;;
	*) echo "ERROR: JAMF_ENV must be prod or dev (got '$JAMF_ENV')." >&2; exit 1 ;;
esac

# Prints a preference value, or nothing if the domain or key does not exist.
readPref() {
	defaults read "$PREF_DOMAIN" "$1" 2>/dev/null || true
}

# loadSetting VAR PLIST_KEY [DEFAULT]
# Keeps an exported value, else DEFAULT (if non-empty), else the plist value
# (skipped when PLIST_KEY is empty). Records where each value came from (never
# the value) in SETTING_SOURCES.
SETTING_SOURCES=""
loadSetting() {
	local var="$1" key="$2" default="${3:-}" src="not set" value
	# Make sure the variable exists (empty) so later "set -u" checks are safe.
	printf -v "$var" '%s' "${!var:-}"
	if [[ -n "${!var}" ]]; then
		src="environment"
	elif [[ -n "$default" ]]; then
		printf -v "$var" '%s' "$default"
		src="script default"
	elif [[ -n "$key" ]]; then
		value="$(readPref "$key")"
		if [[ -n "$value" ]]; then
			printf -v "$var" '%s' "$value"
			src="plist"
		fi
	fi
	SETTING_SOURCES+="$var=$src, "
}

loadSetting JAMF_URL "${ENV_PREFIX}ServerURL" "$SCRIPT_JAMF_URL"
loadSetting JAMF_CLIENT_ID "${ENV_PREFIX}APIClientID"
loadSetting JAMF_CLIENT_SECRET "${ENV_PREFIX}APIClientSecret"
loadSetting DEVICE_TYPE "" "$SCRIPT_DEVICE_TYPE"
loadSetting SERIAL_LIST "" "$SCRIPT_SERIAL_LIST"
loadSetting LOG_FILE "" "$SCRIPT_LOG_FILE"
JAMF_URL="${JAMF_URL%/}"
DRY_RUN="${DRY_RUN:-$SCRIPT_DRY_RUN}"
deviceType="$DEVICE_TYPE"
serialNumberList="$SERIAL_LIST"
logFile="$LOG_FILE"

# Lines 2-3: the environment, and where each setting is taken from (values are
# never printed). If the environment was prompted for, that prompt comes first.
ENV_LINE="Environment: $JAMF_ENV (from $ENV_SOURCE). Settings sources (order: environment, script default, plist $PREF_DOMAIN, then prompt if still empty):"
SOURCES_LINE="  ${SETTING_SOURCES%, }"
echo "$ENV_LINE"
echo "$SOURCES_LINE"

# The plist can hold credentials in plain text; warn if other users can read it.
prefFile="$HOME/Library/Preferences/$PREF_DOMAIN.plist"
if [[ -f "$prefFile" ]]; then
	prefMode=$(stat -f '%Lp' "$prefFile")
	if [[ "$prefMode" != "600" && "$prefMode" != "400" ]]; then
		echo "WARNING: $prefFile is mode $prefMode and may hold credentials. Run: chmod 600 \"$prefFile\"" >&2
	fi
fi

# --- Prompt for anything not supplied ----------------------------------------
# Whatever is still empty after the environment, script defaults and plist is
# prompted for. Prompts only happen on an interactive terminal; otherwise
# validation below fails with a clear error. Secrets are read without echo.
promptValue() {
	local var="$1" label="$2" mode="${3:-}" value
	[[ -z "${!var}" && -t 0 ]] || return 0
	if [[ "$mode" == "secret" ]]; then
		read -rsp "$label: " value
		echo >&2
	else
		read -rp "$label: " value
	fi
	printf -v "$var" '%s' "$value"
}

promptValue JAMF_URL "Jamf Pro URL (e.g. https://yourorg.jamfcloud.com)"
JAMF_URL="${JAMF_URL%/}"
promptValue JAMF_CLIENT_ID "API Client ID" secret
promptValue JAMF_CLIENT_SECRET "API Client secret" secret

# --- Input validation --------------------------------------------------------
[[ -n "$JAMF_URL" ]] || { echo "ERROR: Set JAMF_URL (e.g. https://yourorg.jamfcloud.com)." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
[[ -n "$JAMF_CLIENT_ID" ]] || { echo "ERROR: Set JAMF_CLIENT_ID." >&2; exit 1; }
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET." >&2; exit 1; }
[[ "$deviceType" == "computer" || "$deviceType" == "mobile" ]] || {
	echo "ERROR: DEVICE_TYPE must be 'computer' or 'mobile'." >&2
	exit 1
}
[[ "$DRY_RUN" == "yes" || "$DRY_RUN" == "no" ]] || { echo "ERROR: DRY_RUN must be yes or no." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

[[ -f "$serialNumberList" ]] || { echo "ERROR: Source file '$serialNumberList' does not exist." >&2; exit 1; }
[[ -s "$serialNumberList" ]] || { echo "ERROR: Source file '$serialNumberList' is empty." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"
serialCount=$(grep -c . "$serialNumberList" || true)

# --- Guard against a URL that belongs to the other environment ---------------
# Compares the final JAMF_URL (from any source) with the plist URLs, so a stray
# exported JAMF_URL can't send a "dev" run to production, or the reverse.
normalizeUrl() {
	printf '%s' "${1%/}" | tr '[:upper:]' '[:lower:]'
}
if [[ "$JAMF_ENV" == "prod" ]]; then otherPrefix="Dev"; else otherPrefix="Prod"; fi
expectedUrl=$(normalizeUrl "$(readPref "${ENV_PREFIX}ServerURL")")
otherUrl=$(normalizeUrl "$(readPref "${otherPrefix}ServerURL")")
thisUrl=$(normalizeUrl "$JAMF_URL")
if [[ -n "$expectedUrl" && "$thisUrl" != "$expectedUrl" ]]; then
	echo "ERROR: Environment is $JAMF_ENV but JAMF_URL ($JAMF_URL) does not match ${ENV_PREFIX}ServerURL in the plist." >&2
	echo "       Fix the plist, or unset the JAMF_URL variable so the plist value is used." >&2
	exit 1
elif [[ -z "$expectedUrl" && -n "$otherUrl" && "$thisUrl" == "$otherUrl" ]]; then
	echo "ERROR: Environment is $JAMF_ENV but JAMF_URL ($JAMF_URL) is the ${otherPrefix} URL in the plist." >&2
	exit 1
fi

# --- Production warning and confirmation -------------------------------------
if [[ "$JAMF_ENV" == "prod" ]]; then
	{
		echo
		echo "################################################################"
		echo "#  WARNING: YOU ARE TARGETING PRODUCTION"
		echo "#  Server : $JAMF_URL"
		echo "#  Account: API Client"
		if [[ "$DRY_RUN" == "yes" ]]; then
			echo "#  DRY_RUN=yes: read-only checks, nothing will be deleted."
		else
			echo "#  DRY_RUN=no: this WILL PERMANENTLY DELETE up to $serialCount $deviceType record(s) from PRODUCTION."
		fi
		echo "################################################################"
	} >&2
	if [[ -t 0 ]]; then
		read -rp "Type PROD to continue (anything else cancels): " confirmProd
		[[ "$confirmProd" == "PROD" ]] || { echo "Cancelled. Nothing was changed."; exit 0; }
	elif [[ "$MAKES_CHANGES" == "yes" && "${JAMF_PROD_CONFIRM:-}" != "PROD" ]]; then
		echo "ERROR: A non-interactive production run that changes things requires JAMF_PROD_CONFIRM=PROD." >&2
		exit 1
	fi
fi

mkdir -p "$(dirname "$logFile")"
touch "$logFile"
# Record the same first lines in the log file (console already showed them).
printf '%s\n%s\n%s\n' "$BANNER" "$ENV_LINE" "$SOURCES_LINE" >> "$logFile"

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
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would delete (DRY_RUN=yes, nothing was deleted): $countSuccess"
	else
		log "Successfully deleted: $countSuccess"
	fi
	if [[ ${#successSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${successSerial[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Not found or failed lookups: $countFailure"
	else
		log "Failed deletions: $countFailure"
	fi
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
		if [[ "$DRY_RUN" == "yes" ]]; then
			countSuccess=$((countSuccess + 1))
			successSerial+=("$serialNumber")
			log "DRY_RUN: would delete computer with serial: $serialNumber (Jamf ID $computerId)"
			return
		fi
		responseCode=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 2 \
			--request DELETE "${JAMF_URL}/api/v4/computers-inventory/${computerId}" \
			--header "Authorization: Bearer ${access_token}" \
			--header "Accept: application/json" || echo "000")
	else
		# No modern (non-Classic) Jamf Pro API endpoint deletes a mobile
		# device as of this writing; the Classic API remains required here.
		if [[ "$DRY_RUN" == "yes" ]]; then
			# Read-only existence check on the same Classic path.
			responseCode=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 2 \
				--request GET "${JAMF_URL}/JSSResource/mobiledevices/serialnumber/${serialNumber}" \
				--header "Authorization: Bearer ${access_token}" \
				--header "Accept: application/xml" || echo "000")
			if [[ "$responseCode" == 200 ]]; then
				countSuccess=$((countSuccess + 1))
				successSerial+=("$serialNumber")
				log "DRY_RUN: would delete mobile with serial: $serialNumber"
			elif [[ "$responseCode" == 404 ]]; then
				countFailure=$((countFailure + 1))
				failureSerial+=("$serialNumber")
				log "Not found: No mobile with serial: $serialNumber"
			else
				countFailure=$((countFailure + 1))
				failureSerial+=("$serialNumber")
				log "Failed to look up mobile with serial: $serialNumber. HTTP code: $responseCode"
			fi
			return
		fi
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
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: checking $deviceType records by serial number. Nothing will be deleted."
	else
		log "Deleting $deviceType records by serial number..."
	fi
	while IFS= read -r serialNumber || [[ -n "$serialNumber" ]]; do
		[[ -z "$serialNumber" ]] && continue
		deleteDeviceBySerial "$serialNumber"
	done < "$serialNumberList"
}

main() {
	getAccessToken
	processSerialNumbers
}

main
