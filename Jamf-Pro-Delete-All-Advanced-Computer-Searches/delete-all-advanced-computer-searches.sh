#!/bin/bash

# Delete ALL advanced computer searches in Jamf Pro.
# Author: Karthikeyan Marappan
#
# This is a delete-ALL tool. It does not take a list of searches to delete: it
# finds every advanced computer search and deletes it, except searches
# named on the optional exclude list (EXCLUDE_LIST).
#
# *** A deleted search is gone from Jamf Pro (no Mac is changed). Test in a
# *** non-production Jamf Pro first.
#
# Key Functionalities:
# - Lists every advanced computer search with the Jamf Pro Classic API
#   (GET /JSSResource/advancedcomputersearches) and logs the ID and name of
#   each one. Advanced computer searches are read and deleted with the Classic
#   API; no modern-API endpoint is used here. The Classic list is not paged.
# - Keeps any search whose ID or exact name is on the exclude list (a text
#   file, one ID or name per line, # lines ignored). Excluded searches are
#   never backed up or deleted, in a dry run or a real run.
# - Before deleting anything on a real run, saves each search's full record
#   (GET /JSSResource/advancedcomputersearches/id/{id}, as XML) to a
#   timestamped folder in BACKUP_DIR, named <prod|dev>-<name>-<id>.xml. The
#   saved XML has every <id> element removed (the "trimmed" form, as Jamf
#   Replicator writes it) so it can be posted back to a Jamf Pro server. The
#   <computers> results block is left out: it is the current list of matching
#   Macs (device data), not part of the search definition. A search whose
#   backup fails is not deleted.
# - Deletes each search with DELETE /JSSResource/advancedcomputersearches/id/{id}.
#   A search that fails to delete is reported and the run continues.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any search failed or the run stopped early.
#
# Requirements:
# - curl, plutil and perl (all included with macOS).
# - Jamf Pro API Client permissions (Classic API privileges):
#   - Read Advanced Computer Searches
#   - Delete Advanced Computer Searches
#
# Usage:
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that deletes (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script lists the searches and reports what it
#   WOULD delete, without deleting. Set DRY_RUN=no to delete.
# - A real run (dev or prod) prints a disclaimer. An interactive run then asks
#   you to type DELETE after showing how many searches it found. A
#   non-interactive real run needs JAMF_DELETE_CONFIRM=DELETE.
# - EXCLUDE_LIST (optional) is a text file of search IDs or exact names to keep.
# - BACKUP_DIR is where the pre-delete backup folder is created (real runs).
# - Credentials: never hard-code them. Values are taken in this order:
#   environment variable, script default, the plist
#   com.karthikmac.macadminstoolkit (keys ProdServerURL/DevServerURL,
#   ProdAPIClientID/DevAPIClientID, ProdAPIClientSecret/DevAPIClientSecret;
#   plain text, keep it chmod 600), then a prompt (client ID and secret are
#   entered with no echo). See the main README for the shared configuration.
# - Override EXCLUDE_LIST, BACKUP_DIR and LOG_FILE via the environment;
#   otherwise the defaults below apply.
# - Lines 2-3 of the output show the environment and where each setting came
#   from (never the values).
#
# *** This deletes every advanced computer search. Test against a
# *** non-production Jamf Pro environment first.

SCRIPT_NAME="delete-all-advanced-computer-searches.sh"
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
SCRIPT_EXCLUDE_LIST=""                                    # optional file: search IDs or exact names to keep, one per line
SCRIPT_BACKUP_DIR="$HOME/Library/Logs/jamf_delete_advanced_computer_searches_backup"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_delete_advanced_computer_searches.log"
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
loadSetting EXCLUDE_LIST "" "$SCRIPT_EXCLUDE_LIST"
loadSetting BACKUP_DIR "" "$SCRIPT_BACKUP_DIR"
loadSetting LOG_FILE "" "$SCRIPT_LOG_FILE"

# cleanPath VALUE: makes a path that was typed or pasted usable. Trims spaces,
# removes one pair of surrounding quotes, expands a leading ~, and retries with
# shell escapes removed (Terminal tab completion and drag and drop write
# "My\ File", and a quoted value keeps the backslash) when that path, or for a
# file or folder that does not exist yet its parent folder, exists.
# Real paths used here never contain a backslash, so this cannot change one.
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
		if [[ -e "$unescaped" || -d "$(dirname "$unescaped")" ]]; then p="$unescaped"; fi
	fi
	printf '%s' "$p"
}
EXCLUDE_LIST="$(cleanPath "$EXCLUDE_LIST")"
BACKUP_DIR="$(cleanPath "$BACKUP_DIR")"
LOG_FILE="$(cleanPath "$LOG_FILE")"

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
[[ -z "$EXCLUDE_LIST" || -r "$EXCLUDE_LIST" ]] || { echo "ERROR: EXCLUDE_LIST file '$EXCLUDE_LIST' is not readable." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v plutil >/dev/null || { echo "ERROR: plutil is required." >&2; exit 1; }
command -v perl >/dev/null || { echo "ERROR: perl is required." >&2; exit 1; }

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

# Read the exclude list: one search ID or exact name per line. Blank lines and
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
			echo "#  DRY_RUN=no: this WILL DELETE ALL advanced computer searches from PRODUCTION"
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
# this. An interactive run confirms again, with the search count, once the
# searches are listed. A non-interactive run cannot be asked, so it must opt in
# explicitly with JAMF_DELETE_CONFIRM=DELETE.
if [[ "$DRY_RUN" == "no" ]]; then
	{
		echo
		echo "================================================================"
		echo " DISCLAIMER: THIS SCRIPT PERMANENTLY DELETES ADVANCED COMPUTER SEARCHES"
		echo
		echo " - It deletes EVERY advanced computer search it can list on:"
		echo "   $JAMF_URL"
		echo "   It is not driven by a list of searches to delete. Only searches"
		echo "   on the exclude list (${#excludeEntry[@]} entries loaded) are kept."
		echo " - Deleting a search does not change any Mac. It removes the saved"
		echo "   search (its criteria and display fields) from Jamf Pro."
		echo " - Deleted searches cannot be recovered by this script. Before"
		echo "   deleting, it saves each search's record (XML, IDs removed) to a"
		echo "   new folder in:"
		echo "   $BACKUP_DIR"
		echo "   restore-advanced-computer-searches.sh can recreate searches from it"
		echo "   (untested against a live Jamf Pro)."
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
deletedSearch=()
failureSearch=()
excludedSearch=()
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
	log "Summary for advanced computer search deletions"
	log "Searches found: $countFound"
	log "Kept (on the exclude list): $countExcluded"
	if [[ ${#excludedSearch[@]} -gt 0 ]]; then
		printf "%s\n" "${excludedSearch[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would delete (DRY_RUN=yes, nothing was deleted): $countDeleted"
	else
		log "Deleted: $countDeleted"
	fi
	if [[ ${#deletedSearch[@]} -gt 0 ]]; then
		printf "%s\n" "${deletedSearch[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed: $countFailure"
	if [[ ${#failureSearch[@]} -gt 0 ]]; then
		printf "%s\n" "${failureSearch[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$backupPath" ]]; then
		log "---------------------------------------"
		log "Backup of the searches before deletion: $backupPath"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-delete-searches.XXXXXX")"
SECRET_FILE="$WORK_DIR/client-secret"
RESPONSE_FILE="$WORK_DIR/response.out"
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

# jamfRequest METHOD PATH ACCEPT
# Sets http_status and leaves the response body in $RESPONSE_FILE. ACCEPT is the
# media type to ask for (application/json or application/xml). A 401 means the
# token expired (a long run can outlive it), so it gets a new token and retries
# once. A 403 (missing privilege) is handled by the caller.
jamfRequest() {
	local method="$1" path="$2" accept="$3" attempt
	for attempt in 1 2; do
		http_status="$(bearerConfig | curl --silent --show-error --retry 2 --retry-delay 2 \
			--write-out '%{http_code}' --output "$RESPONSE_FILE" -K - \
			--request "$method" "$JAMF_URL$path" \
			--header "Accept: $accept" || true)"
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
# search would fail the same way.
stopForPrivilege() {
	runFailureReason="Forbidden (403) while $1. The API Role needs Read and Delete for Advanced Computer Searches; remaining searches were not attempted."
	log "Error: Forbidden (403) while $1. The API Role lacks a required privilege."
	exit 1
}

# Parallel lists of every search found (bash 3.2 on macOS has no associative
# arrays). All searches are listed BEFORE any delete.
searchId=()
searchName=()
searchAction=()   # "delete", "keep" (on the exclude list) or "nobackup" (backup failed)

# listSearches: fills the lists above from the Classic API. The Classic list is
# returned in one response (no paging).
listSearches() {
	local rows i id name
	jamfRequest GET "/JSSResource/advancedcomputersearches" "application/json"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "listing advanced computer searches" ;;
		*)
			runFailureReason="Failed to list advanced computer searches (HTTP $http_status). Nothing was deleted."
			log "Error: Failed to list advanced computer searches. HTTP code: $http_status"
			exit 1
			;;
	esac
	# A missing list key means the response is not what we expect: stop rather
	# than treat it as "no searches".
	rows="$(plutil -extract advanced_computer_searches raw "$RESPONSE_FILE" 2>/dev/null || true)"
	[[ "$rows" =~ ^[0-9]+$ ]] || {
		runFailureReason="Unreadable advanced computer search list from Jamf Pro."
		log "Error: Could not read the advanced computer search list."
		exit 1
	}
	for ((i = 0; i < rows; i++)); do
		id="$(plutil -extract "advanced_computer_searches.$i.id" raw "$RESPONSE_FILE" 2>/dev/null || true)"
		name="$(plutil -extract "advanced_computer_searches.$i.name" raw "$RESPONSE_FILE" 2>/dev/null || true)"
		# The ID goes into a URL path, so accept digits only.
		[[ "$id" =~ ^[0-9]+$ ]] || {
			runFailureReason="Jamf Pro returned a search without a valid numeric ID."
			log "Error: Search entry $i has no valid ID. Stopping before any delete."
			exit 1
		}
		searchId+=("$id")
		searchName+=("$name")
		searchAction+=("delete")
		log "Found search | ID: $id | Name: $name"
	done
}

# isExcluded ID NAME: true if the search's ID or exact name is on the exclude list.
isExcluded() {
	local entry
	# ${arr[@]+...} keeps an empty array safe under "set -u" on macOS bash 3.2.
	for entry in ${excludeEntry[@]+"${excludeEntry[@]}"}; do
		[[ "$entry" == "$1" || "$entry" == "$2" ]] && return 0
	done
	return 1
}

# backupFileName ENV NAME ID: prints <env>-<name>-<id>.xml. The name is made
# safe for a file name: control characters are removed, "/", ":" and "\" become
# "_", it is cut to 50 characters (keeps the whole name under the 255-byte
# limit) and any invalid UTF-8 left by the cut is dropped. The ID keeps two
# searches with the same name apart.
backupFileName() {
	local safe
	# shellcheck disable=SC1003 # '\\' is one literal backslash for tr, not an escaped quote
	safe="$(printf '%s' "$2" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C tr '/:\\' '___')"
	safe="$(printf '%s' "${safe:0:50}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)"
	printf '%s-%s-%s.xml' "$1" "${safe:-unnamed}" "$3"
}

# backupSearch INDEX: saves the search's full record as XML in the backup
# folder, with every <id> element removed (the "trimmed" form Jamf Replicator
# writes) so the file can be posted back to Jamf Pro. IDs are removed whether
# the API returns one element per line or all on one line. The <computers>
# block (the search's current results, which include an <id> per Mac) is
# removed first with perl, which ships with macOS and can match across lines.
# Returns non-zero if the record could not be saved, so the search is not
# deleted.
backupSearch() {
	local i="$1" id="${searchId[$1]}" name="${searchName[$1]}" file
	jamfRequest GET "/JSSResource/advancedcomputersearches/id/$id" "application/xml"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "backing up search $name (ID: $id)" ;;
		*) log "Backup failed for search $name (ID: $id). HTTP code: $http_status"; return 1 ;;
	esac
	# An empty body is not a usable backup.
	[[ -s "$RESPONSE_FILE" ]] || { log "Backup failed for search $name (ID: $id). Empty response."; return 1; }
	file="$backupPath/$(backupFileName "$JAMF_ENV" "$name" "$id")"
	perl -0pe 's#<computers>.*?</computers>##sg' "$RESPONSE_FILE" \
		| sed -E '/^[[:space:]]*<id>[^<]*<\/id>[[:space:]]*$/d; s#<id>[^<]*</id>##g' > "$file" || return 1
	# Sanity check: it must still look like a search, hold no <id> element and
	# no Mac results.
	if ! grep -q '<advanced_computer_search' "$file" || ! grep -q '</advanced_computer_search>' "$file" || grep -q -e '<id>' -e '<computers>' "$file"; then
		rm -f "$file"
		log "Backup failed for search $name (ID: $id). The response was not a usable search."
		return 1
	fi
}

# deleteSearch INDEX
deleteSearch() {
	local i="$1" id="${searchId[$1]}" name="${searchName[$1]}" label
	label="$name (ID: $id)"
	if [[ "$DRY_RUN" == "yes" ]]; then
		countDeleted=$((countDeleted + 1))
		deletedSearch+=("$label")
		log "DRY_RUN: would delete advanced computer search $label"
		return
	fi
	jamfRequest DELETE "/JSSResource/advancedcomputersearches/id/$id" "application/json"
	case "$http_status" in
		200|204)
			countDeleted=$((countDeleted + 1))
			deletedSearch+=("$label")
			log "Deleted advanced computer search $label"
			;;
		403)
			countFailure=$((countFailure + 1))
			failureSearch+=("$label (HTTP 403)")
			stopForPrivilege "deleting advanced computer search $label"
			;;
		404)
			# Gone between the list and the delete (for example removed by someone else).
			countFailure=$((countFailure + 1))
			failureSearch+=("$label (not found, HTTP 404)")
			log "Not deleted: advanced computer search $label was not found (HTTP 404)."
			;;
		*)
			countFailure=$((countFailure + 1))
			failureSearch+=("$label (HTTP $http_status)")
			log "Failed to delete advanced computer search $label. HTTP code: $http_status"
			;;
	esac
}

main() {
	getAccessToken
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: listing advanced computer searches. Nothing will be deleted."
	else
		log "Listing advanced computer searches before deleting..."
	fi

	listSearches

	countFound=${#searchId[@]}
	if [[ "$countFound" -eq 0 ]]; then
		log "No advanced computer searches found. Nothing to do."
		return
	fi

	# Apply the exclude list: these searches are kept and never backed up or deleted.
	local i countToDelete=0
	for ((i = 0; i < countFound; i++)); do
		if isExcluded "${searchId[$i]}" "${searchName[$i]}"; then
			searchAction[i]="keep"
			countExcluded=$((countExcluded + 1))
			excludedSearch+=("${searchName[$i]} (ID: ${searchId[$i]})")
			log "Keeping search on the exclude list: ${searchName[$i]} (ID: ${searchId[$i]})"
		else
			countToDelete=$((countToDelete + 1))
		fi
	done

	if [[ "$countToDelete" -eq 0 ]]; then
		log "Every search found is on the exclude list. Nothing to do."
		return
	fi

	# Last check before an interactive real run: show the counts and ask.
	if [[ "$DRY_RUN" == "no" && -t 0 ]]; then
		read -rp "Found $countFound advanced computer search(s), keeping $countExcluded, deleting $countToDelete. Type DELETE to continue: " confirmDelete || confirmDelete=""
		[[ "$confirmDelete" == "DELETE" ]] || {
			runFailureReason="Cancelled at the DELETE confirmation. Nothing was deleted."
			log "Cancelled. Nothing was deleted."
			exit 1
		}
	fi

	# Back up every search that is about to be deleted BEFORE the first delete,
	# so a complete record exists even if the run stops partway through.
	if [[ "$DRY_RUN" == "no" ]]; then
		backupPath="$BACKUP_DIR/$(date +"%Y%m%d-%H%M%S")"
		mkdir -p "$backupPath"
		log "Backing up $countToDelete search(s) to $backupPath ..."
		for ((i = 0; i < countFound; i++)); do
			[[ "${searchAction[$i]}" == "delete" ]] || continue
			if ! backupSearch "$i"; then
				searchAction[i]="nobackup"
				countFailure=$((countFailure + 1))
				failureSearch+=("${searchName[$i]} (ID: ${searchId[$i]}) (backup failed, not deleted)")
			fi
		done
	else
		log "DRY_RUN=yes: a real run would first back up $countToDelete search(s) to a new folder in $BACKUP_DIR."
	fi

	for ((i = 0; i < countFound; i++)); do
		[[ "${searchAction[$i]}" == "delete" ]] || continue
		deleteSearch "$i"
	done

	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
