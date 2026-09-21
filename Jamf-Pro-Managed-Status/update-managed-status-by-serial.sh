#!/bin/bash

# Set the "managed" status of computers in Jamf Pro from a serial number list.
# Author: Karthikeyan Marappan
#
# Key Functionalities:
# - Reads serial numbers from a text file, one per line (blank lines and lines
#   starting with # are ignored).
# - Uses a Jamf Pro API Role and API Client (OAuth client credentials).
# - Looks up each computer with GET /api/v4/computers-inventory (filtered by
#   serial number) and reads its current managed status.
# - Sets general.managed with PATCH /api/v4/computers-inventory-detail/{id}.
#   Computers already in the requested state are skipped. A serial number that
#   matches no record, or more than one record, is reported and not changed.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any serial number failed or the run stopped early.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions: Read Computers, Update Computers.
#
# Usage:
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that changes records (DRY_RUN=no)
#   also needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script looks up each serial number and
#   reports what it WOULD change, without changing anything. Set DRY_RUN=no to
#   apply the change.
# - MANAGED_VALUE is "true" (managed) or "false" (unmanaged). It has no safe
#   default, so it is prompted for when not set.
# - Credentials: never hard-code them. Values are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret;
#   plain text, keep it chmod 600), then a prompt (client ID and secret are
#   entered with no echo). See the main README for the shared configuration.
# - Override SERIAL_LIST (path to the serial number file) and LOG_FILE via the
#   environment; otherwise the defaults below apply.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
#
# *** Test against a non-production Jamf Pro environment first. ***

SCRIPT_NAME="update-managed-status-by-serial.sh"
SCRIPT_VERSION="1.0.0"

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
SCRIPT_MANAGED_VALUE=""                                   # true | false ; empty = ask (MANAGED_VALUE overrides)
SCRIPT_SERIAL_LIST="$HOME/Desktop/serialNumber.txt"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_managed_status.log"
SCRIPT_DRY_RUN="yes"                                      # yes = report only, change nothing

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
loadSetting MANAGED_VALUE "" "$SCRIPT_MANAGED_VALUE"
loadSetting SERIAL_LIST "" "$SCRIPT_SERIAL_LIST"
loadSetting LOG_FILE "" "$SCRIPT_LOG_FILE"
JAMF_URL="${JAMF_URL%/}"
DRY_RUN="${DRY_RUN:-$SCRIPT_DRY_RUN}"
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
promptValue MANAGED_VALUE "Set computers to managed or unmanaged (true = managed, false = unmanaged)"
MANAGED_VALUE=$(printf '%s' "$MANAGED_VALUE" | tr '[:upper:]' '[:lower:]')

# --- Input validation --------------------------------------------------------
[[ -n "$JAMF_URL" ]] || { echo "ERROR: Set JAMF_URL (e.g. https://yourorg.jamfcloud.com)." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
[[ -n "$JAMF_CLIENT_ID" ]] || { echo "ERROR: Set JAMF_CLIENT_ID." >&2; exit 1; }
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET." >&2; exit 1; }
# MANAGED_VALUE goes straight into the JSON request body, so accept only these two.
[[ "$MANAGED_VALUE" == "true" || "$MANAGED_VALUE" == "false" ]] || {
	echo "ERROR: Set MANAGED_VALUE to true (managed) or false (unmanaged)." >&2
	exit 1
}
[[ "$DRY_RUN" == "yes" || "$DRY_RUN" == "no" ]] || { echo "ERROR: DRY_RUN must be yes or no." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

[[ -f "$serialNumberList" ]] || { echo "ERROR: Serial number file '$serialNumberList' does not exist." >&2; exit 1; }
[[ -r "$serialNumberList" ]] || { echo "ERROR: Serial number file '$serialNumberList' is not readable." >&2; exit 1; }

# Count the usable lines (not blank, not a comment) for the warning and checks.
serialCount=$(grep -cv '^[[:space:]]*\(#\|$\)' "$serialNumberList" || true)
[[ "$serialCount" -gt 0 ]] || { echo "ERROR: Serial number file '$serialNumberList' has no serial numbers." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

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
			echo "#  DRY_RUN=yes: read-only checks, nothing will be changed."
		else
			echo "#  DRY_RUN=no: this WILL set managed=$MANAGED_VALUE on up to $serialCount computer record(s) in PRODUCTION."
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

countChanged=0
countUnchanged=0
countFailure=0
changedSerial=()
unchangedSerial=()
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
	log "Summary: set managed=$MANAGED_VALUE"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would change (DRY_RUN=yes, nothing was changed): $countChanged"
	else
		log "Changed: $countChanged"
	fi
	if [[ ${#changedSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${changedSerial[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Already managed=$MANAGED_VALUE (skipped): $countUnchanged"
	if [[ ${#unchangedSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${unchangedSerial[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed or not found: $countFailure"
	if [[ ${#failureSerial[@]} -gt 0 ]]; then
		printf "%s\n" "${failureSerial[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-managed-status.XXXXXX")"
SECRET_FILE="$WORK_DIR/client-secret"
RESPONSE_FILE="$WORK_DIR/response.json"
access_token=""
http_status=""

# Sends the bearer token to curl on stdin (-K -) so it never appears in the
# process list. Used for every authenticated call, including the token
# invalidation below.
bearerConfig() {
	printf 'header = "Authorization: Bearer %s"\n' "$access_token"
}

cleanup() {
	# Best-effort token invalidation on every exit path, success or failure.
	if [[ -n "$access_token" ]]; then
		local invalidate_status
		invalidate_status="$(bearerConfig | curl --silent --show-error --retry 2 --retry-delay 2 \
			--write-out '%{http_code}' --output /dev/null -K - \
			--request POST "$JAMF_URL/api/v1/auth/invalidate-token" || true)"
		case "${invalidate_status:-000}" in
			204) log "Token successfully invalidated." ;;
			401) log "Token already invalid." ;;
			*) log "WARNING: Unexpected response invalidating token: HTTP ${invalidate_status:-000}" ;;
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
	local token_status

	token_status="$(curl --silent --show-error --retry 2 --retry-delay 2 \
		--write-out '%{http_code}' --output "$token_response" \
		--request POST "$JAMF_URL/api/v1/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--header "Accept: application/json" \
		--data-urlencode "client_id=$JAMF_CLIENT_ID" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret@$SECRET_FILE" || true)"
	token_status="${token_status:-000}"

	[[ "$token_status" =~ ^2[0-9][0-9]$ ]] || {
		runFailureReason="Failed to obtain a Jamf API access token (HTTP $token_status)."
		log "Error: Failed to obtain access token. HTTP code: $token_status"
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

# jamfRequest METHOD PATH [JSON_BODY]
# Sets http_status and leaves the response body in $RESPONSE_FILE. A 401 means
# the token expired (a long list can outlive it), so it gets a new token and
# retries once. A 403 (missing privilege) is handled by the caller.
jamfRequest() {
	local method="$1" path="$2" body="${3:-}" attempt
	local -a args
	for attempt in 1 2; do
		args=(--silent --show-error --retry 2 --retry-delay 2
			--write-out '%{http_code}' --output "$RESPONSE_FILE" -K -
			--request "$method" "$JAMF_URL$path"
			--header "Accept: application/json")
		if [[ -n "$body" ]]; then
			args+=(--header "Content-Type: application/json" --data "$body")
		fi
		http_status="$(bearerConfig | curl "${args[@]}" || true)"
		http_status="${http_status:-000}"
		if [[ "$http_status" == "401" && "$attempt" == "1" ]]; then
			log "Access token rejected (401). Requesting a new token and retrying once."
			getAccessToken
			continue
		fi
		break
	done
}

recordFailure() {
	countFailure=$((countFailure + 1))
	failureSerial+=("$1")
	log "$2"
}

# Stops the whole run when the API Client lacks a privilege: every remaining
# serial number would fail the same way.
stopForPrivilege() {
	runFailureReason="Forbidden (403) for serial $1. The API Role needs Read Computers and Update Computers; remaining serial numbers were not attempted."
	log "Error: Forbidden (403). The API Role lacks a required privilege (Read Computers, Update Computers)."
	exit 1
}

processSerial() {
	local serialNumber="$1" totalCount computerId currentManaged

	# The serial goes into the request URL, so accept only letters and digits.
	if [[ ! "$serialNumber" =~ ^[A-Za-z0-9]+$ ]]; then
		recordFailure "$serialNumber" "Skipped: '$serialNumber' is not a valid serial number (letters and digits only)."
		return
	fi

	jamfRequest GET "/api/v4/computers-inventory?section=GENERAL&page-size=2&filter=hardware.serialNumber==$serialNumber"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) recordFailure "$serialNumber" "Failed lookup for serial $serialNumber. HTTP code: 403"; stopForPrivilege "$serialNumber" ;;
		*) recordFailure "$serialNumber" "Failed to look up serial $serialNumber. HTTP code: $http_status"; return ;;
	esac

	totalCount="$(plutil -extract totalCount raw "$RESPONSE_FILE" 2>/dev/null || true)"
	if [[ "$totalCount" == "0" ]]; then
		recordFailure "$serialNumber" "Not found: No computer with serial: $serialNumber"
		return
	elif [[ "$totalCount" != "1" ]]; then
		# More than one record (or an unreadable response): do not guess which to change.
		recordFailure "$serialNumber" "Skipped: serial $serialNumber matched '${totalCount:-unknown}' records; expected exactly 1."
		return
	fi

	computerId="$(plutil -extract results.0.id raw "$RESPONSE_FILE" 2>/dev/null || true)"
	if [[ -z "$computerId" ]]; then
		recordFailure "$serialNumber" "Failed: no computer ID in the lookup response for serial $serialNumber."
		return
	fi
	# If the current value can't be read it stays empty and the update proceeds.
	currentManaged="$(plutil -extract results.0.general.remoteManagement.managed raw "$RESPONSE_FILE" 2>/dev/null || true)"

	if [[ "$currentManaged" == "$MANAGED_VALUE" ]]; then
		countUnchanged=$((countUnchanged + 1))
		unchangedSerial+=("$serialNumber")
		log "Skipped: serial $serialNumber (Jamf ID $computerId) is already managed=$MANAGED_VALUE."
		return
	fi

	if [[ "$DRY_RUN" == "yes" ]]; then
		countChanged=$((countChanged + 1))
		changedSerial+=("$serialNumber")
		log "DRY_RUN: would set managed=$MANAGED_VALUE for serial $serialNumber (Jamf ID $computerId, currently ${currentManaged:-unknown})."
		return
	fi

	jamfRequest PATCH "/api/v4/computers-inventory-detail/$computerId" "{\"general\":{\"managed\":$MANAGED_VALUE}}"
	case "$http_status" in
		200|204)
			countChanged=$((countChanged + 1))
			changedSerial+=("$serialNumber")
			log "Set managed=$MANAGED_VALUE for serial $serialNumber (Jamf ID $computerId)."
			;;
		403) recordFailure "$serialNumber" "Failed update for serial $serialNumber. HTTP code: 403"; stopForPrivilege "$serialNumber" ;;
		*) recordFailure "$serialNumber" "Failed to update serial $serialNumber (Jamf ID $computerId). HTTP code: $http_status" ;;
	esac
}

processSerialNumbers() {
	local line serialNumber
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: checking computers by serial number. Nothing will be changed."
	else
		log "Setting managed=$MANAGED_VALUE by serial number..."
	fi
	# The file is read on file descriptor 3 so nothing run inside the loop can
	# consume it through stdin.
	while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
		# Drop a Windows carriage return and surrounding whitespace.
		serialNumber="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z "$serialNumber" || "$serialNumber" == \#* ]] && continue
		processSerial "$serialNumber"
	done 3< "$serialNumberList"
}

main() {
	getAccessToken
	processSerialNumbers
	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
