#!/bin/bash

# Delete ALL smart and/or static computer groups in Jamf Pro.
# Author: Karthikeyan Marappan
#
# This is a delete-ALL tool. It does not take a list of groups to delete: it
# finds every computer group of the chosen type and deletes it, except groups
# named on the optional exclude list (EXCLUDE_LIST).
#
# Key Functionalities:
# - Lists every smart and/or static computer group with the modern Jamf Pro API
#   (GET /api/v3/computer-groups/smart-groups and /static-groups, paged), and
#   logs the ID, name and type of each one.
# - Keeps any group whose ID or exact name is on the exclude list (a text file,
#   one ID or name per line, # lines ignored). Excluded groups are never
#   backed up or deleted, in a dry run or a real run.
# - Before deleting anything on a real run, saves each group to a timestamped
#   folder in BACKUP_DIR, as <prod|dev>-<smart|static>-<name>-<id>.json:
#   - The group record (GET /api/v3/computer-groups/smart-groups/{id} or
#     /static-groups/{id}): name, description, site, and smart group criteria.
#     Jamf's v3 record for a static group does not list its members.
#   - For a static group, its members too, in <same name>.members.json
#     (GET /JSSResource/computergroups/id/{id}, Classic API).
#   restore-computer-groups.sh reads these files. A group whose backup fails
#   is not deleted.
# - Deletes each group with DELETE /api/v3/computer-groups/smart-groups/{id} or
#   /static-groups/{id}. Jamf Pro returns 422 for a group that is still in use
#   (for example scoped to a policy or profile); that group is reported and
#   left in place, and the run continues.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any group failed or the run stopped early.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions:
#   - Read Smart Computer Groups, Delete Smart Computer Groups
#   - Read Static Computer Groups, Delete Static Computer Groups
#
# Usage:
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that deletes (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script lists the groups and reports what it
#   WOULD delete, without deleting. Set DRY_RUN=no to delete.
# - A real run (dev or prod) prints a disclaimer. An interactive run then asks
#   you to type DELETE after showing how many groups it found. A
#   non-interactive real run needs JAMF_DELETE_CONFIRM=DELETE.
# - GROUP_TYPE is smart, static or all (default all).
# - EXCLUDE_LIST (optional) is a text file of group IDs or exact names to keep.
# - BACKUP_DIR is where the pre-delete backup folder is created (real runs).
# - Credentials: never hard-code them. Values are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret;
#   plain text, keep it chmod 600), then a prompt (client ID and secret are
#   entered with no echo). See the main README for the shared configuration.
# - Override GROUP_TYPE, EXCLUDE_LIST, BACKUP_DIR and LOG_FILE via the
#   environment; otherwise the defaults below apply.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
#
# *** This deletes every computer group. Test against a non-production Jamf
# *** Pro environment first.

SCRIPT_NAME="delete-all-computer-groups.sh"
SCRIPT_VERSION="1.1.0"

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
SCRIPT_GROUP_TYPE="all"                                   # "smart", "static" or "all"
SCRIPT_EXCLUDE_LIST=""                                    # optional file: group IDs or exact names to keep, one per line
SCRIPT_BACKUP_DIR="$HOME/Library/Logs/jamf_delete_computer_groups_backup"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_delete_computer_groups.log"
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
loadSetting GROUP_TYPE "" "$SCRIPT_GROUP_TYPE"
loadSetting EXCLUDE_LIST "" "$SCRIPT_EXCLUDE_LIST"
loadSetting BACKUP_DIR "" "$SCRIPT_BACKUP_DIR"
loadSetting LOG_FILE "" "$SCRIPT_LOG_FILE"
JAMF_URL="${JAMF_URL%/}"
DRY_RUN="${DRY_RUN:-$SCRIPT_DRY_RUN}"
GROUP_TYPE=$(printf '%s' "$GROUP_TYPE" | tr '[:upper:]' '[:lower:]')
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
case "$GROUP_TYPE" in
	smart|static|all) ;;
	*) echo "ERROR: GROUP_TYPE must be smart, static or all." >&2; exit 1 ;;
esac
[[ "$DRY_RUN" == "yes" || "$DRY_RUN" == "no" ]] || { echo "ERROR: DRY_RUN must be yes or no." >&2; exit 1; }
[[ -z "$EXCLUDE_LIST" || -r "$EXCLUDE_LIST" ]] || { echo "ERROR: EXCLUDE_LIST file '$EXCLUDE_LIST' is not readable." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

# Read the exclude list: one group ID or exact name per line. Blank lines and
# lines starting with # are ignored; surrounding whitespace and Windows line
# endings are stripped.
excludeEntry=()
if [[ -n "$EXCLUDE_LIST" ]]; then
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z "$line" || "$line" == \#* ]] && continue
		excludeEntry+=("$line")
	done < "$EXCLUDE_LIST"
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
			echo "#  DRY_RUN=yes: read-only checks, nothing will be deleted."
		else
			echo "#  DRY_RUN=no: this WILL DELETE ALL ($GROUP_TYPE) computer groups from PRODUCTION"
			echo "#  (except ${#excludeEntry[@]} exclude-list entries)."
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

# --- Destructive-action disclaimer and confirmation --------------------------
# Shown on every real run (dev or prod). A dry run changes nothing, so it skips
# this. An interactive run confirms again, with the group count, once the groups
# are listed. A non-interactive run cannot be asked, so it must opt in
# explicitly with JAMF_DELETE_CONFIRM=DELETE.
if [[ "$DRY_RUN" == "no" ]]; then
	{
		echo
		echo "================================================================"
		echo " DISCLAIMER: THIS SCRIPT PERMANENTLY DELETES COMPUTER GROUPS"
		echo
		echo " - It deletes EVERY $GROUP_TYPE computer group it can list on:"
		echo "   $JAMF_URL"
		echo "   It is not driven by a list of groups to delete. Only groups on"
		echo "   the exclude list (${#excludeEntry[@]} entries loaded) are kept."
		echo " - Deleted groups cannot be recovered by this script. Before"
		echo "   deleting, it saves each group (and a static group's members) to a"
		echo "   new folder in:"
		echo "   $BACKUP_DIR"
		echo "   restore-computer-groups.sh can recreate groups from it (untested"
		echo "   against a live Jamf Pro)."
		echo " - Jamf Pro will not delete a group that is scoped to other objects"
		echo "   such as policies or configuration profiles (HTTP 422). Those"
		echo "   groups stay and are reported as failed. The dry run cannot tell"
		echo "   which groups are in use."
		echo " - Run with DRY_RUN=yes first and review the list."
		echo " - Provided as is, with no warranty. You are responsible for the"
		echo "   result. Test in a non-production Jamf Pro first."
		echo "================================================================"
	} >&2
	if [[ ! -t 0 && "${JAMF_DELETE_CONFIRM:-}" != "DELETE" ]]; then
		echo "ERROR: A non-interactive real run requires JAMF_DELETE_CONFIRM=DELETE." >&2
		exit 1
	fi
fi

mkdir -p "$(dirname "$logFile")"
touch "$logFile"
# Record the same first lines in the log file (console already showed them).
printf '%s\n%s\n%s\n' "$BANNER" "$ENV_LINE" "$SOURCES_LINE" >> "$logFile"

countFound=0
countDeleted=0
countFailure=0
countExcluded=0
deletedGroup=()
failureGroup=()
excludedGroup=()
backupPath=""
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
	log "Summary for $GROUP_TYPE computer group deletions"
	log "Groups found: $countFound"
	log "Kept (on the exclude list): $countExcluded"
	if [[ ${#excludedGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${excludedGroup[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would delete (DRY_RUN=yes, nothing was deleted): $countDeleted"
	else
		log "Deleted: $countDeleted"
	fi
	if [[ ${#deletedGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${deletedGroup[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed: $countFailure"
	if [[ ${#failureGroup[@]} -gt 0 ]]; then
		printf "%s\n" "${failureGroup[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$backupPath" ]]; then
		log "---------------------------------------"
		log "Backup of the groups before deletion: $backupPath"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-delete-groups.XXXXXX")"
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

# jamfRequest METHOD PATH
# Sets http_status and leaves the response body in $RESPONSE_FILE. A 401 means
# the token expired (a long run can outlive it), so it gets a new token and
# retries once. A 403 (missing privilege) is handled by the caller.
jamfRequest() {
	local method="$1" path="$2" attempt
	for attempt in 1 2; do
		http_status="$(bearerConfig | curl --silent --show-error --retry 2 --retry-delay 2 \
			--write-out '%{http_code}' --output "$RESPONSE_FILE" -K - \
			--request "$method" "$JAMF_URL$path" \
			--header "Accept: application/json" || true)"
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
	runFailureReason="Forbidden (403) while $1. The API Role needs Read and Delete for Smart and Static Computer Groups; remaining groups were not attempted."
	log "Error: Forbidden (403) while $1. The API Role lacks a required privilege."
	exit 1
}

# Parallel lists of every group found (bash 3.2 on macOS has no associative
# arrays). All groups are listed BEFORE any delete, so deleting cannot shift
# the pages that are still being read.
groupId=()
groupName=()
groupKind=()
groupAction=()   # "delete", "keep" (on the exclude list) or "nobackup" (backup failed)

# listGroups TYPE   (TYPE is "smart" or "static")
listGroups() {
	local kind="$1" page=0 total=0 seen=0 rows i id name
	while :; do
		jamfRequest GET "/api/v3/computer-groups/$kind-groups?page=$page&page-size=100&sort=id:asc"
		case "$http_status" in
			2[0-9][0-9]) ;;
			403) stopForPrivilege "listing $kind computer groups" ;;
			*)
				runFailureReason="Failed to list $kind computer groups (HTTP $http_status). Nothing was deleted for this type."
				log "Error: Failed to list $kind computer groups. HTTP code: $http_status"
				exit 1
				;;
		esac
		total="$(plutil -extract totalCount raw "$RESPONSE_FILE" 2>/dev/null || true)"
		[[ "$total" =~ ^[0-9]+$ ]] || {
			runFailureReason="Unreadable $kind computer group list from Jamf Pro."
			log "Error: Could not read totalCount for $kind computer groups."
			exit 1
		}
		rows="$(plutil -extract results raw "$RESPONSE_FILE" 2>/dev/null || echo 0)"
		[[ "$rows" =~ ^[0-9]+$ ]] || rows=0
		for ((i = 0; i < rows; i++)); do
			id="$(plutil -extract "results.$i.id" raw "$RESPONSE_FILE" 2>/dev/null || true)"
			name="$(plutil -extract "results.$i.name" raw "$RESPONSE_FILE" 2>/dev/null || true)"
			[[ -n "$id" ]] || continue
			groupId+=("$id")
			groupName+=("$name")
			groupKind+=("$kind")
			groupAction+=("delete")
			log "Found group | ID: $id | Name: $name | Type: $kind"
		done
		seen=$((seen + rows))
		# Stop at the reported total, or on an empty page (avoids looping forever).
		[[ "$rows" -gt 0 && "$seen" -lt "$total" ]] || break
		page=$((page + 1))
	done
}

# isExcluded ID NAME: true if the group's ID or exact name is on the exclude list.
isExcluded() {
	local entry
	# ${arr[@]+...} keeps an empty array safe under "set -u" on macOS bash 3.2.
	for entry in ${excludeEntry[@]+"${excludeEntry[@]}"}; do
		[[ "$entry" == "$1" || "$entry" == "$2" ]] && return 0
	done
	return 1
}

# backupFileBase ENV KIND NAME ID: prints <env>-<kind>-<name>-<id> (no extension).
# The name is made safe for a file name: control characters are removed, "/", ":"
# and "\" become "_", it is cut to 50 characters (keeps the whole name under the
# 255-byte limit) and any invalid UTF-8 left by the cut is dropped. The ID keeps
# two groups with the same name apart.
backupFileBase() {
	local safe
	# shellcheck disable=SC1003 # '\\' is one literal backslash for tr, not an escaped quote
	safe="$(printf '%s' "$3" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C tr '/:\\' '___')"
	safe="$(printf '%s' "${safe:0:50}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)"
	printf '%s-%s-%s-%s' "$1" "$2" "${safe:-unnamed}" "$4"
}

# backupGroup INDEX: saves the group in the backup folder. Returns non-zero if it
# could not be saved, so the group is not deleted.
#   <base>.json          the v3 group record (smart group criteria, name, site).
#   <base>.members.json  static groups only: the member computers. Jamf's v3
#                        record for a static group does not include them, so they
#                        come from the Classic API (GET /JSSResource/computergroups/id/{id}).
backupGroup() {
	local i="$1" id="${groupId[$1]}" name="${groupName[$1]}" kind="${groupKind[$1]}" base
	base="$backupPath/$(backupFileBase "$JAMF_ENV" "$kind" "$name" "$id")"
	jamfRequest GET "/api/v3/computer-groups/$kind-groups/$id"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "backing up $kind computer group $name (ID: $id)" ;;
		*) log "Backup failed for $kind computer group $name (ID: $id). HTTP code: $http_status"; return 1 ;;
	esac
	cp "$RESPONSE_FILE" "$base.json" || return 1

	[[ "$kind" == "static" ]] || return 0
	jamfRequest GET "/JSSResource/computergroups/id/$id"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "backing up the members of static computer group $name (ID: $id)" ;;
		*)
			log "Backup failed for the members of static computer group $name (ID: $id). HTTP code: $http_status"
			rm -f "$base.json"
			return 1
			;;
	esac
	# The member list must be readable (an empty group has 0 members). If not, the
	# backup is incomplete, so the group is not deleted.
	if ! plutil -extract computer_group.computers raw "$RESPONSE_FILE" >/dev/null 2>&1; then
		log "Backup failed for static computer group $name (ID: $id). The member list was not in the response."
		rm -f "$base.json"
		return 1
	fi
	cp "$RESPONSE_FILE" "$base.members.json" || { rm -f "$base.json"; return 1; }
}

# deleteGroup INDEX
deleteGroup() {
	local i="$1" id="${groupId[$1]}" name="${groupName[$1]}" kind="${groupKind[$1]}" label
	label="$name (ID: $id, $kind)"
	if [[ "$DRY_RUN" == "yes" ]]; then
		countDeleted=$((countDeleted + 1))
		deletedGroup+=("$label")
		log "DRY_RUN: would delete computer group $label"
		return
	fi
	jamfRequest DELETE "/api/v3/computer-groups/$kind-groups/$id"
	case "$http_status" in
		200|204)
			countDeleted=$((countDeleted + 1))
			deletedGroup+=("$label")
			log "Deleted computer group $label"
			;;
		403)
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (HTTP 403)")
			stopForPrivilege "deleting computer group $label"
			;;
		422)
			# Jamf Pro refuses to delete a group that other objects depend on.
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (in use, HTTP 422)")
			log "Not deleted: computer group $label is in use (HTTP 422)."
			;;
		*)
			countFailure=$((countFailure + 1))
			failureGroup+=("$label (HTTP $http_status)")
			log "Failed to delete computer group $label. HTTP code: $http_status"
			;;
	esac
}

main() {
	getAccessToken
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: listing $GROUP_TYPE computer groups. Nothing will be deleted."
	else
		log "Listing $GROUP_TYPE computer groups before deleting..."
	fi

	[[ "$GROUP_TYPE" == "static" ]] || listGroups smart
	[[ "$GROUP_TYPE" == "smart" ]] || listGroups static

	countFound=${#groupId[@]}
	if [[ "$countFound" -eq 0 ]]; then
		log "No $GROUP_TYPE computer groups found. Nothing to do."
		return
	fi

	# Apply the exclude list: these groups are kept and never backed up or deleted.
	local i countToDelete=0
	for ((i = 0; i < countFound; i++)); do
		if isExcluded "${groupId[$i]}" "${groupName[$i]}"; then
			groupAction[i]="keep"
			countExcluded=$((countExcluded + 1))
			excludedGroup+=("${groupName[$i]} (ID: ${groupId[$i]}, ${groupKind[$i]})")
			log "Keeping group on the exclude list: ${groupName[$i]} (ID: ${groupId[$i]}, ${groupKind[$i]})"
		else
			countToDelete=$((countToDelete + 1))
		fi
	done

	if [[ "$countToDelete" -eq 0 ]]; then
		log "Every group found is on the exclude list. Nothing to do."
		return
	fi

	# Last check before an interactive real run: show the counts and ask.
	if [[ "$DRY_RUN" == "no" && -t 0 ]]; then
		read -rp "Found $countFound computer group(s), keeping $countExcluded, deleting $countToDelete. Type DELETE to continue: " confirmDelete || confirmDelete=""
		[[ "$confirmDelete" == "DELETE" ]] || {
			runFailureReason="Cancelled at the DELETE confirmation. Nothing was deleted."
			log "Cancelled. Nothing was deleted."
			exit 1
		}
	fi

	# Back up every group that is about to be deleted BEFORE the first delete, so
	# a complete record exists even if the run stops partway through.
	if [[ "$DRY_RUN" == "no" ]]; then
		backupPath="$BACKUP_DIR/$(date +"%Y%m%d-%H%M%S")"
		mkdir -p "$backupPath"
		log "Backing up $countToDelete group(s) to $backupPath ..."
		for ((i = 0; i < countFound; i++)); do
			[[ "${groupAction[$i]}" == "delete" ]] || continue
			if ! backupGroup "$i"; then
				groupAction[i]="nobackup"
				countFailure=$((countFailure + 1))
				failureGroup+=("${groupName[$i]} (ID: ${groupId[$i]}, ${groupKind[$i]}) (backup failed, not deleted)")
			fi
		done
	else
		log "DRY_RUN=yes: a real run would first back up $countToDelete group(s) to a new folder in $BACKUP_DIR."
	fi

	for ((i = 0; i < countFound; i++)); do
		[[ "${groupAction[$i]}" == "delete" ]] || continue
		deleteGroup "$i"
	done

	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
