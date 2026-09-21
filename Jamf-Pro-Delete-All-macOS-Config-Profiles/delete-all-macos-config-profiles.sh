#!/bin/bash

# Delete ALL macOS configuration profiles in Jamf Pro.
# Author: Karthikeyan Marappan
#
# This is a delete-ALL tool. It does not take a list of profiles to delete: it
# finds every macOS configuration profile and deletes it, except profiles
# named on the optional exclude list (EXCLUDE_LIST).
#
# *** Deleting a profile in Jamf Pro also REMOVES it from every Mac in its
# *** scope at the next check-in. Settings the profile enforced go with it.
#
# Key Functionalities:
# - Lists every macOS configuration profile with the Jamf Pro Classic API
#   (GET /JSSResource/osxconfigurationprofiles) and logs the ID and name of
#   each one. This is the same Classic endpoint the Profile Deprecation Audit
#   uses; no modern-API equivalent is used here. The Classic list is not paged.
# - Keeps any profile whose ID or exact name is on the exclude list (a text
#   file, one ID or name per line, # lines ignored). Excluded profiles are
#   never backed up or deleted, in a dry run or a real run.
# - Before deleting anything on a real run, saves each profile's full record
#   (GET /JSSResource/osxconfigurationprofiles/id/{id}, as XML) to a
#   timestamped folder in BACKUP_DIR, named <prod|dev>-<name>-<id>.xml. The
#   saved XML has every <id> element removed (the "trimmed" form, as Jamf
#   Replicator writes it) so it can be posted back to a Jamf Pro server. A
#   profile whose backup fails is not deleted.
# - Deletes each profile with DELETE /JSSResource/osxconfigurationprofiles/id/{id}.
#   A profile that fails to delete is reported and the run continues.
# - Invalidates the API token on exit, whether the run succeeded or not.
# - Always prints a summary, even if the run stopped early. The exit code is
#   non-zero if any profile failed or the run stopped early.
#
# Requirements:
# - curl and plutil (both included with macOS).
# - Jamf Pro API Client permissions (Classic API privileges):
#   - Read macOS Configuration Profiles
#   - Delete macOS Configuration Profiles
#
# Usage:
# - Environment: choose prod or dev with JAMF_ENV, or the SCRIPT_JAMF_ENV value
#   below, or answer the prompt. Choosing prod shows a warning and requires
#   typing PROD. A non-interactive prod run that deletes (DRY_RUN=no) also
#   needs JAMF_PROD_CONFIRM=PROD.
# - DRY_RUN defaults to "yes": the script lists the profiles and reports what it
#   WOULD delete, without deleting. Set DRY_RUN=no to delete.
# - A real run (dev or prod) prints a disclaimer. An interactive run then asks
#   you to type DELETE after showing how many profiles it found. A
#   non-interactive real run needs JAMF_DELETE_CONFIRM=DELETE.
# - EXCLUDE_LIST (optional) is a text file of profile IDs or exact names to keep.
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
# *** This deletes every macOS configuration profile. Test against a
# *** non-production Jamf Pro environment first.

SCRIPT_NAME="delete-all-macos-config-profiles.sh"
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
SCRIPT_EXCLUDE_LIST=""                                    # optional file: profile IDs or exact names to keep, one per line
SCRIPT_BACKUP_DIR="$HOME/Library/Logs/jamf_delete_macos_config_profiles_backup"
SCRIPT_LOG_FILE="$HOME/Library/Logs/jamf_delete_macos_config_profiles.log"
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

# Used by the production guard below.
MAKES_CHANGES="no"
[[ "$DRY_RUN" == "no" ]] && MAKES_CHANGES="yes"

# Read the exclude list: one profile ID or exact name per line. Blank lines and
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
			echo "#  DRY_RUN=no: this WILL DELETE ALL macOS configuration profiles from PRODUCTION"
			echo "#  (except ${#excludeEntry[@]} exclude-list entries) and REMOVE them from every"
			echo "#  Mac in scope."
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
# this. An interactive run confirms again, with the profile count, once the
# profiles are listed. A non-interactive run cannot be asked, so it must opt in
# explicitly with JAMF_DELETE_CONFIRM=DELETE.
if [[ "$DRY_RUN" == "no" ]]; then
	{
		echo
		echo "================================================================"
		echo " DISCLAIMER: THIS SCRIPT PERMANENTLY DELETES CONFIGURATION PROFILES"
		echo
		echo " - It deletes EVERY macOS configuration profile it can list on:"
		echo "   $JAMF_URL"
		echo "   It is not driven by a list of profiles to delete. Only profiles"
		echo "   on the exclude list (${#excludeEntry[@]} entries loaded) are kept."
		echo " - Deleting a profile removes it from every Mac in its scope at the"
		echo "   next check-in. Anything the profile enforced (for example"
		echo "   restrictions, PPPC, FileVault, Wi-Fi, certificates or system"
		echo "   extension approvals) is removed from those Macs."
		echo " - Deleted profiles cannot be recovered by this script. Before"
		echo "   deleting, it saves each profile's record (XML, IDs removed) to a"
		echo "   new folder in:"
		echo "   $BACKUP_DIR"
		echo "   Restoring is not automated or tested."
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
deletedProfile=()
failureProfile=()
excludedProfile=()
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
	log "Summary for macOS configuration profile deletions"
	log "Profiles found: $countFound"
	log "Kept (on the exclude list): $countExcluded"
	if [[ ${#excludedProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${excludedProfile[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "Would delete (DRY_RUN=yes, nothing was deleted): $countDeleted"
	else
		log "Deleted: $countDeleted"
	fi
	if [[ ${#deletedProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${deletedProfile[@]}" | tee -a "$logFile"
	fi
	log "---------------------------------------"
	log "Failed: $countFailure"
	if [[ ${#failureProfile[@]} -gt 0 ]]; then
		printf "%s\n" "${failureProfile[@]}" | tee -a "$logFile"
	fi
	if [[ -n "$backupPath" ]]; then
		log "---------------------------------------"
		log "Backup of the profiles before deletion: $backupPath"
	fi
	if [[ -n "$runFailureReason" ]]; then
		log "---------------------------------------"
		log "Run stopped early. Reason: $runFailureReason"
	fi
	log "---------------------------------------"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-delete-profiles.XXXXXX")"
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
# profile would fail the same way.
stopForPrivilege() {
	runFailureReason="Forbidden (403) while $1. The API Role needs Read and Delete for macOS Configuration Profiles; remaining profiles were not attempted."
	log "Error: Forbidden (403) while $1. The API Role lacks a required privilege."
	exit 1
}

# Parallel lists of every profile found (bash 3.2 on macOS has no associative
# arrays). All profiles are listed BEFORE any delete.
profileId=()
profileName=()
profileAction=()   # "delete", "keep" (on the exclude list) or "nobackup" (backup failed)

# listProfiles: fills the lists above from the Classic API. The Classic list is
# returned in one response (no paging).
listProfiles() {
	local rows i id name
	jamfRequest GET "/JSSResource/osxconfigurationprofiles" "application/json"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "listing macOS configuration profiles" ;;
		*)
			runFailureReason="Failed to list macOS configuration profiles (HTTP $http_status). Nothing was deleted."
			log "Error: Failed to list macOS configuration profiles. HTTP code: $http_status"
			exit 1
			;;
	esac
	# A missing list key means the response is not what we expect: stop rather
	# than treat it as "no profiles".
	rows="$(plutil -extract os_x_configuration_profiles raw "$RESPONSE_FILE" 2>/dev/null || true)"
	[[ "$rows" =~ ^[0-9]+$ ]] || {
		runFailureReason="Unreadable macOS configuration profile list from Jamf Pro."
		log "Error: Could not read the macOS configuration profile list."
		exit 1
	}
	for ((i = 0; i < rows; i++)); do
		id="$(plutil -extract "os_x_configuration_profiles.$i.id" raw "$RESPONSE_FILE" 2>/dev/null || true)"
		name="$(plutil -extract "os_x_configuration_profiles.$i.name" raw "$RESPONSE_FILE" 2>/dev/null || true)"
		# The ID goes into a URL path, so accept digits only.
		[[ "$id" =~ ^[0-9]+$ ]] || {
			runFailureReason="Jamf Pro returned a profile without a valid numeric ID."
			log "Error: Profile entry $i has no valid ID. Stopping before any delete."
			exit 1
		}
		profileId+=("$id")
		profileName+=("$name")
		profileAction+=("delete")
		log "Found profile | ID: $id | Name: $name"
	done
}

# isExcluded ID NAME: true if the profile's ID or exact name is on the exclude list.
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
# profiles with the same name apart.
backupFileName() {
	local safe
	# shellcheck disable=SC1003 # '\\' is one literal backslash for tr, not an escaped quote
	safe="$(printf '%s' "$2" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C tr '/:\\' '___')"
	safe="$(printf '%s' "${safe:0:50}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)"
	printf '%s-%s-%s.xml' "$1" "${safe:-unnamed}" "$3"
}

# backupProfile INDEX: saves the profile's full record as XML in the backup
# folder, with every <id> element removed (the "trimmed" form Jamf Replicator
# writes) so the file can be posted back to Jamf Pro. IDs are removed whether
# the API returns one element per line or all on one line. The payload is an
# XML-escaped string, so it cannot contain a real <id> element. Returns
# non-zero if the record could not be saved, so the profile is not deleted.
backupProfile() {
	local i="$1" id="${profileId[$1]}" name="${profileName[$1]}" file
	jamfRequest GET "/JSSResource/osxconfigurationprofiles/id/$id" "application/xml"
	case "$http_status" in
		2[0-9][0-9]) ;;
		403) stopForPrivilege "backing up profile $name (ID: $id)" ;;
		*) log "Backup failed for profile $name (ID: $id). HTTP code: $http_status"; return 1 ;;
	esac
	# An empty body is not a usable backup.
	[[ -s "$RESPONSE_FILE" ]] || { log "Backup failed for profile $name (ID: $id). Empty response."; return 1; }
	file="$backupPath/$(backupFileName "$JAMF_ENV" "$name" "$id")"
	sed -E '/^[[:space:]]*<id>[^<]*<\/id>[[:space:]]*$/d; s#<id>[^<]*</id>##g' "$RESPONSE_FILE" > "$file" || return 1
	# Sanity check: it must still look like a profile and hold no <id> element.
	if ! grep -q '<os_x_configuration_profile' "$file" || ! grep -q '<payloads>' "$file" || grep -q '<id>' "$file"; then
		rm -f "$file"
		log "Backup failed for profile $name (ID: $id). The response was not a usable profile."
		return 1
	fi
}

# deleteProfile INDEX
deleteProfile() {
	local i="$1" id="${profileId[$1]}" name="${profileName[$1]}" label
	label="$name (ID: $id)"
	if [[ "$DRY_RUN" == "yes" ]]; then
		countDeleted=$((countDeleted + 1))
		deletedProfile+=("$label")
		log "DRY_RUN: would delete macOS configuration profile $label"
		return
	fi
	jamfRequest DELETE "/JSSResource/osxconfigurationprofiles/id/$id" "application/json"
	case "$http_status" in
		200|204)
			countDeleted=$((countDeleted + 1))
			deletedProfile+=("$label")
			log "Deleted macOS configuration profile $label"
			;;
		403)
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (HTTP 403)")
			stopForPrivilege "deleting macOS configuration profile $label"
			;;
		404)
			# Gone between the list and the delete (for example removed by someone else).
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (not found, HTTP 404)")
			log "Not deleted: macOS configuration profile $label was not found (HTTP 404)."
			;;
		*)
			countFailure=$((countFailure + 1))
			failureProfile+=("$label (HTTP $http_status)")
			log "Failed to delete macOS configuration profile $label. HTTP code: $http_status"
			;;
	esac
}

main() {
	getAccessToken
	if [[ "$DRY_RUN" == "yes" ]]; then
		log "DRY_RUN=yes: listing macOS configuration profiles. Nothing will be deleted."
	else
		log "Listing macOS configuration profiles before deleting..."
	fi

	listProfiles

	countFound=${#profileId[@]}
	if [[ "$countFound" -eq 0 ]]; then
		log "No macOS configuration profiles found. Nothing to do."
		return
	fi

	# Apply the exclude list: these profiles are kept and never backed up or deleted.
	local i countToDelete=0
	for ((i = 0; i < countFound; i++)); do
		if isExcluded "${profileId[$i]}" "${profileName[$i]}"; then
			profileAction[i]="keep"
			countExcluded=$((countExcluded + 1))
			excludedProfile+=("${profileName[$i]} (ID: ${profileId[$i]})")
			log "Keeping profile on the exclude list: ${profileName[$i]} (ID: ${profileId[$i]})"
		else
			countToDelete=$((countToDelete + 1))
		fi
	done

	if [[ "$countToDelete" -eq 0 ]]; then
		log "Every profile found is on the exclude list. Nothing to do."
		return
	fi

	# Last check before an interactive real run: show the counts and ask.
	if [[ "$DRY_RUN" == "no" && -t 0 ]]; then
		read -rp "Found $countFound macOS configuration profile(s), keeping $countExcluded, deleting $countToDelete. Type DELETE to continue: " confirmDelete || confirmDelete=""
		[[ "$confirmDelete" == "DELETE" ]] || {
			runFailureReason="Cancelled at the DELETE confirmation. Nothing was deleted."
			log "Cancelled. Nothing was deleted."
			exit 1
		}
	fi

	# Back up every profile that is about to be deleted BEFORE the first delete,
	# so a complete record exists even if the run stops partway through.
	if [[ "$DRY_RUN" == "no" ]]; then
		backupPath="$BACKUP_DIR/$(date +"%Y%m%d-%H%M%S")"
		mkdir -p "$backupPath"
		log "Backing up $countToDelete profile(s) to $backupPath ..."
		for ((i = 0; i < countFound; i++)); do
			[[ "${profileAction[$i]}" == "delete" ]] || continue
			if ! backupProfile "$i"; then
				profileAction[i]="nobackup"
				countFailure=$((countFailure + 1))
				failureProfile+=("${profileName[$i]} (ID: ${profileId[$i]}) (backup failed, not deleted)")
			fi
		done
	else
		log "DRY_RUN=yes: a real run would first back up $countToDelete profile(s) to a new folder in $BACKUP_DIR."
	fi

	for ((i = 0; i < countFound; i++)); do
		[[ "${profileAction[$i]}" == "delete" ]] || continue
		deleteProfile "$i"
	done

	# A non-zero exit lets a calling script or scheduler see that something failed.
	[[ "$countFailure" -eq 0 ]] || exit 1
}

main
