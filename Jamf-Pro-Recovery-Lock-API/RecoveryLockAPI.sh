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
# - Runs as root from a Jamf policy (or from a terminal for a standalone run).
#   Policy parameters:
#     4 = Set or Remove (or export LOCK_MODE for a standalone run)
#     5 = prod or dev (or export JAMF_ENV, or set SCRIPT_JAMF_ENV below)
#   The environment is never chosen silently: an unattended run with none
#   chosen stops with an error.
# - Values (URL, client ID, client secret) are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret),
#   then a prompt (terminal only; client ID and secret are entered with no
#   echo). See the main README for the shared configuration.
# - The plist is plain text and, on a managed Mac, is readable by whoever can
#   read the file. Keep it root-owned and mode 600 (a warning is printed
#   otherwise). Jamf policy script parameters are visible in policy logs, so
#   do not pass the client secret as a policy parameter.
# - Selecting prod prints a warning. On a terminal you must type PROD to
#   continue; an unattended (policy) run prints the warning and continues.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
# - For details, refer:
#   https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html

SCRIPT_NAME="RecoveryLockAPI.sh"
SCRIPT_VERSION="2.0.0"

set -euo pipefail
umask 077

# First line of output identifies the script and version.
echo "$SCRIPT_NAME - $SCRIPT_VERSION"

# Value order: environment variable, then these script defaults, then the
# preference domain below, then (for anything still empty) an interactive
# prompt. Keep secrets out of this file.
SCRIPT_JAMF_ENV=""      # prod | dev ; empty = ask (policy parameter 5 or JAMF_ENV overrides)
SCRIPT_JAMF_URL=""      # e.g. https://yourorg.jamfcloud.com
# Fallback lockMode when neither Jamf policy parameter 4 nor LOCK_MODE is set.
SCRIPT_LOCK_MODE="Set"

# Shared toolkit preference domain (~/Library/Preferences/<domain>.plist).
# Shared keys are documented in the main README. DRY_RUN is deliberately NOT
# read from it, so a stored value can never turn a dry run into a real run.
PREF_DOMAIN="com.karthikmac.macadminstoolkit"

# --- Select the environment (prod or dev) ------------------------------------
# JAMF_ENV (environment variable), then SCRIPT_JAMF_ENV, then a prompt. Never
# defaulted silently: with no choice on a non-interactive run, the script stops.
ENV_SOURCE="JAMF_ENV variable"
JAMF_ENV="${JAMF_ENV:-}"
if [[ -n "${5:-}" ]]; then
	JAMF_ENV="$5"
	ENV_SOURCE="Jamf policy parameter 5"
fi
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
JAMF_URL="${JAMF_URL%/}"

# lockMode: Jamf policy parameter 4 takes priority, then LOCK_MODE from the
# environment, then the hard-coded SCRIPT_LOCK_MODE default above. It is
# validated (before any API calls) further down.
if [[ -n "${4:-}" ]]; then
	lockMode="$4"
	lockSource="policy parameter 4"
elif [[ -n "${LOCK_MODE:-}" ]]; then
	lockMode="$LOCK_MODE"
	lockSource="environment"
else
	lockMode="$SCRIPT_LOCK_MODE"
	lockSource="script default"
fi
SETTING_SOURCES+="lockMode=$lockSource, "

# Lines 2-3: the environment, and where each setting is taken from (values are
# never printed). If the environment was prompted for, that prompt comes first.
ENV_LINE="Environment: $JAMF_ENV (from $ENV_SOURCE). Settings sources (order: environment, script default, plist $PREF_DOMAIN, then prompt if still empty):"
SOURCES_LINE="  ${SETTING_SOURCES%, }"
echo "$ENV_LINE"
echo "$SOURCES_LINE"

# The plist can hold credentials in plain text; warn if other users can read it.
# Checked in the current user's and the system-wide preferences folders.
for prefFile in "${HOME:-/var/root}/Library/Preferences/$PREF_DOMAIN.plist" "/Library/Preferences/$PREF_DOMAIN.plist"; do
	if [[ -f "$prefFile" ]]; then
		prefMode=$(stat -f '%Lp' "$prefFile")
		if [[ "$prefMode" != "600" && "$prefMode" != "400" ]]; then
			echo "WARNING: $prefFile is mode $prefMode and may hold credentials. Run: chmod 600 \"$prefFile\"" >&2
		fi
	fi
done

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
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }
case "$lockMode" in
	Set|Remove) ;;
	*)
		echo "ERROR: Invalid lockMode '$lockMode'. Provide 'Set' or 'Remove' as Jamf policy parameter 4, export LOCK_MODE, or fix SCRIPT_LOCK_MODE." >&2
		exit 1
		;;
esac

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
		echo "#  Action : $lockMode Recovery Lock on this Mac"
		echo "################################################################"
	} >&2
	# A terminal run must confirm. An unattended (policy) run cannot be asked, so
	# the warning above (visible in the policy log) is all it gets.
	if [[ -t 0 ]]; then
		read -rp "Type PROD to continue (anything else cancels): " confirmProd
		[[ "$confirmProd" == "PROD" ]] || { echo "Cancelled. Nothing was changed."; exit 0; }
	fi
fi

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
