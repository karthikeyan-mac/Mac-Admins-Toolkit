#!/bin/bash

# Create (or update) the read-only Jamf Pro API Role that ScopeMap needs.
# Author: Karthikeyan Marappan
# ScopeMap: https://github.com/Jamf-Concepts/scope-map
#
# Key Functionalities:
# - Creates or updates an API Role holding the ScopeMap read privileges
#   (see PRIVILEGES below), via the Jamf Pro API (/api/v1/api-roles).
# - Validates every privilege name against the target server
#   (GET /api/v1/api-role-privileges) before changing anything.
# - Optionally creates an API Client bound to that role and prints its
#   client secret once (CREATE_CLIENT=yes).
# - DRY_RUN defaults to "yes": the script authenticates and validates, prints
#   the payload, and changes nothing. Set DRY_RUN=no for the real run.
# - Invalidates the API token on exit, whether the run succeeded or failed.
#
# Requirements:
# - curl and jq (both included with macOS 15 and later).
# - Run with a Jamf Pro USER ACCOUNT (not an API Client) that has the
#   "Administrator" privilege set.
#   Why: Jamf Pro has a privilege-escalation guard. Whoever creates an API
#   Role can only assign privileges they already hold. An Administrator
#   account holds every API privilege, so it can create the role with no
#   manual setup. An API Client would first need every privilege being
#   assigned (plus Create/Read/Update API Roles), otherwise
#   POST /api/v1/api-roles returns 403 INVALID_PRIVILEGE.
#   If CREATE_CLIENT=yes the account must also be able to create API
#   Integrations (covered by the Administrator privilege set).
#
# Usage:
# - Environment: choose prod or dev with JAMF_ENV (environment variable), or
#   the SCRIPT_JAMF_ENV value below, or answer the prompt. Choosing prod shows
#   a clear warning and requires typing PROD to continue. Non-interactive prod
#   runs that change things (DRY_RUN=no) also need JAMF_PROD_CONFIRM=PROD.
#     JAMF_ENV=dev ./create-jamfscopemap-api-role.sh
# - Never hard-code credentials in this file. Values are taken in this order:
#     1) environment variables, e.g.
#          export JAMF_URL="https://yourorg.jamfcloud.com"
#          export JAMF_USER="admin-account"
#     2) the SCRIPT_* defaults below (URL and credentials are empty by default)
#     3) the preference domain com.karthikmac.macadminstoolkit
#          (~/Library/Preferences/com.karthikmac.macadminstoolkit.plist).
#          Dev keys : DevServerURL, DevAdminUsername, DevAdminPassword,
#                     DevAPIClientID, DevAPIClientSecret
#          Prod keys: ProdServerURL, ProdAdminUsername, ProdAdminPassword,
#                     ProdAPIClientID, ProdAPIClientSecret
#          Shared keys (both environments): ScopeMapRoleName,
#            ScopeMapCreateClient
#          Created by a Jamf admin, e.g.
#            defaults write com.karthikmac.macadminstoolkit DevServerURL -string "https://..."
#          NOTE: this file is plain text. Keep it chmod 600 on admin Macs only.
#          Because ROLE_NAME and CREATE_CLIENT have script
#          defaults, their plist keys only apply if you blank the default.
#     4) a prompt: anything still missing is asked for on an interactive
#        terminal. Password, client ID and client secret are typed/pasted with
#        no echo. Non-interactive runs fail if a value is missing.
#   Lines 2-3 of the output show the environment and which source each
#   setting came from (never the values).
#   The final URL is checked against the plist: it must match the selected
#   environment's ServerURL (if set) and must not be the other environment's.
#   DRY_RUN is only read from the environment, never from the plist.
#   DRY_RUN=no is the switch for a real run (prod also asks for PROD first).
# - Fallback only: JAMF_CLIENT_ID + JAMF_CLIENT_SECRET (an API Client). This
#   only works if that client already holds every privilege being assigned.
# - Optional overrides (environment): ROLE_NAME, CREATE_CLIENT (yes|no),
#   DRY_RUN (yes|no).
# - CREATE_CLIENT=yes creates an API Client with the SAME name as the role. If
#   a client with that name, or any client already assigned this role, exists,
#   no new client is created (an existing client's secret can't be shown again).
#
# *** Test against a non-production Jamf Pro environment first. ***

SCRIPT_NAME="create-jamfscopemap-api-role.sh"
SCRIPT_VERSION="1.1.0"

set -euo pipefail
umask 077

# First line of output identifies the script and version.
echo "$SCRIPT_NAME - $SCRIPT_VERSION"

# Value order: environment variable, then these script defaults, then the
# preference domain below, then (for anything still empty) an interactive
# prompt. Keep secrets out of this file.
SCRIPT_JAMF_ENV=""                       # prod | dev ; empty = ask (JAMF_ENV overrides)
SCRIPT_JAMF_URL=""                       # e.g. https://yourorg.jamfcloud.com
SCRIPT_ROLE_NAME="ScopeMap Read-Only"    # name of the API Role to create/update
SCRIPT_CREATE_CLIENT="no"                 # yes = also create an API Client + secret
SCRIPT_DRY_RUN="no"                     # yes = validate + print payload only

# Shared toolkit preference domain (~/Library/Preferences/<domain>.plist).
# DRY_RUN is deliberately NOT read from it, so a stored value can never turn a
# dry run into a real run.
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
loadSetting JAMF_USER "${ENV_PREFIX}AdminUsername"
loadSetting JAMF_PASS "${ENV_PREFIX}AdminPassword"
loadSetting JAMF_CLIENT_ID "${ENV_PREFIX}APIClientID"
loadSetting JAMF_CLIENT_SECRET "${ENV_PREFIX}APIClientSecret"
loadSetting ROLE_NAME ScopeMapRoleName "$SCRIPT_ROLE_NAME"
loadSetting CREATE_CLIENT ScopeMapCreateClient "$SCRIPT_CREATE_CLIENT"
JAMF_URL="${JAMF_URL%/}"
DRY_RUN="${DRY_RUN:-$SCRIPT_DRY_RUN}"
TOKEN=""

# Lines 2-3: the environment, and where each setting is taken from (values are
# never printed). If the environment was prompted for, that prompt comes first.
echo "Environment: $JAMF_ENV (from $ENV_SOURCE). Settings sources (order: environment, script default, plist $PREF_DOMAIN, then prompt if still empty):"
echo "  ${SETTING_SOURCES%, }"

# The plist holds credentials in plain text; warn if other users can read it.
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
# Prefer an Administrator account; a blank username falls back to an API Client.
if [[ -z "$JAMF_USER" && -z "$JAMF_CLIENT_ID" && -z "$JAMF_CLIENT_SECRET" ]]; then
	promptValue JAMF_USER "Jamf Pro username (leave blank to use an API Client instead)"
fi
if [[ -n "$JAMF_USER" ]]; then
	promptValue JAMF_PASS "Password for $JAMF_USER" secret
else
	promptValue JAMF_CLIENT_ID "API Client ID" secret
	promptValue JAMF_CLIENT_SECRET "API Client secret" secret
fi

# --- Input validation --------------------------------------------------------
[[ -n "$JAMF_URL" ]] || { echo "ERROR: Set JAMF_URL (e.g. https://yourorg.jamfcloud.com)." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
[[ "$CREATE_CLIENT" == "yes" || "$CREATE_CLIENT" == "no" ]] || { echo "ERROR: CREATE_CLIENT must be yes or no." >&2; exit 1; }
[[ "$DRY_RUN" == "yes" || "$DRY_RUN" == "no" ]] || { echo "ERROR: DRY_RUN must be yes or no." >&2; exit 1; }
[[ -n "$ROLE_NAME" ]] || { echo "ERROR: ROLE_NAME must not be empty." >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required (included with macOS 15 and later)." >&2; exit 1; }

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

# --- The ScopeMap read privileges --------------------------------------------
PRIVILEGES=(
	# Devices
	"Read Computers"
	"Read Mobile Devices"
	# Groups
	"Read Smart Computer Groups"
	"Read Static Computer Groups"
	"Read Smart Mobile Device Groups"
	"Read Static Mobile Device Groups"
	"Read Smart User Groups"
	"Read Static User Groups"
	# Deliverables
	"Read Policies"
	"Read macOS Configuration Profiles"
	"Read iOS Configuration Profiles"
	"Read Mac Applications"
	"Read Mobile Device Applications"
	"Read Restricted Software"
	"Read Packages"
	"Read Scripts"
	"Read Printers"
	# Patch (both required)
	"Read Patch Management Software Titles"
	"Read Patch Policies"
	# Enrollment
	"Read Computer PreStage Enrollments"
	"Read Mobile Device PreStage Enrollments"
	"Read Enrollment Customizations"
	"Read Device Enrollment Program Instances"
	# Extension attributes
	"Read Computer Extension Attributes"
	"Read Mobile Device Extension Attributes"
	# Advanced searches
	"Read Advanced Computer Searches"
	"Read Advanced Mobile Device Searches"
	# Organization (Self Service is required alongside Categories)
	"Read Buildings"
	"Read Departments"
	"Read Categories"
	"Read Self Service"
	"Read Sites"
	"Read Distribution Points"
	# Accounts
	"Read Accounts"
	"Read Account Groups"
	"Read User"
	# Settings
	"Read Computer Check-In"
	"Read Inventory Preload Records"
	"Read Webhooks"
)

# --- Helpers -----------------------------------------------------------------
# Quote a value for a curl config read from stdin. Secrets are passed to curl
# this way (printf is a builtin) so they never appear in the process list.
cfgQuote() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '"%s"' "$s"
}

getToken() {
	local resp
	if [[ -n "$JAMF_USER" && -n "$JAMF_PASS" ]]; then
		resp=$(printf 'user = %s\n' "$(cfgQuote "$JAMF_USER:$JAMF_PASS")" |
			curl -sS -K - -X POST --connect-timeout 10 --max-time 60 "$JAMF_URL/api/v1/auth/token") || {
			echo "ERROR: Token request failed (network error)." >&2
			exit 1
		}
		jq -er '.token' <<<"$resp" 2>/dev/null || {
			echo "ERROR: Basic auth token request failed (check URL and credentials)." >&2
			exit 1
		}
	elif [[ -n "$JAMF_CLIENT_ID" && -n "$JAMF_CLIENT_SECRET" ]]; then
		echo "NOTE: Using an API Client. It must already hold every privilege being assigned." >&2
		resp=$(printf 'data-urlencode = %s\n' "$(cfgQuote "client_secret=$JAMF_CLIENT_SECRET")" |
			curl -sS -K - -X POST --connect-timeout 10 --max-time 60 "$JAMF_URL/api/oauth/token" \
				-H "Content-Type: application/x-www-form-urlencoded" \
				--data-urlencode "client_id=$JAMF_CLIENT_ID" \
				--data-urlencode "grant_type=client_credentials") || {
			echo "ERROR: Token request failed (network error)." >&2
			exit 1
		}
		jq -er '.access_token' <<<"$resp" 2>/dev/null || {
			echo "ERROR: OAuth token request failed (check URL and client credentials)." >&2
			exit 1
		}
	else
		echo "ERROR: No credentials. Set JAMF_USER (and JAMF_PASS) for an Administrator account." >&2
		exit 1
	fi
}

# api METHOD PATH [BODY] -> prints the response body; exits on HTTP >= 400.
api() {
	local method="$1" path="$2" body="${3:-}" out code
	local args=(-sS -X "$method" -K - --connect-timeout 10 --max-time 120
		-H "Accept: application/json" -w $'\n%{http_code}')
	[[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
	out=$(printf 'header = %s\n' "$(cfgQuote "Authorization: Bearer $TOKEN")" |
		curl "${args[@]}" "$JAMF_URL$path") || {
		echo "ERROR: $method $path failed (network error)." >&2
		exit 1
	}
	code="${out##*$'\n'}"
	out="${out%$'\n'*}"
	if [[ ! "$code" =~ ^[0-9]+$ || "$code" -ge 400 ]]; then
		echo "ERROR: $method $path -> HTTP $code" >&2
		echo "$out" >&2
		if [[ "$code" == "403" ]]; then
			echo "HINT: 403 usually means the account lacks a privilege it is trying to grant" >&2
			echo "      (privilege-escalation guard). Use a Jamf Pro user account with the" >&2
			echo "      Administrator privilege set, not an API Client." >&2
		fi
		exit 1
	fi
	printf '%s' "$out"
}

# Invalidate the token on exit, on success or failure.
cleanup() {
	local status
	[[ -n "$TOKEN" ]] || return 0
	status=$(printf 'header = %s\n' "$(cfgQuote "Authorization: Bearer $TOKEN")" |
		curl -sS -K - -X POST -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
			"$JAMF_URL/api/v1/auth/invalidate-token" 2>/dev/null) || status="000"
	case "$status" in
		204) echo "Token invalidated." ;;
		401) echo "Token already invalid." ;;
		*) echo "WARNING: Unexpected response invalidating token: HTTP $status" >&2 ;;
	esac
}
trap cleanup EXIT

# --- Production warning and confirmation -------------------------------------
if [[ "$JAMF_ENV" == "prod" ]]; then
	account="API Client"
	[[ -z "$JAMF_USER" ]] || account="user $JAMF_USER"
	{
		echo
		echo "################################################################"
		echo "#  WARNING: YOU ARE TARGETING PRODUCTION"
		echo "#  Server : $JAMF_URL"
		echo "#  Account: $account"
		if [[ "$DRY_RUN" == "yes" ]]; then
			echo "#  DRY_RUN=yes: read-only checks, nothing will be changed."
		else
			echo "#  DRY_RUN=no: this WILL create/update the API Role on PRODUCTION."
		fi
		echo "################################################################"
	} >&2
	if [[ -t 0 ]]; then
		read -rp "Type PROD to continue (anything else cancels): " confirmProd
		[[ "$confirmProd" == "PROD" ]] || { echo "Cancelled. Nothing was changed."; exit 0; }
	elif [[ "$DRY_RUN" == "no" && "${JAMF_PROD_CONFIRM:-}" != "PROD" ]]; then
		echo "ERROR: A non-interactive production run that changes things requires JAMF_PROD_CONFIRM=PROD." >&2
		exit 1
	fi
fi

# --- Authenticate ------------------------------------------------------------
TOKEN=$(getToken)
echo "Authenticated to $JAMF_URL"

# --- Validate privilege names against this Jamf Pro instance -----------------
echo "Validating ${#PRIVILEGES[@]} privilege names..."
if available=$(api GET "/api/v1/api-role-privileges" 2>/dev/null); then
	missing=()
	for p in "${PRIVILEGES[@]}"; do
		jq -e --arg p "$p" '.privileges | index($p)' <<<"$available" >/dev/null || missing+=("$p")
	done
	if ((${#missing[@]} > 0)); then
		echo "ERROR: These privilege names were not found on your server:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		echo "Compare against: GET $JAMF_URL/api/v1/api-role-privileges" >&2
		exit 1
	fi
	echo "All privilege names valid."
else
	echo "WARNING: Could not fetch the privilege list; skipping validation." >&2
fi

PAYLOAD=$(printf '%s\n' "${PRIVILEGES[@]}" | jq -R . | jq -s --arg name "$ROLE_NAME" '{displayName: $name, privileges: .}')

if [[ "$DRY_RUN" == "yes" ]]; then
	echo "DRY_RUN=yes; nothing was changed. Payload would be:"
	jq . <<<"$PAYLOAD"
	exit 0
fi

# --- Create or update the role -----------------------------------------------
existing=$(api GET "/api/v1/api-roles?page=0&page-size=500")
role_id=$(jq -r --arg n "$ROLE_NAME" '.results[] | select(.displayName == $n) | .id' <<<"$existing" | head -n1)

if [[ -n "$role_id" ]]; then
	echo "Role '$ROLE_NAME' exists (id $role_id); updating privileges..."
	api PUT "/api/v1/api-roles/$role_id" "$PAYLOAD" >/dev/null
	echo "Updated role '$ROLE_NAME'."
else
	resp=$(api POST "/api/v1/api-roles" "$PAYLOAD")
	echo "Created role '$ROLE_NAME' (id $(jq -r '.id' <<<"$resp"))."
fi

# --- Optionally create an API Client bound to the role -----------------------
# The API Client is named after the role. Creating one on every run would pile up
# duplicates, so look first: skip if a client has that name or already uses this
# role. If the list can't be read as expected, stop rather than guess.
if [[ "$CREATE_CLIENT" == "yes" ]]; then
	clients=$(api GET "/api/v1/api-integrations")
	existing_clients=$(jq -c --arg n "$ROLE_NAME" '
		(if type == "array" then .
		 elif type == "object" and (.results | type) == "array" then .results
		 else error("unexpected response") end)
		| [ .[] | select(.displayName == $n or ((.authorizationScopes // []) | index($n))) ]
	' <<<"$clients" 2>/dev/null) || {
		echo "ERROR: Unexpected response listing API Clients; not creating one to avoid a duplicate." >&2
		exit 1
	}
	if [[ "$(jq 'length' <<<"$existing_clients")" -gt 0 ]]; then
		echo
		echo "API Client already exists for role '$ROLE_NAME'; not creating another:"
		jq -r '.[] | "  \(.displayName) (id \(.id))"' <<<"$existing_clients"
		echo "  (An existing client's secret can't be shown again. Delete the client in"
		echo "   Jamf Pro first if you need a new one.)"
	else
		client_body=$(jq -n --arg n "$ROLE_NAME" \
			'{displayName: $n, enabled: true, accessTokenLifetimeSeconds: 1800, authorizationScopes: [$n]}')
		client=$(api POST "/api/v1/api-integrations" "$client_body")
		int_id=$(jq -r '.id' <<<"$client")
		client_id=$(jq -r '.clientId' <<<"$client")
		creds=$(api POST "/api/v1/api-integrations/$int_id/client-credentials")
		echo
		echo "API Client created: $ROLE_NAME"
		echo "  Jamf URL     : $JAMF_URL"
		echo "  Client ID    : $client_id"
		# The secret is shown once by design; save it to a password manager now.
		echo "  Client Secret: $(jq -r '.clientSecret' <<<"$creds")"
		echo "  (Save the secret now; it is not shown again.)"
	fi
fi

echo
echo "Reminder: Blueprints and Compliance use Jamf Platform scopes"
echo "(blueprints read, compliance-benchmarks read) and can't be set via this API Role."
