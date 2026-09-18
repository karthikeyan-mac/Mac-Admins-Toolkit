#!/bin/bash

# Karthikeyan Marappan
# Send a Slack notification from a Jamf Pro policy using an incoming webhook.

set -euo pipefail

# Hard-coded defaults. Jamf Pro parameters 4 through 8 override these values.
HARDCODED_SLACK_TITLE_TEXT="Provisioning"
HARDCODED_SLACK_MESSAGE_LINE_1_TEXT="SERIALNUMBER"
HARDCODED_SLACK_COLOR="#008000"
HARDCODED_SLACK_MESSAGE_LINE_2_TEXT="Workflow Completed"
HARDCODED_SLACK_WEBHOOK_URL=""

# Jamf Pro reserves parameters 1 through 3. Empty policy parameters use the
# corresponding hard-coded defaults.
SLACK_TITLE_TEXT="${4:-$HARDCODED_SLACK_TITLE_TEXT}"
SLACK_MESSAGE_LINE_1_TEXT="${5:-$HARDCODED_SLACK_MESSAGE_LINE_1_TEXT}"
SLACK_COLOR="${6:-$HARDCODED_SLACK_COLOR}"
SLACK_MESSAGE_LINE_2_TEXT="${7:-$HARDCODED_SLACK_MESSAGE_LINE_2_TEXT}"
SLACK_WEBHOOK_URL="${8:-$HARDCODED_SLACK_WEBHOOK_URL}"

# Escape a value for inclusion in a JSON string. Jamf script parameters can
# contain quotes, backslashes, and line breaks, all of which must be escaped
# before they are placed in the webhook payload.
json_escape() {
    local value="$1" escaped="" character code
    local LC_CTYPE=C

    while [[ -n "$value" ]]; do
        character=${value%"${value#?}"}
        value=${value#?}

        case "$character" in
            '"') escaped+='\"' ;;
            $'\\') escaped+='\\' ;;
            $'\b') escaped+='\b' ;;
            $'\f') escaped+='\f' ;;
            $'\n') escaped+='\n' ;;
            $'\r') escaped+='\r' ;;
            $'\t') escaped+='\t' ;;
            *)
                # macOS /bin/bash 3.2 treats the byte as a signed char, so
                # bytes >= 0x80 (UTF-8 continuation/lead bytes) come back as
                # large negative numbers here. Mask to the low 8 bits to
                # recover the true byte value before the control-char check,
                # otherwise multi-byte UTF-8 characters get corrupted into
                # bogus \u escapes.
                printf -v code '%d' "'$character"
                (( code &= 0xFF ))
                if (( code < 32 )); then
                    printf -v character '\\u%04x' "$code"
                fi
                escaped+="$character"
                ;;
        esac
    done

    printf '%s' "$escaped"
}

if [[ ! "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.(slack\.com|slack-gov\.com)/services/[^/]+/[^/]+/[^/]+$ ]]; then
    echo "Slack webhook URL is missing or invalid. Configure Jamf parameter 8 or the local fallback." >&2
    exit 1
fi

if [[ -z "$SLACK_TITLE_TEXT" ]]; then
    echo "Slack title text (Jamf parameter 4) must not be empty." >&2
    exit 1
fi

if [[ ! "$SLACK_COLOR" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    echo "Slack color (Jamf parameter 6) must be a #RRGGBB value." >&2
    exit 1
fi

# --- Resolve the SERIALNUMBER placeholder to the Mac's actual serial number ---
# Typing SERIALNUMBER into Jamf parameter 5 (message line 1) triggers this;
# any other value is passed through unchanged as free text.
if [[ "$SLACK_MESSAGE_LINE_1_TEXT" == *"SERIALNUMBER"* ]]; then
    SLACK_MESSAGE_LINE_1_TEXT="$(/usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/ { print $4; exit }')"
fi

# --- Send Slack Notification ---
# Block Kit has no attachment-free way to render a colored side bar, so the
# attachment wrapper is kept solely for its "color" field. Slack's own
# migration guide confirms this is the one legacy attachment field with no
# block equivalent and recommends nesting "blocks" inside the attachment
# rather than using the legacy "text"/"fallback"/"mrkdwn_in" fields:
# https://docs.slack.dev/messaging/migrating-outmoded-message-compositions-to-blocks/
payload=$(/bin/cat <<EOF
{
  "text": "$(json_escape "$SLACK_TITLE_TEXT")",
  "attachments": [
    {
      "color": "$(json_escape "$SLACK_COLOR")",
      "blocks": [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "*$(json_escape "$SLACK_MESSAGE_LINE_1_TEXT")*\n*$(json_escape "$SLACK_MESSAGE_LINE_2_TEXT")*"
          }
        }
      ]
    }
  ]
}
EOF
)

if ! response=$(/usr/bin/curl --silent --show-error --fail \
    --connect-timeout 10 --max-time 30 \
    -X POST -H 'Content-type: application/json' \
    --data "$payload" "$SLACK_WEBHOOK_URL"); then
    echo "Failed to send Slack notification." >&2
    exit 1
fi

if [[ "$response" != "ok" ]]; then
    echo "Slack webhook returned an unexpected response: $response" >&2
    exit 1
fi
