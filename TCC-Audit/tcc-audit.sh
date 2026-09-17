#!/bin/bash
# Read-only audit of TCC privacy records on macOS 27 and later.
# Author: Karthikeyan Marappan

set -euo pipefail

services=(
    Accessibility
    AddressBook
    AppleEvents
    AudioCapture
    BluetoothAlways
    Calendar
    Camera
    DeveloperTool
    FileProviderDomain
    FocusStatus
    ListenEvent
    MediaLibrary
    Microphone
    Motion
    Photos
    PhotosAdd
    PostEvent
    Reminders
    RemoteDesktop
    ScreenCapture
    Siri
    SpeechRecognition
    SystemPolicyAllFiles
    SystemPolicyAppBundles
    SystemPolicyAppData
    SystemPolicyDesktopFolder
    SystemPolicyDeveloperFiles
    SystemPolicyDocumentsFolder
    SystemPolicyDownloadsFolder
    SystemPolicyNetworkVolumes
    SystemPolicyRemovableVolumes
    SystemPolicySysAdminFiles
    WebBrowserPublicKeyCredential
    Willow
)

macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_build="$(/usr/bin/sw_vers -buildVersion)"
macos_major="${macos_version%%.*}"

if [[ ! "$macos_major" =~ ^[0-9]+$ ]] || (( macos_major < 27 )); then
    printf 'ERROR: This audit requires macOS 27 or later; detected macOS %s.\n' "$macos_version" >&2
    exit 1
fi

[[ -x /usr/bin/tccutil ]] || {
    printf 'ERROR: /usr/bin/tccutil is unavailable.\n' >&2
    exit 1
}

empty_services=()
service_errors=()
state_errors=()
successful_services=0
record_count=0

printf '%s\n' '============================================================'
printf '%s\n' 'macOS TCC Service Audit'
printf '%s\n' '============================================================'
printf 'macOS Version : %s\n' "$macos_version"
printf 'Build         : %s\n' "$macos_build"
printf 'Date          : %s\n' "$(/bin/date)"
printf '%s\n' '============================================================'
printf '%s\n' 'TCC Records'
printf '%s\n' '============================================================'

for service in "${services[@]}"; do
    if result="$(/usr/bin/tccutil list -s "$service" 2>&1)"; then
        successful_services=$((successful_services + 1))
    else
        exit_code=$?
        error_text="${result//$'\n'/; }"
        service_errors+=("$service (exit $exit_code): ${error_text:-No error text returned}")
        continue
    fi

    if [[ -z "$result" ]]; then
        empty_services+=("$service")
        continue
    fi

    printf '\n%s\n' '----------------------------------------'
    printf 'Service: %s\n' "$service"
    printf '%s\n' '----------------------------------------'

    while IFS= read -r client_id; do
        [[ -n "$client_id" ]] || continue
        record_count=$((record_count + 1))

        if state="$(/usr/bin/tccutil list -s "$service" -b "$client_id" 2>&1)"; then
            state="${state//$'\n'/; }"
            if [[ -z "$state" ]]; then
                state="unknown"
                state_errors+=("$service / $client_id: Empty authorization state")
            fi
        else
            exit_code=$?
            error_text="${state//$'\n'/; }"
            state="error"
            state_errors+=("$service / $client_id (exit $exit_code): ${error_text:-No error text returned}")
        fi

        printf '%-64s %s\n' "$client_id" "$state"
    done <<< "$result"
done

printf '\n%s\n' '============================================================'
printf '%s\n' 'Services With No Records'
printf '%s\n' '============================================================'

if (( ${#empty_services[@]} > 0 )); then
    printf '%s\n' "${empty_services[@]}"
else
    printf '%s\n' 'None'
fi

printf '\n%s\n' '============================================================'
printf '%s\n' 'Query Errors'
printf '%s\n' '============================================================'

if (( ${#service_errors[@]} > 0 || ${#state_errors[@]} > 0 )); then
    (( ${#service_errors[@]} == 0 )) || printf '%s\n' "${service_errors[@]}"
    (( ${#state_errors[@]} == 0 )) || printf '%s\n' "${state_errors[@]}"
else
    printf '%s\n' 'None'
fi

printf '\n%s\n' '============================================================'
printf '%s\n' 'TCC Audit Summary'
printf '%s\n' '============================================================'
printf 'Services queried successfully : %d/%d\n' "$successful_services" "${#services[@]}"
printf 'TCC records found             : %d\n' "$record_count"
printf 'Service query errors          : %d\n' "${#service_errors[@]}"
printf 'Authorization state errors    : %d\n' "${#state_errors[@]}"
printf '%s\n' '============================================================'

if (( successful_services == 0 )); then
    printf 'ERROR: No TCC services were queried successfully.\n' >&2
    exit 1
fi

if (( ${#service_errors[@]} > 0 || ${#state_errors[@]} > 0 )); then
    exit 2
fi

exit 0
