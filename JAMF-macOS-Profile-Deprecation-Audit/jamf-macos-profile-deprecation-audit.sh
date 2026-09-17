#!/bin/bash
# Read-only audit of Jamf Pro configuration profiles for macOS 27 deprecations.
# Author: Karthikeyan Marappan
# LinkedIn: https://www.linkedin.com/in/bewithkarthi/
# Requires: curl and xmllint (included with macOS)
# API role: Read - Computer Configuration Profiles
#
# Script version: 1.0.0
# Rule-set version: macOS-27.2026-09-17
# Last reviewed: 2026-09-17

SCRIPT_VERSION="1.0.0"
RULESET_VERSION="macOS-27.2026-09-17"

set -euo pipefail
umask 077

# Environment variables override these values. Keep committed secrets empty.
SCRIPT_JAMF_URL="https://karthikeyan.jamfcloud.com"
SCRIPT_JAMF_CLIENT_ID="your-api-client-id"
SCRIPT_JAMF_CLIENT_SECRET=""

JAMF_URL="${JAMF_URL:-$SCRIPT_JAMF_URL}"
JAMF_CLIENT_ID="${JAMF_CLIENT_ID:-$SCRIPT_JAMF_CLIENT_ID}"
JAMF_CLIENT_SECRET="${JAMF_CLIENT_SECRET:-$SCRIPT_JAMF_CLIENT_SECRET}"
JAMF_URL="${JAMF_URL%/}"

[[ "$JAMF_URL" != "https://karthikeyan.jamfcloud.com" ]] || {
    echo "ERROR: Set JAMF_URL or replace the placeholder SCRIPT_JAMF_URL." >&2
    exit 1
}
[[ "$JAMF_CLIENT_ID" != "your-api-client-id" ]] || { echo "ERROR: Set SCRIPT_JAMF_CLIENT_ID." >&2; exit 1; }
[[ "$JAMF_URL" == https://* ]] || { echo "ERROR: JAMF_URL must start with https://" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required." >&2; exit 1; }
command -v xmllint >/dev/null || { echo "ERROR: xmllint is required." >&2; exit 1; }

printf 'Jamf Pro URL: %s\n' "$JAMF_URL" >&2

# Prompt only for interactive runs when no secret was supplied.
if [[ -z "${JAMF_CLIENT_SECRET:-}" ]]; then
    [[ -t 0 ]] || { echo "ERROR: Set JAMF_CLIENT_SECRET for non-interactive execution." >&2; exit 1; }
    read -r -s -p "Jamf API client secret: " JAMF_CLIENT_SECRET
    printf '\n' >&2
fi
[[ -n "$JAMF_CLIENT_SECRET" ]] || { echo "ERROR: Jamf API client secret cannot be empty." >&2; exit 1; }

OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jamf-profile-deprecation-audit.XXXXXX")"
CSV_FILE="$OUTPUT_DIR/jamf-deprecated-mdm-audit.csv"
SECRET_FILE="$WORK_DIR/client-secret"
SUMMARY_FILE="$WORK_DIR/findings.tsv"
REPORT_FILE=""

cleanup() {
    [[ -z "$REPORT_FILE" ]] || rm -f "$REPORT_FILE"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" && -w "$OUTPUT_DIR" ]] || { echo "ERROR: OUTPUT_DIR is not writable." >&2; exit 1; }
[[ ! -L "$CSV_FILE" ]] || { echo "ERROR: Refusing to write through a symlinked output file." >&2; exit 1; }

xml_string() {
    xmllint --nonet --xpath "string($2)" "$1" 2>/dev/null
}

validate_xml_root() {
    local xml_file="$1"
    local expected_root="$2"
    local actual_root

    if ! actual_root="$(xmllint --nonet --xpath 'name(/*)' "$xml_file" 2>/dev/null)"; then
        echo "ERROR: Jamf returned invalid XML in $xml_file." >&2
        exit 1
    fi
    [[ "$actual_root" == "$expected_root" ]] || {
        echo "ERROR: Expected Jamf XML root '$expected_root', received '${actual_root:-none}'." >&2
        exit 1
    }
}

plist_has_xpath() {
    local plist_file="$1"
    local xpath="$2"
    local result

    result="$(xmllint --nonet --xpath "boolean($xpath)" "$plist_file" 2>/dev/null)"
    [[ "$result" == "true" ]]
}

payload_type_xpath() {
    # Return an XPath selecting payload dictionaries with the supplied PayloadType.
    printf "%s" "//dict[key[normalize-space(.)='PayloadType' and following-sibling::*[1][self::string and normalize-space(.)='$1']]]"
}

csv_field() {
    local value="$1"
    value=${value//\"/\"\"}
    printf '"%s"' "$value"
}

add_finding() {
    # category, status, replacement, profile ID, name, UUID, payload UUID
    local profile_url="$JAMF_URL/OSXConfigurationProfiles.html?id=$4"

    csv_field "$1" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$2" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$3" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$4" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$profile_url" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$5" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$6" >> "$REPORT_FILE"; printf ',' >> "$REPORT_FILE"
    csv_field "$7" >> "$REPORT_FILE"; printf '\n' >> "$REPORT_FILE"
    printf '%s\t%s\t%s\n' "$1" "$2" "$4" >> "$SUMMARY_FILE"
    matches=$((matches + 1))
}

print_summary() {
    local affected_profiles

    affected_profiles="$(awk -F '\t' '!seen[$3]++ { count++ } END { print count + 0 }' "$SUMMARY_FILE")"

    printf '\n%s\n' '============================================================'
    printf '%s\n' 'Jamf macOS 27 Configuration Profile Audit Summary'
    printf '%s\n' '============================================================'
    printf '%-22s %d\n' 'Profiles scanned:' "$total"
    printf '%-22s %d\n' 'Profiles affected:' "$affected_profiles"
    printf '%-22s %d\n' 'Total findings:' "$matches"

    if [[ "$matches" -gt 0 ]]; then
        printf '\nFindings by category:\n'
        awk -F '\t' '{ count[$1]++ } END { for (item in count) printf "  %-44s %d\n", item, count[item] }' "$SUMMARY_FILE" \
            | sort

        printf '\nFindings by status:\n'
        awk -F '\t' '{ count[$2]++ } END { for (item in count) printf "  %-44s %d\n", item, count[item] }' "$SUMMARY_FILE" \
            | sort
    else
        printf '\nNo matching deprecated or removed settings were found.\n'
    fi

    printf '\n%-22s %s\n' 'CSV report:' "$CSV_FILE"
    printf '%-22s %s\n' 'Script version:' "$SCRIPT_VERSION"
    printf '%-22s %s\n' 'Rule set:' "$RULESET_VERSION"
    printf '%s\n' '============================================================'
}

print_debug_response() {
    local output_file="$1"

    if [[ "${DEBUG:-0}" == "1" && -s "$output_file" ]]; then
        printf 'Jamf response:\n' >&2
        cat "$output_file" >&2
        printf '\n' >&2
    fi
}

jamf_curl() {
    local description="$1"
    local output_file="$2"
    local http_status
    shift 2

    # Keep the response body available for optional diagnostic output.
    if ! http_status="$(curl --silent --show-error "$@" \
        --output "$output_file" --write-out '%{http_code}')"; then
        printf '\nERROR: Jamf connection failed while %s.\n' "$description" >&2
        print_debug_response "$output_file"
        exit 1
    fi

    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        printf 'ERROR: Jamf returned HTTP %s while %s.\n' "$http_status" "$description" >&2
        print_debug_response "$output_file"
        exit 1
    fi
}

token_response="$WORK_DIR/token.json"
printf '%s' "$JAMF_CLIENT_SECRET" > "$SECRET_FILE"
unset JAMF_CLIENT_SECRET SCRIPT_JAMF_CLIENT_SECRET
jamf_curl "obtaining an OAuth access token" "$token_response" \
    --request POST "$JAMF_URL/api/v1/oauth/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --header 'Accept: application/json' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=$JAMF_CLIENT_ID" \
    --data-urlencode "client_secret@$SECRET_FILE"

# access_token is a JWT and cannot contain a double quote; no JSON parser is needed.
ACCESS_TOKEN="$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$token_response" | head -n 1)"
[[ -n "$ACCESS_TOKEN" ]] || { echo "ERROR: OAuth token response did not include access_token." >&2; exit 1; }
AUTH_CONFIG="$WORK_DIR/curl-auth.conf"
printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" > "$AUTH_CONFIG"
unset ACCESS_TOKEN

index_xml="$WORK_DIR/profiles.xml"
jamf_curl "listing macOS configuration profiles" "$index_xml" \
    --config "$AUTH_CONFIG" \
    --header 'Accept: application/xml' \
    "$JAMF_URL/JSSResource/osxconfigurationprofiles"
validate_xml_root "$index_xml" "os_x_configuration_profiles"

profile_count="$(xml_string "$index_xml" '/os_x_configuration_profiles/size')"
[[ "$profile_count" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Jamf profile index did not include a valid profile count." >&2
    exit 1
}

# Store one profile ID per line for the audit loop.
profile_ids_file="$WORK_DIR/profile-ids.txt"
if [[ "$profile_count" == "0" ]]; then
    : > "$profile_ids_file"
else
    xmllint --nonet --xpath '//os_x_configuration_profile/id' "$index_xml" 2>/dev/null \
        | sed 's#</id>#</id>\n#g' \
        | sed -n 's#.*<id>\([^<]*\)</id>.*#\1#p' > "$profile_ids_file"
fi

extracted_profile_count="$(wc -l < "$profile_ids_file" | tr -d ' ')"
[[ "$extracted_profile_count" == "$profile_count" ]] || {
    echo "ERROR: Jamf reported $profile_count profile(s), but $extracted_profile_count valid ID(s) were extracted." >&2
    exit 1
}

# Build the report beside its final destination, then rename it only after a
# successful audit so a failed run cannot replace the last complete report.
REPORT_FILE="$(mktemp "$OUTPUT_DIR/.jamf-deprecated-mdm-audit.XXXXXX")"
printf 'category,status,replacement,profile_id,profile_url,profile_name,profile_uuid,payload_uuid\n' > "$REPORT_FILE"
chmod 600 "$REPORT_FILE"
: > "$SUMMARY_FILE"
matches=0
total="$profile_count"
index=0

while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Jamf returned invalid configuration profile ID '$id'." >&2
        exit 1
    }
    index=$((index + 1))
    profile_xml="$WORK_DIR/profile-$id.xml"
    jamf_curl "retrieving configuration profile ID $id" "$profile_xml" \
        --config "$AUTH_CONFIG" \
        --header 'Accept: application/xml' \
        "$JAMF_URL/JSSResource/osxconfigurationprofiles/id/$id"
    validate_xml_root "$profile_xml" "os_x_configuration_profile"

    returned_id="$(xml_string "$profile_xml" '/os_x_configuration_profile/general/id')"
    [[ "$returned_id" == "$id" ]] || {
        echo "ERROR: Jamf returned profile ID '${returned_id:-none}' while profile ID $id was requested." >&2
        exit 1
    }

    profile_name="$(xml_string "$profile_xml" '/os_x_configuration_profile/general/name')"
    printf 'Checking %d/%d: %s\n' "$index" "$total" "${profile_name:-$id}" >&2

    profile_uuid="$(xml_string "$profile_xml" '/os_x_configuration_profile/general/uuid')"
    tcc_uuid=""
    payload_text="$WORK_DIR/payload-$id.plist"
    xml_string "$profile_xml" '/os_x_configuration_profile/general/payloads' > "$payload_text"
    [[ -s "$payload_text" ]] || {
        echo "ERROR: Jamf profile ID $id did not include configuration-profile payload data." >&2
        exit 1
    }
    xmllint --nonet --noout "$payload_text" 2>/dev/null || {
        echo "ERROR: Jamf profile ID $id contained invalid plist payload data." >&2
        exit 1
    }

    tcc_payload_xpath="$(payload_type_xpath 'com.apple.TCC.configuration-profile-policy')"
    accessibility_xpath="$tcc_payload_xpath/key[normalize-space(.)='Services']/following-sibling::*[1][self::dict]/key[normalize-space(.)='Accessibility']"
    if plist_has_xpath "$payload_text" "$accessibility_xpath"; then
        tcc_uuid="$(xmllint --nonet --xpath "string(($tcc_payload_xpath/key[normalize-space(.)='PayloadUUID']/following-sibling::*[1][self::string])[1])" "$payload_text" 2>/dev/null)"
        accessibility_grant_xpath="$accessibility_xpath/following-sibling::*[1][self::array]//dict[key[normalize-space(.)='Allowed']/following-sibling::*[1][self::true] or key[normalize-space(.)='Authorization']/following-sibling::*[1][self::string and normalize-space(.)='Allow']]"
        if plist_has_xpath "$payload_text" "$accessibility_grant_xpath"; then
            accessibility_status="Grant removed in macOS 27"
        else
            accessibility_status="Deprecated in macOS 27 (non-grant rule)"
        fi
        add_finding "PPPC Accessibility" "$accessibility_status" \
            "DDM com.apple.configuration.app.settings (Privacy key)" \
            "$id" "$profile_name" "$profile_uuid" "$tcc_uuid"
    fi

    software_update_xpath="$(payload_type_xpath 'com.apple.SoftwareUpdate')"
    if plist_has_xpath "$payload_text" "$software_update_xpath"; then
        add_finding "Software Update payload" "Removed in macOS 27" \
            "DDM com.apple.configuration.softwareupdate.settings" \
            "$id" "$profile_name" "$profile_uuid" ""
    fi

    restrictions_xpath="$(payload_type_xpath 'com.apple.applicationaccess')"
    software_deferral_xpath="$restrictions_xpath/key[normalize-space(.)='forceDelayedSoftwareUpdates' or normalize-space(.)='enforcedSoftwareUpdateDelay' or normalize-space(.)='forceDelayedMajorSoftwareUpdates' or normalize-space(.)='enforcedSoftwareUpdateMajorOSDeferredInstallDelay' or normalize-space(.)='forceDelayedAppSoftwareUpdates' or normalize-space(.)='enforcedSoftwareUpdateNonOSDeferredInstallDelay' or normalize-space(.)='enforcedSoftwareUpdateMinorOSDeferredInstallDelay' or normalize-space(.)='ManagedDeferredInstallDelay']"
    if plist_has_xpath "$payload_text" "$software_deferral_xpath"; then
        add_finding "Software Update deferral restriction" "Removed in macOS 27" \
            "DDM com.apple.configuration.softwareupdate.settings" \
            "$id" "$profile_name" "$profile_uuid" ""
    fi

    dns_xpath="$(payload_type_xpath 'com.apple.dnsSettings.managed')"
    if plist_has_xpath "$payload_text" "$dns_xpath"; then
        add_finding "Encrypted DNS payload" "Deprecated in macOS 27" \
            "DDM com.apple.configuration.network.dns-settings" \
            "$id" "$profile_name" "$profile_uuid" ""
    fi

    content_cache_xpath="$(payload_type_xpath 'com.apple.AssetCache.managed')"
    if plist_has_xpath "$payload_text" "$content_cache_xpath"; then
        add_finding "Content Caching payload" "Deprecated in macOS 27" \
            "DDM com.apple.configuration.content-cache.settings" \
            "$id" "$profile_name" "$profile_uuid" ""
    fi

    app_restrictions_xpath="$(payload_type_xpath 'com.apple.applicationaccess.new')"
    if plist_has_xpath "$payload_text" "$app_restrictions_xpath"; then
        add_finding "App allow/deny restrictions" "Deprecated in macOS 27" \
            "DDM com.apple.configuration.app.settings" \
            "$id" "$profile_name" "$profile_uuid" ""
    fi
done < "$profile_ids_file"

mv -f "$REPORT_FILE" "$CSV_FILE"
REPORT_FILE=""

print_summary
