#!/bin/bash

# Restore macOS configuration profiles into Jamf Pro from backup XML files.
# Author: Karthikeyan Marappan
#
# Companion to delete-all-macos-config-profiles.sh. That script saves each
# profile as <prod|dev>-<name>-<id>.xml (IDs removed) before deleting it. This
# script creates those profiles again.
#
# *** A restored profile is applied to its scope straight away. A profile
# *** scoped to All Computers is deployed to every Mac. Review the dry run.
#
# Key Functionalities:
# - Reads one backup file, or every *.xml file in a backup folder (not
#   recursive), from RESTORE_PATH.
# - Only restores files whose name starts with the selected environment
#   (prod- or dev-), so a dev backup cannot be restored into prod by accident.
#   If any file belongs to another environment the script stops before it
#   signs in.
# - Removes any <id> element from the XML before sending it (already done in a
#   backup, so this only matters for raw exports), then creates the profile
#   with POST /JSSResource/osxconfigurationprofiles/id/0 (Classic API).
# - Lists the profiles that already exist (GET /JSSResource/osxconfigurationprofiles)
#   and skips a backup whose profile name already exists, so nothing is
#   duplicated and nothing existing is changed.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any profile failed or the run stopped early.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions (Classic API privileges):
#   - Read macOS Configuration Profiles
#   - Create macOS Configuration Profiles
#
# Usage:
# - RESTORE_PATH (required): a backup folder or one .xml file. Prompted for if
#   not set on an interactive run.
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that restores (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script reports what it WOULD restore or
#   skip, without creating anything. Set DRY_RUN=no to restore.
# - A real run prints a disclaimer. An interactive run then asks you to type
#   RESTORE after showing how many profiles it will create. A non-interactive
#   real run needs JAMF_RESTORE_CONFIRM=RESTORE.
# - Credentials: never hard-code them. Values are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret;
#   plain text, keep it chmod 600), then a prompt (client ID and secret are
#   entered with no echo). See the main README for the shared configuration.
# - Override LOG_FILE via the environment; otherwise the default below applies.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
#
# *** Test against a non-production Jamf Pro environment first.

SCRIPT_NAME="restore-macos-config-profiles.sh"
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
SCRIPT_RESTORE_PATH=""                                    # backup folder or one .xml file; empty = ask
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_restore_macos_config_profiles.log"
SCRIPT_DRY_RUN="no"                                      # yes = report only, create nothing

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
loadSetting RESTORE_PATH "" "$SCRIPT_RESTORE_PATH"
loadSetting LOG_FILE "" "$SCRIPT_LOG_FILE"
JAMF_URL="${JAMF_URL%/}"
DRY_RUN="${DRY_RUN:-$SCRIPT_DRY_RUN}"
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

promptValue RESTORE_PATH "Backup folder or .xml file to restore"

# cleanPath VALUE: makes a path that was typed or pasted usable. Trims spaces,
# removes one pair of surrounding quotes, expands a leading ~, and, if nothing
# exists at that path, retries with shell escapes removed (Terminal tab
# completion and drag and drop write "My\ File", and read keeps the backslash).
# Backup file names never contain a backslash, so this cannot change a real path.
cleanPath() {
	local p="$1" unescaped
	p="${p#"${p%%[![:space:]]*}"}"
	p="${p%"${p##*[![:space:]]}"}"
	case "$p" in
		\"*\") p="${p#\"}"; p="${p%\"}" ;;
		\'*\') p="${p#\'}"; p="${p%\'}" ;;
	esac
	if [[ "$p" == \~ || "$p" == \~/* ]]; then p="$HOME${p#\~}"; fi
	if [[ ! -e "$p" && "$p" == *\\* ]]; then
		unescaped="$(printf '%s' "$p" | sed 's/\\\(.\)/\1/g')"
		if [[ -e "$unescaped" ]]; then p="$unescaped"; fi
	fi
	printf '%s' "$p"
}
RESTORE_PATH="$(cleanPath "$RESTORE_PATH")"

promptValue JAMF_URL "Jamf Pro URL (e.g. https://yourorg.jamfcloud.com)"
JAMF_URL="${JAMF_URL%/}"
promptValue JAMF_CLIENT_ID "API Client ID" secret
promptValue JAMF_CLIENT_SECRET "API Client secret" secret

# --- Input validation --------------------------------------------------------
[[ -n "$JAMF_URL" ]] || { echo "ERROR: Set JAMF_URL (e.g. https://yourorg.jamfcloud.com)." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
[[ -n "$JAMF_CLIENT_ID" ]] || { echo "ERROR: Set JAMF_CLIENT_ID." >&2; exit 1; }
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET." >&2; exit 1; }
[[ "$DRY_RUN" == "yes" || "$DRY_RUN" == "no" ]] || { echo "ERROR: DRY_RUN must be yes or no." >&2; exit 1; }
[[ -n "$RESTORE_PATH" ]] || { echo "ERROR: Set RESTORE_PATH to a backup folder or an .xml file." >&2; exit 1; }
[[ -d "$RESTORE_PATH" || -f "$RESTORE_PATH" ]] || { echo "ERROR: RESTORE_PATH '$RESTORE_PATH' is not a folder or file." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

# Collect the backup files: one file, or every *.xml directly inside a folder.
restoreFile=()
if [[ -d "$RESTORE_PATH" ]]; then
	while IFS= read -r line; do
		restoreFile+=("$line")
	done < <(find "$RESTORE_PATH" -maxdepth 1 -type f -name '*.xml' | sort)
else
	restoreFile+=("$RESTORE_PATH")
fi
[[ ${#restoreFile[@]} -gt 0 ]] || { echo "ERROR: No .xml files found in '$RESTORE_PATH'." >&2; exit 1; }

# Environment guard: every file must be named <selected env>-...xml. Stop before
# signing in if any is not, so a dev backup cannot be restored into prod.
wrongEnv=0
for line in "${restoreFile[@]}"; do
	[[ "$(basename "$line")" == "$JAMF_ENV"-* ]] || wrongEnv=$((wrongEnv + 1))
done
if [[ "$wrongEnv" -gt 0 ]]; then
	echo "ERROR: $wrongEnv of ${#restoreFile[@]} file(s) in '$RESTORE_PATH' are not named ${JAMF_ENV}-*.xml." >&2
	echo "       Backups are named <prod|dev>-<name>-<id>.xml. Use the matching environment, or the right folder." >&2
	exit 1
fi

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
			echo "#  DRY_RUN=yes: read-only checks, nothing will be created."
		else
			echo "#  DRY_RUN=no: this WILL CREATE up to ${#restoreFile[@]} macOS configuration profile(s) in"
			echo "#  PRODUCTION, applied to their scope straight away."
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

# --- Restore disclaimer and confirmation -------------------------------------
# Shown on every real run (dev or prod). A dry run changes nothing, so it skips
# this. An interactive run confirms again, with the count, once the files are
# checked. A non-interactive run must opt in with JAMF_RESTORE_CONFIRM=RESTORE.
if [[ "$DRY_RUN" == "no" ]]; then
	{
		echo
		echo "================================================================"
		echo " DISCLAIMER: THIS SCRIPT CREATES CONFIGURATION PROFILES"
		echo
		echo " - It creates a macOS configuration profile in Jamf Pro from each"
		echo "   backup file it is given (${#restoreFile[@]} file(s) found) on:"
		echo "   $JAMF_URL"
		echo " - A restored profile is applied to its scope straight away. A"
		echo "   profile scoped to All Computers is deployed to every Mac."
		echo " - A profile whose name already exists is skipped, not changed."
		echo " - Scope is restored by name (a backup has no IDs). Groups or"
		echo "   computers that no longer exist may make Jamf Pro reject the"
		echo "   profile or leave its scope smaller. Check each restored profile."
		echo " - A restored profile gets a new ID."
		echo " - Run with DRY_RUN=yes first. Provided as is, with no warranty."
		echo "   Test in a non-production Jamf Pro first."
		echo "================================================================"
	} >&2
	if [[ ! -t 0 && "${JAMF_RESTORE_CONFIRM:-}" != "RESTORE" ]]; then
		echo "ERROR: A non-interactive real run requires JAMF_RESTORE_CONFIRM=RESTORE." >&2
		exit 1
	fi
fi

mkdir -p "$(dirname "$logFile")"
touch "$logFile"
# Record the same first lines in the log file (console already showed them).
printf '%s\n%s\n%s\n' "$BANNER" "$ENV_LINE" "$SOURCES_LINE" >> "$logFile"

countFiles=0
countRestored=0
countSkipped=0
countFailure=0
restoredProfile=()
skippedProfile=()
failureProfile=()
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
	log "Summary for macOS configuration profile restore"
	log "Backup files found: $countFiles"
	log "Skipped (name already exists or repeated in this run): $countSkipped"
	if [[ ${#skippedProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${skippedProfile[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would restore (DRY_RUN=yes, nothing was created): $countRestored"
	else
		log "Restored: $countRestored"
	fi
	if [[ ${#restoredProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${restoredProfile[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed: $countFailure"
	if [[ ${#failureProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${failureProfile[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-restore-profiles.XXXXXX")"
SECRET_FILE="$WORK_DIR/client-secret"
RESPONSE_FILE="$WORK_DIR/response.out"
POST_FILE="$WORK_DIR/post.xml"
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

# jamfRequest METHOD PATH ACCEPT [XML_BODY_FILE]
# Sets http_status and leaves the response body in $RESPONSE_FILE. ACCEPT is the
# media type to ask for. With XML_BODY_FILE the file is sent as the XML request
# body, and curl does NOT retry (a repeated POST after a server error could
# create the profile twice). A 401 means the token expired, so it gets a new
# token and retries once; the request was not processed. A 403 (missing
# privilege) is handled by the caller.
jamfRequest() {
	local method="$1" path="$2" accept="$3" body="${4:-}" attempt
	local extra=() retry=(--retry 2 --retry-delay 2)
	if [[ -n "$body" ]]; then
		extra=(--header "Content-Type: application/xml" --data-binary "@$body")
		retry=()
	fi
	for attempt in 1 2; do
		http_status="$(bearerConfig | curl --silent --show-error ${retry[@]+"${retry[@]}"} \
			--write-out '%{http_code}' --output "$RESPONSE_FILE" -K - \
			--request "$method" "$JAMF_URL$path" \
			--header "Accept: $accept" ${extra[@]+"${extra[@]}"} || true)"
		http_status="${http_status:-000}"
		if [[ "$http_status" == "401" && "$attempt" == "1" ]]; then
			log "Access token rejected (401). Requesting a new token and retrying once."
			getAccessToken
			continue
		fi
		break
	done
}

# Stops the whole run when the API Client lacks a privilege: every remaining
# profile would fail the same way.
stopForPrivilege() {
	runFailureReason="Forbidden (403) while $1. The API Role needs Read and Create for macOS Configuration Profiles; remaining profiles were not attempted."
	log "Error: Forbidden (403) while $1. The API Role lacks a required privilege."
	exit 1
}

# Names of the profiles that exist now (bash 3.2 has no associative arrays).
existingName=()

# listExisting: fills existingName from the Classic API (one response, no paging).
listExisting() {
	local rows i name
	jamfRequest GET "/JSSResource/osxconfigurationprofiles" "application/json"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "listing macOS configuration profiles" ;;
		*)
			runFailureReason="Failed to list macOS configuration profiles (HTTP $http_status). Nothing was created."
			log "Error: Failed to list macOS configuration profiles. HTTP code: $http_status"
			exit 1
			;;
	esac
	# A missing list key means the response is not what we expect: stop rather
	# than treat it as "no profiles" and risk creating duplicates.
	rows="$(plutil -extract os_x_configuration_profiles raw "$RESPONSE_FILE" 2>/dev/null || true)"
	[[ "$rows" =~ ^[0-9]+$ ]] || {
		runFailureReason="Unreadable macOS configuration profile list from Jamf Pro."
		log "Error: Could not read the macOS configuration profile list."
		exit 1
	}
	for ((i = 0; i < rows; i++)); do
		name="$(plutil -extract "os_x_configuration_profiles.$i.name" raw "$RESPONSE_FILE" 2>/dev/null || true)"
		existingName+=("$name")
	done
	log "Found ${#existingName[@]} existing macOS configuration profile(s) in Jamf Pro."
}

# nameExists NAME: true if a profile with exactly this name already exists.
nameExists() {
	local entry
	# ${arr[@]+...} keeps an empty array safe under "set -u" on macOS bash 3.2.
	for entry in ${existingName[@]+"${existingName[@]}"}; do
		[[ "$entry" == "$1" ]] && return 0
	done
	return 1
}

# xmlUnescape: decodes the five XML entities on stdin (used for the profile name).
xmlUnescape() {
	sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g'
}

# prepareFile FILE: writes the XML to send to $POST_FILE (every <id> element
# removed) and sets profileName from the file. Returns non-zero if the file is
# not a usable profile. The payload is an XML-escaped string, so it cannot hold
# a real <id> element.
profileName=""
prepareFile() {
	local text
	profileName=""
	sed -E '/^[[:space:]]*<id>[^<]*<\/id>[[:space:]]*$/d; s#<id>[^<]*</id>##g' "$1" > "$POST_FILE" || return 1
	grep -q '<os_x_configuration_profile' "$POST_FILE" && grep -q '<payloads>' "$POST_FILE" || return 1
	# The first <name> in the file is the profile's own name (first child of
	# <general>). Bash expansion is used because it takes the FIRST match even
	# when the whole file is on one line.
	text="$(cat "$POST_FILE")"
	[[ "$text" == *"<name>"* ]] || return 1
	text="${text#*<name>}"
	text="${text%%</name>*}"
	profileName="$(printf '%s' "$text" | xmlUnescape)"
	[[ -n "$profileName" ]]
}

# createProfile LABEL
# POSTs $POST_FILE. Reports the new ID when Jamf Pro returns one.
createProfile() {
	local label="$1" text newId=""
	jamfRequest POST "/JSSResource/osxconfigurationprofiles/id/0" "application/xml" "$POST_FILE"
	case "$http_status" in
		200|201)
			text="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
			if [[ "$text" == *"<id>"* ]]; then
				text="${text#*<id>}"
				newId="${text%%</id>*}"
			fi
			[[ "$newId" =~ ^[0-9]+$ ]] || newId="unknown"
			countRestored=$((countRestored + 1))
			restoredProfile+=("$label (new ID: $newId)")
			log "Restored macOS configuration profile $label (new ID: $newId)"
			;;
		403)
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (HTTP 403)")
			stopForPrivilege "creating macOS configuration profile $label"
			;;
		*)
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (HTTP $http_status)")
			log "Failed to restore macOS configuration profile $label. HTTP code: $http_status"
			;;
	esac
}

main() {
	getAccessToken
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: checking ${#restoreFile[@]} backup file(s). Nothing will be created."
	else
		log "Checking ${#restoreFile[@]} backup file(s) before restoring..."
	fi
	countFiles=${#restoreFile[@]}
	listExisting

	# Decide what to do with each file BEFORE creating anything.
	local i file label action=() name=() countToRestore=0
	for ((i = 0; i < countFiles; i++)); do
		file="${restoreFile[$i]}"
		label="$(basename "$file")"
		if ! prepareFile "$file"; then
			action+=("invalid")
			name+=("")
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (not a usable profile file)")
			log "Not restored: $label is not a usable profile file."
		elif nameExists "$profileName"; then
			action+=("exists")
			name+=("$profileName")
			countSkipped=$((countSkipped + 1))
			skippedProfile+=("$profileName ($label)")
			log "Skipping $label: a profile named \"$profileName\" already exists (in Jamf Pro, or from an earlier file in this run)."
		else
			action+=("restore")
			name+=("$profileName")
			countToRestore=$((countToRestore + 1))
			# Count this name as taken so a second file with the same profile name
			# in this run is skipped instead of creating a duplicate.
			existingName+=("$profileName")
		fi
	done

	if [[ "$countToRestore" -eq 0 ]]; then
		log "Nothing to restore."
		[[ "$countFailure" -eq 0 ]] || exit 1
		return
	fi

	# Last check before an interactive real run: show the counts and ask.
	if [[ "$DRY_RUN" == "no" && -t 0 ]]; then
		read -rp "Found $countFiles backup file(s), skipping $countSkipped, restoring $countToRestore. Type RESTORE to continue: " confirmRestore || confirmRestore=""
		[[ "$confirmRestore" == "RESTORE" ]] || {
			runFailureReason="Cancelled at the RESTORE confirmation. Nothing was created."
			log "Cancelled. Nothing was created."
			exit 1
		}
	fi

	for ((i = 0; i < countFiles; i++)); do
		[[ "${action[$i]}" == "restore" ]] || continue
		file="${restoreFile[$i]}"
		label="${name[$i]} ($(basename "$file"))"
		if [[ "$DRY_RUN" == "yes" ]]; then
			countRestored=$((countRestored + 1))
			restoredProfile+=("$label")
			log "DRY_RUN: would restore macOS configuration profile $label"
			continue
		fi
		# Rebuild the file to send (prepareFile wrote $POST_FILE for the last file).
		prepareFile "$file" || { countFailure=$((countFailure + 1)); failureProfile+=("$label (could not be prepared)"); continue; }
		createProfile "$label"
	done

	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
