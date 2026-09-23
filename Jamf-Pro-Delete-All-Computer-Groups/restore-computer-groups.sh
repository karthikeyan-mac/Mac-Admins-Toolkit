#!/bin/bash

# Restore smart and static computer groups in Jamf Pro from backup files.
# Author: Karthikeyan Marappan
#
# Companion to delete-all-computer-groups.sh. That script saves each group as
# <prod|dev>-<smart|static>-<name>-<id>.json (plus <same name>.members.json for a
# static group) before deleting it. This script creates those groups again.
#
# Key Functionalities:
# - Reads one backup file, or every *.json file in a backup folder (not
#   recursive, *.members.json files are read together with their group file),
#   from RESTORE_PATH.
# - Only restores files whose name starts with the selected environment and a
#   group type (prod-smart-, prod-static-, dev-smart-, dev-static-). If any
#   file does not, the script stops before it signs in, so a dev backup cannot
#   be restored into prod.
# - Lists the groups that already exist (smart and static, paged, modern Jamf
#   Pro API) and skips a backup whose group name already exists, so nothing is
#   duplicated and nothing existing is changed.
# - Creates a smart group with POST /api/v3/computer-groups/smart-groups
#   (name, description, site, criteria) and a static group with
#   POST /api/v3/computer-groups/static-groups (name, description, site and
#   the member computer IDs from the .members.json file). Static groups are
#   created first, because a smart group's criteria can refer to a static one.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any group failed or the run stopped early.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions:
#   - Read Smart Computer Groups, Create Smart Computer Groups
#   - Read Static Computer Groups, Create Static Computer Groups
#
# Usage:
# - RESTORE_PATH (required): a backup folder or one .json group file. Prompted
#   for if not set on an interactive run.
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that restores (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script reports what it WOULD restore or
#   skip, without creating anything. Set DRY_RUN=no to restore.
# - A real run prints a disclaimer. An interactive run then asks you to type
#   RESTORE after showing how many groups it will create. A non-interactive
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

SCRIPT_NAME="restore-computer-groups.sh"
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
SCRIPT_RESTORE_PATH=""                                    # backup folder or one .json file; empty = ask
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_restore_computer_groups.log"
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

promptValue RESTORE_PATH "Backup folder or .json file to restore"

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
[[ -n "$RESTORE_PATH" ]] || { echo "ERROR: Set RESTORE_PATH to a backup folder or a .json file." >&2; exit 1; }
[[ -d "$RESTORE_PATH" || -f "$RESTORE_PATH" ]] || { echo "ERROR: RESTORE_PATH '$RESTORE_PATH' is not a folder or file." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

# Collect the group files: one file, or every *.json directly inside a folder.
# A *.members.json file belongs to the group file next to it, so it is not a
# group file itself.
restoreFile=()
if [[ -d "$RESTORE_PATH" ]]; then
	while IFS= read -r line; do
		restoreFile+=("$line")
	done < <(find "$RESTORE_PATH" -maxdepth 1 -type f -name '*.json' ! -name '*.members.json' | sort)
else
	restoreFile+=("$RESTORE_PATH")
fi
[[ ${#restoreFile[@]} -gt 0 ]] || { echo "ERROR: No group .json files found in '$RESTORE_PATH'." >&2; exit 1; }

# Environment guard: every file must be named <selected env>-smart-...json or
# <selected env>-static-...json. Stop before signing in if any is not, so a dev
# backup cannot be restored into prod.
wrongName=0
for line in "${restoreFile[@]}"; do
	case "$(basename "$line")" in
		"$JAMF_ENV"-smart-*.json | "$JAMF_ENV"-static-*.json) ;;
		*) wrongName=$((wrongName + 1)) ;;
	esac
done
if [[ "$wrongName" -gt 0 ]]; then
	echo "ERROR: $wrongName of ${#restoreFile[@]} file(s) in '$RESTORE_PATH' are not named ${JAMF_ENV}-smart-*.json or ${JAMF_ENV}-static-*.json." >&2
	echo "       Backups are named <prod|dev>-<smart|static>-<name>-<id>.json. Use the matching environment, or the right folder." >&2
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
			echo "#  DRY_RUN=no: this WILL CREATE up to ${#restoreFile[@]} computer group(s) in PRODUCTION."
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
		echo " DISCLAIMER: THIS SCRIPT CREATES COMPUTER GROUPS"
		echo
		echo " - It creates a computer group in Jamf Pro from each backup file it"
		echo "   is given (${#restoreFile[@]} file(s) found) on:"
		echo "   $JAMF_URL"
		echo " - A group whose name already exists is skipped, not changed."
		echo " - A restored group gets a new ID. Policies, profiles and other"
		echo "   objects that were scoped to the old group are NOT re-linked."
		echo " - A static group gets the member computers saved in its backup. If"
		echo "   any of those computers no longer exists, Jamf Pro rejects the"
		echo "   group and it is reported as failed."
		echo " - A smart group is recalculated by Jamf Pro after it is created."
		echo "   Its criteria may refer to another group that does not exist yet."
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
restoredGroup=()
skippedGroup=()
failureGroup=()
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
	log "Summary for computer group restore"
	log "Backup files found: $countFiles"
	log "Skipped (name already exists or repeated in this run): $countSkipped"
	if [[ ${#skippedGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${skippedGroup[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would restore (DRY_RUN=yes, nothing was created): $countRestored"
	else
		log "Restored: $countRestored"
	fi
	if [[ ${#restoredGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${restoredGroup[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed: $countFailure"
	if [[ ${#failureGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${failureGroup[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-restore-groups.XXXXXX")"
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

# jamfRequest METHOD PATH [JSON_BODY_FILE]
# Sets http_status and leaves the response body in $RESPONSE_FILE. With
# JSON_BODY_FILE the file is sent as the JSON request body, and curl does NOT
# retry (a repeated POST after a server error could create the group twice). A
# 401 means the token expired, so it gets a new token and retries once; the
# request was not processed. A 403 (missing privilege) is handled by the caller.
jamfRequest() {
	local method="$1" path="$2" body="${3:-}" attempt
	local extra=() retry=(--retry 2 --retry-delay 2)
	if [[ -n "$body" ]]; then
		extra=(--header "Content-Type: application/json" --data-binary "@$body")
		retry=()
	fi
	for attempt in 1 2; do
		http_status="$(bearerConfig | curl --silent --show-error ${retry[@]+"${retry[@]}"} \
			--write-out '%{http_code}' --output "$RESPONSE_FILE" -K - \
			--request "$method" "$JAMF_URL$path" \
			--header "Accept: application/json" ${extra[@]+"${extra[@]}"} || true)"
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
# group would fail the same way.
stopForPrivilege() {
	runFailureReason="Forbidden (403) while $1. The API Role needs Read and Create for Smart and Static Computer Groups; remaining groups were not attempted."
	log "Error: Forbidden (403) while $1. The API Role lacks a required privilege."
	exit 1
}

# Names of the groups that exist now (bash 3.2 has no associative arrays). Smart
# and static groups are checked together: Jamf Pro rejects a duplicate name.
existingName=()

# listExisting TYPE   (TYPE is "smart" or "static"): adds every group name to
# existingName. Paged, like the delete tool.
listExisting() {
	local kind="$1" page=0 total=0 seen=0 rows i name
	while :; do
		jamfRequest GET "/api/v3/computer-groups/$kind-groups?page=$page&page-size=100&sort=id:asc"
		case "$http_status" in
			2[0-9][0-9]) ;;
			403) stopForPrivilege "listing $kind computer groups" ;;
			*)
				runFailureReason="Failed to list $kind computer groups (HTTP $http_status). Nothing was created."
				log "Error: Failed to list $kind computer groups. HTTP code: $http_status"
				exit 1
				;;
		esac
		# A missing totalCount means the response is not what we expect: stop
		# rather than treat it as "no groups" and risk creating duplicates.
		total="$(plutil -extract totalCount raw "$RESPONSE_FILE" 2>/dev/null || true)"
		[[ "$total" =~ ^[0-9]+$ ]] || {
			runFailureReason="Unreadable $kind computer group list from Jamf Pro."
			log "Error: Could not read totalCount for $kind computer groups."
			exit 1
		}
		rows="$(plutil -extract results raw "$RESPONSE_FILE" 2>/dev/null || echo 0)"
		[[ "$rows" =~ ^[0-9]+$ ]] || rows=0
		for ((i = 0; i < rows; i++)); do
			name="$(plutil -extract "results.$i.name" raw "$RESPONSE_FILE" 2>/dev/null || true)"
			existingName+=("$name")
		done
		seen=$((seen + rows))
		# Stop at the reported total, or on an empty page (avoids looping forever).
		[[ "$rows" -gt 0 && "$seen" -lt "$total" ]] || break
		page=$((page + 1))
	done
}

# nameExists NAME: true if a group with exactly this name already exists.
nameExists() {
	local entry
	# ${arr[@]+...} keeps an empty array safe under "set -u" on macOS bash 3.2.
	for entry in ${existingName[@]+"${existingName[@]}"}; do
		[[ "$entry" == "$1" ]] && return 0
	done
	return 1
}

# prepareFile FILE BODY_OUT
# Builds the JSON request body in BODY_OUT from a backup, and sets groupKind,
# groupName and memberCount. Only the fields the create endpoints document are
# sent (name, description, siteId, and criteria or assignments), so nothing else
# in the backup (such as the old ID) reaches Jamf Pro. Returns non-zero, after
# setting prepareError, if the backup is not usable.
groupKind=""
groupName=""
memberCount=0
prepareError=""
prepareFile() {
	local file="$1" out="$2" base plist value members n i id ids=""
	base="$(basename "$file")"
	groupKind="static"
	[[ "$base" == "$JAMF_ENV"-smart-* ]] && groupKind="smart"
	groupName=""
	memberCount=0
	prepareError=""
	plist="$WORK_DIR/body.plist"
	rm -f "$plist"

	groupName="$(plutil -extract name raw "$file" 2>/dev/null || true)"
	[[ -n "$groupName" ]] || { prepareError="no group name in the file"; return 1; }
	plutil -create xml1 "$plist"
	plutil -insert name -string "$groupName" "$plist"

	# Optional fields: a null or missing value is left out.
	value="$(plutil -extract description raw "$file" 2>/dev/null || true)"
	[[ -z "$value" ]] || plutil -insert description -string "$value" "$plist"
	value="$(plutil -extract siteId raw "$file" 2>/dev/null || true)"
	[[ -z "$value" ]] || plutil -insert siteId -string "$value" "$plist"

	if [[ "$groupKind" == "smart" ]]; then
		if value="$(plutil -extract criteria json -o - "$file" 2>/dev/null)" && [[ -n "$value" ]]; then
			plutil -insert criteria -json "$value" "$plist"
		fi
	else
		# The members come from the .members.json file next to the group file.
		members="${file%.json}.members.json"
		[[ -f "$members" ]] || { prepareError="the members file ${members##*/} is missing"; return 1; }
		n="$(plutil -extract computer_group.computers raw "$members" 2>/dev/null || true)"
		[[ "$n" =~ ^[0-9]+$ ]] || { prepareError="the members file is unreadable"; return 1; }
		for ((i = 0; i < n; i++)); do
			id="$(plutil -extract "computer_group.computers.$i.id" raw "$members" 2>/dev/null || true)"
			[[ "$id" =~ ^[0-9]+$ ]] || { prepareError="a member has no valid computer ID"; return 1; }
			ids+="${ids:+,}\"$id\""
		done
		plutil -insert assignments -json "[$ids]" "$plist"
		memberCount="$n"
	fi
	plutil -convert json -o "$out" "$plist"
}

# rejectGroup LABEL KIND: records a group that Jamf Pro rejected with HTTP 400.
rejectGroup() {
	countFailure=$((countFailure + 1))
	failureGroup+=("$1 (rejected, HTTP 400)")
	log "Not restored: Jamf Pro rejected $2 computer group $1 (HTTP 400). For a static group, a member computer may no longer exist; for a smart group, check its criteria and any group it refers to."
}

# createGroup INDEX DEFER
# DEFER is "yes" for a smart group in the retry passes: a smart group whose
# criteria refer to another group that does not exist yet may be rejected (400),
# so that answer is not final. It returns 2 and records nothing, and the caller
# tries again after the other groups have been created.
createGroup() {
	local i="$1" defer="$2" label="${restoreLabel[$1]}" kind="${restoreKind[$1]}" newId=""
	jamfRequest POST "/api/v3/computer-groups/$kind-groups" "$WORK_DIR/body-$i.json"
	case "$http_status" in
		200|201)
			newId="$(plutil -extract id raw "$RESPONSE_FILE" 2>/dev/null || true)"
			[[ -n "$newId" ]] || newId="unknown"
			countRestored=$((countRestored + 1))
			restoredGroup+=("$label (new ID: $newId)")
			log "Restored $kind computer group $label (new ID: $newId)"
			;;
		403)
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (HTTP 403)")
			stopForPrivilege "creating $kind computer group $label"
			;;
		422)
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (name already exists, HTTP 422)")
			log "Not restored: $kind computer group $label was rejected because the name already exists (HTTP 422)."
			;;
		400)
			[[ "$defer" == "yes" ]] && return 2
			rejectGroup "$label" "$kind"
			;;
		*)
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (HTTP $http_status)")
			log "Failed to restore $kind computer group $label. HTTP code: $http_status"
			;;
	esac
}

# Parallel lists for every backup file (bash 3.2 has no associative arrays).
restoreAction=()   # "restore", "exists" or "invalid"
restoreKind=()
restoreLabel=()

main() {
	getAccessToken
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: checking ${#restoreFile[@]} backup file(s). Nothing will be created."
	else
		log "Checking ${#restoreFile[@]} backup file(s) before restoring..."
	fi
	countFiles=${#restoreFile[@]}
	listExisting smart
	listExisting static
	log "Found ${#existingName[@]} existing computer group(s) in Jamf Pro."

	# Decide what to do with each file BEFORE creating anything.
	local i file base label countToRestore=0
	for ((i = 0; i < countFiles; i++)); do
		file="${restoreFile[$i]}"
		base="$(basename "$file")"
		if ! prepareFile "$file" "$WORK_DIR/body-$i.json"; then
			restoreAction+=("invalid"); restoreKind+=("$groupKind"); restoreLabel+=("$base")
			countFailure=$((countFailure + 1))
			failureGroup+=("$base ($prepareError)")
			log "Not restored: $base: $prepareError."
			continue
		fi
		label="$groupName ($base)"
		[[ "$groupKind" == "static" ]] && label="$groupName ($base, $memberCount member(s))"
		restoreKind+=("$groupKind")
		restoreLabel+=("$label")
		if nameExists "$groupName"; then
			restoreAction+=("exists")
			countSkipped=$((countSkipped + 1))
			skippedGroup+=("$label")
			log "Skipping $base: a group named \"$groupName\" already exists (in Jamf Pro, or from an earlier file in this run)."
		else
			restoreAction+=("restore")
			countToRestore=$((countToRestore + 1))
			# Count this name as taken so a second file with the same group name
			# in this run is skipped instead of creating a duplicate.
			existingName+=("$groupName")
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

	# Static groups first: a smart group's criteria can refer to a static group.
	local pass
	for pass in static smart; do
		for ((i = 0; i < countFiles; i++)); do
			[[ "${restoreAction[$i]}" == "restore" && "${restoreKind[$i]}" == "$pass" ]] || continue
			if [[ "$DRY_RUN" == "yes" ]]; then
				countRestored=$((countRestored + 1))
				restoredGroup+=("${restoreLabel[$i]}")
				log "DRY_RUN: would restore $pass computer group ${restoreLabel[$i]}"
			elif [[ "$pass" == "static" ]]; then
				createGroup "$i" no
			fi
		done
	done

	# Smart groups can refer to other smart groups (member of / not member of), so
	# the order matters. A smart group Jamf Pro rejects with 400 is kept aside and
	# tried again once the others exist. The loop ends when everything is created,
	# or when a whole pass creates nothing new; what is left is then reported as
	# failed. (A dry run cannot show this: it creates nothing.)
	if [[ "$DRY_RUN" == "no" ]]; then
		local pending=() next=() rc
		for ((i = 0; i < countFiles; i++)); do
			[[ "${restoreAction[$i]}" == "restore" && "${restoreKind[$i]}" == "smart" ]] && pending+=("$i")
		done
		while [[ ${#pending[@]} -gt 0 ]]; do
			next=()
			for i in "${pending[@]}"; do
				rc=0
				createGroup "$i" yes || rc=$?
				[[ "$rc" -eq 2 ]] && next+=("$i")
			done
			if [[ ${#next[@]} -eq ${#pending[@]} ]]; then
				# No progress: these are genuinely rejected.
				for i in "${next[@]}"; do rejectGroup "${restoreLabel[$i]}" smart; done
				break
			fi
			if [[ ${#next[@]} -gt 0 ]]; then
				log "${#next[@]} smart group(s) were rejected; trying them again now that other groups exist."
			fi
			pending=(${next[@]+"${next[@]}"})
		done
	fi

	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
