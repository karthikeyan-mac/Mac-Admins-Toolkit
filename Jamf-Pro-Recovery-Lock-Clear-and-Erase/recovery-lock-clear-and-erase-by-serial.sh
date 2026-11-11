#!/bin/bash

# Clears Recovery Lock and/or erases an Apple Silicon Mac picked by serial number.
# Runs from a Jamf Self Service policy on a tech's Mac. Windows use swiftDialog.
# Author: Karthikeyan Marappan
#
# The tech enters the serial twice, checks the Mac's details, picks a reason and
# types ERASE. The script clears Recovery Lock, waits up to 2 minutes for the Mac
# to reply, then sends the erase. If the Mac has not replied by then (offline),
# the erase is queued behind the Recovery Lock command. If Recovery Lock fails or
# can't be found in Jamf, nothing is erased. Intel Macs are never touched.
# SCRIPT_CLEAR_RECOVERY_LOCK and SCRIPT_ERASE_DEVICE (yes/no) choose what runs, so the
# script can clear Recovery Lock only, erase only, or both. Both "no" is an error.
#
# Policy parameters (each falls back to the SCRIPT_ variable below):
#   4  Jamf Pro URL, https://yourorg.jamfcloud.com
#   5  API client ID
#   6  API client secret (shows in policy logs, use a limited role)
#   7  Link to your Intel Mac article (optional)
#   8  Slack webhook URL for alerts (optional, no URL = no alerts)
# The dry run, clear Recovery Lock, erase, wait time, icon and obliterationBehavior are
# script variables only.
#
# API client privileges: Read Computers, View MDM command information in Jamf Pro
# API, Send Set Recovery Lock Command, Send Computer Remote Wipe Command.
# Needs a logged-in user and swiftDialog. The erase is permanent.

SCRIPT_NAME="recovery-lock-clear-and-erase-by-serial.sh"
SCRIPT_VERSION="1.0.0"

set -euo pipefail
umask 077

echo "$SCRIPT_NAME - $SCRIPT_VERSION"

# Settings. Policy parameters win where there is one. Never commit a real client secret.
SCRIPT_JAMF_URL=""        # parameter 4
SCRIPT_CLIENT_ID=""       # parameter 5
SCRIPT_CLIENT_SECRET=""   # parameter 6
SCRIPT_DRY_RUN="yes"     # yes = details only, no = make changes (script only)
SCRIPT_INTEL_KB_URL=""    # parameter 7
SCRIPT_WAIT_SECONDS="120" # seconds to wait before queuing the erase, 10-120
SCRIPT_ICON=""            # icon: file path, https:// URL or SF=symbol
SCRIPT_SLACK_WEBHOOK_URL=""  # parameter 8
SCRIPT_OBLITERATION="Default" # Default, DoNotObliterate, ObliterateWithWarning or Always (https://learn.jamf.com/r/en-US/technical-articles/Obliteration_Behavior)
SCRIPT_CLEAR_RECOVERY_LOCK="yes" # yes or no: send the Clear Recovery Lock command
SCRIPT_ERASE_DEVICE="yes"        # yes or no: send the erase command (both no = error)

# Organisation settings (no policy parameter)
SCRIPT_DIALOG_TITLE="Recovery Lock and Erase"
SCRIPT_ASM_NAME="Apple School Manager"     # Apple Business or Apple School Manager, no commas
SCRIPT_KB_NAME="Selling Macs"              # name of your Intel Mac article, no commas
SCRIPT_SUPPORT_CONTACT=""                  # added to error windows, e.g. "IT Service Desk"
SCRIPT_DIALOG_BIN="/usr/local/bin/dialog"
SCRIPT_DOCK_ICON="/System/Library/CoreServices/Erase Assistant.app/Contents/Resources/AppIcon.icns"                        # Dock icon: file path or https:// URL (empty = swiftDialog's own icon)
SCRIPT_LOG_DIR=""                          # empty = ~/Library/Logs of the logged-in tech
SCRIPT_PROMPT_TIMEOUT="300"                # seconds before an unanswered window closes, nothing changed (0 = no timeout)

JAMF_URL="${4:-$SCRIPT_JAMF_URL}"
JAMF_URL="${JAMF_URL%/}"
CLIENT_ID="${5:-$SCRIPT_CLIENT_ID}"
CLIENT_SECRET="${6:-$SCRIPT_CLIENT_SECRET}"
DRY_RUN="$SCRIPT_DRY_RUN"
[[ "$DRY_RUN" == "no" ]] || DRY_RUN="yes"
INTEL_KB_URL="${7:-$SCRIPT_INTEL_KB_URL}"
WAIT_SECONDS="$SCRIPT_WAIT_SECONDS"
ICON="$SCRIPT_ICON"
ICON="${ICON:-info}"
OBLITERATION="$SCRIPT_OBLITERATION"
SLACK_URL="${8:-$SCRIPT_SLACK_WEBHOOK_URL}"
DO_LOCK="$SCRIPT_CLEAR_RECOVERY_LOCK"
DO_ERASE="$SCRIPT_ERASE_DEVICE"

TITLE="$SCRIPT_DIALOG_TITLE"
ASM="$SCRIPT_ASM_NAME"
KB="$SCRIPT_KB_NAME"
WARN="orange"   # warning text colour
# every window shows a Dock icon; SCRIPT_DOCK_ICON sets what it looks like
DOCK_ARGS=(--showdockicon)
[[ -z "$SCRIPT_DOCK_ICON" ]] || DOCK_ARGS+=(--dockicon "$SCRIPT_DOCK_ICON")
DIALOG="$SCRIPT_DIALOG_BIN"
PROMPT_TIMEOUT="$SCRIPT_PROMPT_TIMEOUT"
WIDTH=780
POLL=15   # seconds between checks of the command state
TICK=5    # seconds between progress window updates

echo "Settings: policy parameters 4-8, else script variables (values not shown). DRY_RUN=$DRY_RUN, clear Recovery Lock=$DO_LOCK, erase=$DO_ERASE"

# --- Logged-in user and log file -------------------------------------------------
# Policies run as root, so windows and the log file belong to the logged-in user.
consoleUser=$(stat -f '%Su' /dev/console)
consoleUid=$(stat -f '%u' /dev/console)
haveUser="no"
if [[ -n "$consoleUser" && "$consoleUser" != "root" && "$consoleUser" != "loginwindow" ]]; then
	haveUser="yes"
fi

techSerial=$(/usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}' || true)

runAsUser() { launchctl asuser "$consoleUid" /usr/bin/sudo -u "$consoleUser" "$@"; }

# The log lives in the tech's ~/Library/Logs. It is created and written as the tech,
# never as root, so a symlink there cannot make root write somewhere else.
LOG_FILE=""
setupLog() {
	[[ "$haveUser" == "yes" ]] || return 0
	local home dir
	home=$(dscl . -read "/Users/$consoleUser" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
	dir="${SCRIPT_LOG_DIR:-${home:-/Users/$consoleUser}/Library/Logs}"
	LOG_FILE="$dir/recovery-lock-clear-and-erase-by-serial.log"
	if [[ -L "$dir" || -L "$LOG_FILE" ]]; then
		echo "WARNING: the log folder or file is a symlink, so there is no log file."
		LOG_FILE=""
		return 0
	fi
	[[ -d "$dir" ]] || runAsUser /bin/mkdir -p "$dir" 2>/dev/null || true
	# keep one old copy once the log passes 1 MB
	if [[ -f "$LOG_FILE" && $(stat -f '%z' "$LOG_FILE") -gt 1048576 ]]; then
		runAsUser /bin/mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
	fi
	if runAsUser /usr/bin/touch "$LOG_FILE" 2>/dev/null; then
		runAsUser /bin/chmod 600 "$LOG_FILE" 2>/dev/null || true
	else
		echo "WARNING: can't write $LOG_FILE, so there is no log file."
		LOG_FILE=""
	fi
}

# log TEXT: prints to the policy log and adds a timestamped line to the log file.
# The secret, tokens and the erase PIN are never logged.
log() {
	echo "$*"
	if [[ -n "$LOG_FILE" ]]; then
		printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | runAsUser /usr/bin/tee -a "$LOG_FILE" >/dev/null || true
	fi
}

setupLog
log "Run started by $consoleUser on $(hostname) (serial ${techSerial:-unknown}), $SCRIPT_NAME $SCRIPT_VERSION, DRY_RUN=$DRY_RUN, clear Recovery Lock=$DO_LOCK, erase=$DO_ERASE"
# an invalid webhook URL turns the alerts off, it does not stop the run
if [[ -n "$SLACK_URL" && ! "$SLACK_URL" =~ ^https://hooks\.(slack\.com|slack-gov\.com)/services/[^/]+/[^/]+/[^/]+$ ]]; then
	log "WARNING: the Slack webhook URL is not valid, so there are no Slack alerts."
	SLACK_URL=""
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/recovery-lock-erase.XXXXXX")
# The progress window reads its command file as the tech, so it sits in a folder
# the tech can read. Nothing sensitive goes in it.
DIALOG_DIR=$(mktemp -d /private/tmp/recovery-lock-dialog.XXXXXX)
chmod 755 "$DIALOG_DIR"
CMD_FILE="$DIALOG_DIR/commands.txt"
PROGRESS_PID=""
token=""

# --- Windows -------------------------------------------------------------------
# Text goes to swiftDialog as arguments, so nothing from Jamf can run as code.
# \n in a message is a line break, :orange[text] is coloured text.

# notify MESSAGE [ICON]: one OK window, falls back to an AppleScript alert.
notify() {
	[[ "$haveUser" == "yes" ]] || return 0
	local icon="${2:-info}"
	[[ "$icon" != "info" ]] || icon="$ICON"   # the normal icon is SCRIPT_ICON, caution stays a warning
	if [[ -x "$DIALOG" ]]; then
		runAsUser "$DIALOG" --title "${WIN_TITLE:-$TITLE}" --message "$1" --icon "$icon" \
			--titlefont size=20 --messagefont size=13 --button1text "OK" \
			--ontop "${DOCK_ARGS[@]}" --moveable --width "$WIDTH" --height 380 >/dev/null 2>&1 || true
	else
		runAsUser /usr/bin/osascript -e 'on run argv' \
			-e 'display dialog (item 1 of argv) with title (item 2 of argv) buttons {"OK"} default button "OK"' \
			-e 'end run' -- "$1" "$TITLE" >/dev/null 2>&1 || true
	fi
}

# dialogJson HEIGHT ARGS...: shows a window, saves what the tech entered in
# $WORK_DIR/dlg.json and sets DLG_RC (0 = main button, 4 = timed out, else
# cancelled). The window has a countdown (swiftDialog --timer) so a window left
# open can't sit there forever.
dialogJson() {
	local height="$1" timer=()
	shift
	((PROMPT_TIMEOUT == 0)) || timer=(--timer "$PROMPT_TIMEOUT")
	DLG_RC=0
	runAsUser "$DIALOG" "$@" --title "${WIN_TITLE:-$TITLE}" --titlefont size=20 --messagefont size=13 \
		"${DOCK_ARGS[@]}" --moveable --width "$WIDTH" --height "$height" --json ${timer[@]+"${timer[@]}"} \
		> "$WORK_DIR/dlg.json" 2>/dev/null || DLG_RC=$?
}

# stops quietly when the window was cancelled or timed out
exitUnlessContinued() {
	[[ "$DLG_RC" == "0" ]] && return 0
	WIN_TITLE=""
	if [[ "$DLG_RC" == "4" ]]; then
		log "Timed out waiting for the technician. Nothing was changed."
	else
		log "Cancelled. Nothing was changed."
	fi
	exit 0
}

# dialogField NAME LABEL: a value the tech entered, found by name, then by label.
dialogField() {
	local v
	v=$(plutil -extract "$1" raw -o - "$WORK_DIR/dlg.json" 2>/dev/null || true)
	[[ -n "$v" ]] || v=$(plutil -extract "$2" raw -o - "$WORK_DIR/dlg.json" 2>/dev/null || true)
	printf '%s' "$v"
}

# Every window uses DOCK_ARGS (--showdockicon), so swiftDialog has a Dock icon the tech can click
# if a window ends up behind others (and does not open a second copy by mistake).
# Progress window, updated through its command file. No Cancel button: the tech
# waits and the button turns into Done at the end. It is not on top, so the tech can
# keep working during the wait. Only the final windows (finishWindow and notify) are
# on top, so the result can't be left behind other windows.
dlgCmd() { echo "$1" >> "$CMD_FILE" 2>/dev/null || true; }
progressAlive() { [[ -n "$PROGRESS_PID" ]] && kill -0 "$PROGRESS_PID" 2>/dev/null; }

STEP_LOCK="Clear Recovery Lock"
STEP_ERASE="Erase the Mac"
# setStep TITLE STATUS TEXT (status: wait, success, fail, pending)
setStep() { dlgCmd "listitem: title: $1, status: $2, statustext: $3"; }
mmss() { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }
# the info box under the icon shows the live status
# infoText LOCK ERASE WAITED [SEPARATOR]: only the requested actions are listed.
infoText() {
	local sep="${4:-\\n\\n}" t="### Status"
	[[ "$DO_LOCK" == "no" ]] || t+="${sep}**Recovery Lock:** $1"
	[[ "$DO_ERASE" == "no" ]] || t+="${sep}**Erase:** $2"
	[[ "$DO_LOCK" == "no" ]] || t+="${sep}**Waited:** $3 of $(mmss "$WAIT_SECONDS")"
	printf '%s' "$t"
}
infoLive() { dlgCmd "infobox: $(infoText "$1" "$2" "$3" '<br><br>')"; }

# startProgress MESSAGE INFOBOX
startProgress() {
	# the checklist shows only the requested actions
	local listArgs=()
	[[ "$DO_LOCK" == "no" ]] || listArgs+=(--listitem "$STEP_LOCK")
	[[ "$DO_ERASE" == "no" ]] || listArgs+=(--listitem "$STEP_ERASE")
	: > "$CMD_FILE"
	chmod 666 "$CMD_FILE"
	runAsUser "$DIALOG" --title "$TITLE" --message "$1" --icon "$ICON" \
		--titlefont size=20 --messagefont size=13 \
		--infobox "$2" --infoboxwidth 230 \
		${listArgs[@]+"${listArgs[@]}"} \
		--progress 100 --progresstext "Starting..." --button1text "Please wait..." \
		--commandfile "$CMD_FILE" "${DOCK_ARGS[@]}" --moveable --width "$WIDTH" --height 560 >/dev/null 2>&1 &
	PROGRESS_PID=$!
	sleep 2   # let the window open before sending commands
	dlgCmd "button1: disable"
	[[ "$DO_LOCK" == "no" ]] || setStep "$STEP_LOCK" wait "Waiting for the Mac"
	[[ "$DO_ERASE" == "no" ]] || setStep "$STEP_ERASE" pending "Not started"
}

# finishWindow TITLE ICON MESSAGE: closes the progress window and shows the result in
# a new window with no timeout. It stays on top until Done is clicked, so the tech
# always sees the result. (A result in the progress window had no way to be a new
# window with its own settings, so this is a separate window.)
finishWindow() {
	local icon="$2"
	[[ "$icon" != "info" ]] || icon="$ICON"   # the normal icon is SCRIPT_ICON, caution stays a warning
	stopProgress
	runAsUser "$DIALOG" --title "$1" --message "$3" --icon "$icon" \
		--titlefont size=20 --messagefont size=13 --button1text "Done" \
		--ontop "${DOCK_ARGS[@]}" --moveable --width "$WIDTH" --height 480 >/dev/null 2>&1 || true
}

stopProgress() {
	if [[ -n "$PROGRESS_PID" ]]; then
		dlgCmd "quit:"
		sleep 1
		PROGRESS_PID=""
	fi
}

# --- Cleanup and errors --------------------------------------------------------
invalidateToken() {
	[[ -n "$1" ]] || return 0
	printf 'header = "Authorization: Bearer %s"\n' "$1" |
		curl -s -o /dev/null --config - -X POST "$JAMF_URL/api/v1/auth/invalidate-token" || true
}

cleanup() {
	stopProgress
	invalidateToken "$token"
	rm -rf "$WORK_DIR" "$DIALOG_DIR"
}
trap cleanup EXIT

# --- Slack alerts (optional) -----------------------------------------------------
# jsonEscape VALUE: escapes a value for a JSON string (names from Jamf can hold
# quotes or backslashes). Same function as in Jamf-Pro-Slack-Notifications.
jsonEscape() {
	local value="$1" escaped="" character code
	local LC_CTYPE=C
	while [[ -n "$value" ]]; do
		character=${value%"${value#?}"}
		value=${value#?}
		# shellcheck disable=SC1003
		case "$character" in
			'"') escaped+='\"' ;;
			$'\\') escaped+='\\' ;;
			$'\b') escaped+='\b' ;;
			$'\f') escaped+='\f' ;;
			$'\n') escaped+='\n' ;;
			$'\r') escaped+='\r' ;;
			$'\t') escaped+='\t' ;;
			*)
				# bash 3.2 reads bytes >= 0x80 as negative numbers, so mask to the
				# real byte value or UTF-8 characters get corrupted
				printf -v code '%d' "'$character"
				((code &= 0xFF))
				if ((code < 32)); then printf -v character '\\u%04x' "$code"; fi
				escaped+="$character"
				;;
		esac
	done
	printf '%s' "$escaped"
}

# slackPost COLOUR EMOJI TITLE STATUS [PROBLEM]: posts one Block Kit message: a header,
# two columns of details, an optional problem box and a small footer. Best effort: a
# Slack problem is logged and never stops or changes the run. The webhook URL goes to
# curl on stdin, so it is not in the process list or the log.
slackRequested="no"
slackDone="no"
slackSerial=""
slackName=""
slackModel=""
slackUserName=""
slackEmail=""
slackReason=""
slackAction=""

# slackText VALUE: Slack mrkdwn treats & < > as markup (<!channel> would ping people),
# so they are escaped before the value goes in a message.
slackText() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# slackField LABEL VALUE: one "label over value" cell for the two-column details.
slackField() {
	printf '{"type":"mrkdwn","text":"*%s*\\n%s"}' "$1" "$(jsonEscape "$(slackText "$2")")"
}

slackPost() {
	[[ -n "$SLACK_URL" ]] || return 0
	local colour="$1" emoji="$2" title="$3" status="$4" problem="${5:-}"
	local fields blocks payload
	fields="$(slackField "Serial" "$slackSerial"),$(slackField "Computer name" "$slackName"),$(slackField "Model" "$slackModel"),$(slackField "Action" "$slackAction"),$(slackField "User" "$slackUserName"),$(slackField "Email" "$slackEmail")"
	[[ -z "$slackReason" ]] || fields+=",$(slackField "Reason" "$slackReason")"
	fields+=",$(slackField "Status" "$status")"
	blocks="{\"type\":\"header\",\"text\":{\"type\":\"plain_text\",\"text\":\"$emoji $(jsonEscape "$title")\",\"emoji\":true}}"
	blocks+=",{\"type\":\"section\",\"fields\":[$fields]}"
	if [[ -n "$problem" ]]; then
		blocks+=",{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"*Problem*\\n$(jsonEscape "$(slackText "$problem")")\"}}"
	fi
	blocks+=",{\"type\":\"context\",\"elements\":[{\"type\":\"mrkdwn\",\"text\":\"Triggered by *$(jsonEscape "$(slackText "$consoleUser")")* from Mac $(jsonEscape "$(slackText "${techSerial:-unknown}")") | $(jsonEscape "$SCRIPT_NAME") $SCRIPT_VERSION\"}]}"
	payload="{\"text\":\"$(jsonEscape "$title")\",\"attachments\":[{\"color\":\"$colour\",\"blocks\":[$blocks]}]}"
	if printf 'url = "%s"\n' "$SLACK_URL" | curl --silent --fail --connect-timeout 5 --max-time 10 \
		--config - -X POST -H 'Content-type: application/json' --data "$payload" >/dev/null 2>&1; then
		log "Slack alert sent: $title"
	else
		log "WARNING: could not send the Slack alert: $title"
	fi
}

# plain MESSAGE: the message without window markup, for the logs and Slack.
plain() { printf '%s' "${1//\\n/ }" | sed -E 's/:[a-z]+\[([^]]*)\]/\1/g; s/\*\*//g'; }

# fail MESSAGE: logs the error, shows it to the tech and exits. If the erase was
# already requested, Slack gets a failure alert too.
fail() {
	log "ERROR: $(plain "$1")"
	if [[ "$slackRequested" == "yes" && "$slackDone" == "no" ]]; then
		slackDone="yes"
		slackPost "#FF0000" ":x:" "$ACTION_TITLE FAILED" "Failed" "$(plain "$1")"
	fi
	stopProgress
	WIN_TITLE="Something went wrong"
	notify "$1${SCRIPT_SUPPORT_CONTACT:+\n\nNeed help? $SCRIPT_SUPPORT_CONTACT}" caution
	exit 1
}

# --- Check the settings ----------------------------------------------------------
[[ "$haveUser" == "yes" ]] || fail "Nobody is logged in to the Mac, so the windows can't be shown."
[[ -x "$DIALOG" ]] || fail "swiftDialog was not found at $DIALOG. Install it and run this again."
[[ "$JAMF_URL" == https://* ]] || fail "Policy parameter 4 (or SCRIPT_JAMF_URL) must be the Jamf Pro URL starting with https://"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail "Policy parameters 5 and 6 (or SCRIPT_CLIENT_ID and SCRIPT_CLIENT_SECRET) are required."
if [[ ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || ((WAIT_SECONDS < 10 || WAIT_SECONDS > 120)); then
	fail "SCRIPT_WAIT_SECONDS must be a number from 10 to 120."
fi
# what to do: both "no" has nothing to do, so it is an error (exit 1)
for opt in "$DO_LOCK" "$DO_ERASE"; do
	[[ "$opt" == "yes" || "$opt" == "no" ]] || fail "SCRIPT_CLEAR_RECOVERY_LOCK and SCRIPT_ERASE_DEVICE must each be yes or no."
done
if [[ "$DO_LOCK" == "no" && "$DO_ERASE" == "no" ]]; then
	fail ":${WARN}[Nothing to do.]\n\nSCRIPT_CLEAR_RECOVERY_LOCK and SCRIPT_ERASE_DEVICE are both set to no. Set at least one to yes. Nothing was changed."
fi
case "$OBLITERATION" in
	Default | DoNotObliterate | ObliterateWithWarning | Always) ;;
	*) fail "SCRIPT_OBLITERATION must be Default, DoNotObliterate, ObliterateWithWarning or Always." ;;
esac
# the reason list is comma separated, so these can't hold commas
if [[ -z "$ASM" || "$ASM" == *,* || -z "$KB" || "$KB" == *,* ]]; then
	fail "SCRIPT_ASM_NAME and SCRIPT_KB_NAME can't be empty or contain commas."
fi

if [[ ! "$PROMPT_TIMEOUT" =~ ^[0-9]+$ ]] || ((PROMPT_TIMEOUT != 0 && (PROMPT_TIMEOUT < 30 || PROMPT_TIMEOUT > 3600))); then
	fail "SCRIPT_PROMPT_TIMEOUT must be 0 (no timeout) or a number from 30 to 3600."
fi

# wording for the windows, logs and Slack, by what the script is set to do
if [[ "$DO_LOCK" == "yes" && "$DO_ERASE" == "yes" ]]; then
	ACTION_TITLE="Recovery Lock and Erase"
	ACTION_DESC="Clear Recovery Lock, then erase"
	introText="clears Recovery Lock and then erases an Apple Silicon Mac that is managed in Jamf Pro. Use it to reimage, retire or sell a Mac."
	dryAction="have its Recovery Lock cleared and then be erased"
	NOT_ERASED_NOTE=":${WARN}[The Mac was NOT erased.] "
elif [[ "$DO_LOCK" == "yes" ]]; then
	ACTION_TITLE="Recovery Lock clear"
	ACTION_DESC="Clear Recovery Lock only"
	introText="clears Recovery Lock on an Apple Silicon Mac that is managed in Jamf Pro. :${WARN}[The Mac is not erased.]"
	dryAction="have its Recovery Lock cleared (it would not be erased)"
	NOT_ERASED_NOTE=""
else
	ACTION_TITLE="Erase"
	ACTION_DESC="Erase only"
	introText="erases an Apple Silicon Mac that is managed in Jamf Pro. :${WARN}[Recovery Lock is not cleared.] Use it to reimage, retire or sell a Mac."
	dryAction="be erased (Recovery Lock would not be cleared)"
	NOT_ERASED_NOTE=""
fi

# the default window title follows the mode, so a Recovery Lock only run never says
# "Erase". A title you set yourself is kept.
if [[ "$TITLE" == "Recovery Lock and Erase" ]]; then
	if [[ "$DO_ERASE" == "no" ]]; then
		TITLE="Clear Recovery Lock"
	elif [[ "$DO_LOCK" == "no" ]]; then
		TITLE="Erase Mac"
	fi
fi

if ((WAIT_SECONDS % 60 == 0)); then
	waitText="$((WAIT_SECONDS / 60)) minute(s)"
else
	waitText="$WAIT_SECONDS seconds"
fi

# --- Window 1: serial number ---------------------------------------------------
dryNote=""
[[ "$DRY_RUN" == "yes" ]] && dryNote="**DRY RUN:** nothing will be changed. You will only see the Mac's details.\n\n"

retireNote=""
[[ "$DO_ERASE" == "no" ]] || retireNote="\n\n**Retiring or selling?** :${WARN}[Remove the device from ${ASM} first.] Not needed for a reimage."

infoArgs=()
if [[ "$INTEL_KB_URL" == https://* ]]; then
	infoArgs=(--infobuttontext "More info" --infobuttonaction "$INTEL_KB_URL")
fi

# the steps table in the first window lists only what will happen
stepRows="| 1 | Enter the serial number twice |\n"
if [[ "$DO_ERASE" == "yes" ]]; then
	stepRows+="| 2 | Check the Mac's details and choose the reason |\n"
else
	stepRows+="| 2 | Check the Mac's details |\n"
fi
stepNo=3
if [[ "$DO_LOCK" == "yes" ]]; then
	if [[ "$DO_ERASE" == "yes" ]]; then
		stepRows+="| $stepNo | Recovery Lock is cleared (the Mac must be online). No reply within ${waitText}: the erase is queued |\n"
	else
		stepRows+="| $stepNo | Recovery Lock is cleared (the Mac must be online). No reply within ${waitText}: the command is queued |\n"
	fi
	stepNo=$((stepNo + 1))
fi
[[ "$DO_ERASE" == "no" ]] || stepRows+="| $stepNo | The Mac is erased. :${WARN}[This cannot be undone.] |\n"

# swiftDialog's "confirm" adds a second field that must match the first
serial=""
for attempt in 1 2; do
	WIN_TITLE="$TITLE"
	problem=""
	if ((attempt > 1)); then
		WIN_TITLE="Serial number not valid - try again"
		problem="**Please fix this:** :${WARN}[That serial number is not valid.]\n\n"
	fi
	dialogJson 500 \
		--message "${dryNote}${problem}This utility ${introText}\n\n| Step | What happens |\n|:--|:--|\n${stepRows%\\n}" \
		--icon "$ICON" \
		--infobox "### Before you start\n\n**Apple Silicon only.**\n\n**Intel Macs:** use the ${KB} workflow (More info button).${retireNote}" \
		--infoboxwidth 230 \
		--textfield "Serial number,required,confirm,name=serial,regex=^[A-Za-z0-9]+\$,regexerror=Letters and digits only" \
		--textfieldlivevalidation \
		--button1text "Continue" --button2text "Cancel" ${infoArgs[@]+"${infoArgs[@]}"}
	exitUnlessContinued
	entered=$(dialogField serial "Serial number" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
	if [[ "$entered" =~ ^[A-Z0-9]{8,14}$ ]]; then
		serial="$entered"
		break
	fi
done
WIN_TITLE=""
[[ -n "$serial" ]] || fail "The serial number was not valid. Nothing was changed."
log "Serial number entered: $serial"

# --- Jamf API --------------------------------------------------------------------
# The token stays in the main shell (never inside $(...)) so a renewed token is
# used everywhere. API client tokens can be short lived, so it is renewed at half
# its lifetime and again on a 401.
tokenTime=0
tokenLife=60
TOKEN_ERROR=""
getToken() {
	local st t old="$token" life
	printf '%s' "$CLIENT_SECRET" > "$WORK_DIR/secret"   # in a file, not on the command line
	st=$(curl -s -X POST "$JAMF_URL/api/oauth/token" \
		--data-urlencode "client_id=$CLIENT_ID" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret@$WORK_DIR/secret" \
		-o "$WORK_DIR/token.json" -w '%{http_code}') || st="000"
	if [[ ! "$st" =~ ^2 ]]; then TOKEN_ERROR="HTTP $st"; return 1; fi
	t=$(plutil -extract access_token raw "$WORK_DIR/token.json" 2>/dev/null || true)
	if [[ -z "$t" ]]; then TOKEN_ERROR="no access token returned"; return 1; fi
	token="$t"
	life=$(plutil -extract expires_in raw "$WORK_DIR/token.json" 2>/dev/null || true)
	[[ "$life" =~ ^[0-9]+$ ]] && tokenLife="$life" || tokenLife=60
	tokenTime=$SECONDS
	invalidateToken "$old"
}

# apiTry METHOD PATH [curl args]: sets API_STATUS, saves the reply in
# $WORK_DIR/out.json and never exits.
API_STATUS=""
apiTry() {
	local method="$1" path="$2" attempt
	shift 2
	if ((SECONDS - tokenTime >= tokenLife / 2)); then
		getToken || echo "Could not renew the token early: $TOKEN_ERROR" >&2
	fi
	for attempt in 1 2; do
		# the token goes on stdin so it is not in the process list
		API_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
			curl -s --retry 2 --config - -X "$method" "$JAMF_URL$path" \
				-H "Accept: application/json" "$@" \
				-o "$WORK_DIR/out.json" -w '%{http_code}') || API_STATUS="000"
		if [[ "$API_STATUS" == "401" && "$attempt" == "1" ]]; then
			echo "Token rejected (401), getting a new one..."
			getToken || { echo "Could not renew the token: $TOKEN_ERROR" >&2; return 0; }
			continue
		fi
		break
	done
}

# What we are doing, and what to add to an error ("the Mac was NOT erased").
STEP="contact Jamf Pro"
AFTER_FAIL_NOTE=""

value() { plutil -extract "$1" raw "$WORK_DIR/out.json" 2>/dev/null || true; }
# first non-empty value of several keys (field names differ between versions)
firstValue() {
	local k v
	for k in "$@"; do
		v=$(value "$k")
		if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
	done
}

# api METHOD PATH [curl args]: like apiTry, but stops with a readable message.
api() {
	local detail why
	apiTry "$@"
	[[ "$API_STATUS" =~ ^2 ]] && return 0
	cat "$WORK_DIR/out.json" >&2 2>/dev/null || true
	echo >&2
	detail=$(value errors.0.description)
	case "$API_STATUS" in
		401) why="Jamf rejected the API client even after renewing the token. Check the API client's role privileges." ;;
		403) why="The API client isn't allowed to do this. Check its role privileges." ;;
		404)
			if [[ "$2" == /api/v2/mdm/commands* ]]; then
				why="Jamf has no MDM-managed device for this Mac. The record may be stale, unenrolled or unmanaged. Nothing was sent to the Mac."
			else
				why="Jamf could not find what was asked for."
			fi ;;
		000) why="Could not reach Jamf Pro. Check the network and the Jamf URL." ;;
		5*) why="Jamf Pro reported a problem (HTTP $API_STATUS). Try again in a few minutes." ;;
		*) why="Jamf did not accept the request (HTTP $API_STATUS).${detail:+ Jamf said: $detail.}" ;;
	esac
	fail ":${WARN}[Could not $STEP.]\n\n$why${AFTER_FAIL_NOTE:+\n\n$AFTER_FAIL_NOTE}"
}

getToken || fail "Could not get a Jamf token ($TOKEN_ERROR). Check the Jamf URL, client ID and secret."

# --- Find the Mac ----------------------------------------------------------------
STEP="look up the computer in Jamf Pro"
api GET "/api/v4/computers-inventory?section=GENERAL&section=HARDWARE&section=USER_AND_LOCATION&filter=hardware.serialNumber==$serial"
count=$(value totalCount)
# exactly one record, and it has to be this serial
if [[ "$count" != "1" || -n "$(value results.1.id)" ]]; then
	fail ":${WARN}[Serial number not found, or duplicate records.]\n\nJamf Pro has ${count:-0} computers with serial $serial (expected exactly 1). Check the serial number. If there are duplicates, delete the stale record in Jamf. Nothing was changed."
fi
recordSerial=$(value results.0.hardware.serialNumber | tr '[:lower:]' '[:upper:]')
[[ "$recordSerial" == "$serial" ]] || fail ":${WARN}[Serial number mismatch.]\n\nJamf returned a record for '$recordSerial', not $serial. Nothing was changed."

mgmtId=$(value results.0.general.managementId)
compName=$(value results.0.general.name)
model=$(value results.0.hardware.model)
modelId=$(value results.0.hardware.modelIdentifier)
appleSilicon=$(value results.0.hardware.appleSilicon)
username=$(value results.0.userAndLocation.username)
userRealName=$(value results.0.userAndLocation.realname)
email=$(value results.0.userAndLocation.email)
lastCheckIn=$(firstValue results.0.general.lastContactTime results.0.general.lastContact)
managed=$(value results.0.general.remoteManagement.managed)

# Check the Mac is managed before anything else. An unmanaged record can still hold a
# management ID, but Jamf cannot send it MDM commands. Stop here, send nothing.
if [[ "$managed" != "true" ]]; then
	log "ERROR: $serial is not managed in Jamf Pro (remoteManagement.managed='${managed:-not reported}'). Nothing was sent."
	fail ":${WARN}[Mac is not managed.]\n\n$serial (${model:-unknown model}) is unmanaged in Jamf Pro, so MDM commands can't be sent to it. Nothing was changed."
fi

[[ -n "$appleSilicon" ]] || fail "Jamf Pro did not report the chip type for $serial. Nothing was changed."

if [[ "$appleSilicon" != "true" ]]; then
	intelMsg=":${WARN}[Intel Mac - not supported]\n\n$serial (${modelId:-unknown model}) is an Intel Mac. This tool only supports Apple Silicon.\n\n:${WARN}[Nothing was changed.] Refer to the ${KB} article for Intel Macs."
	log "ERROR: $serial (${modelId:-unknown model}) is an Intel Mac. Apple Silicon only. Nothing was changed."
	if [[ "$INTEL_KB_URL" == https://* ]]; then
		runAsUser "$DIALOG" --title "$TITLE" --message "$intelMsg" --icon caution \
			--titlefont size=20 --messagefont size=13 --button1text "Close" \
			--infobuttontext "Open ${KB} article" --infobuttonaction "$INTEL_KB_URL" \
			"${DOCK_ARGS[@]}" --moveable --width "$WIDTH" --height 380 >/dev/null 2>&1 || true
	else
		notify "$intelMsg" caution
	fi
	exit 1
fi

# the management ID decides which device gets every command, so it must look like a UUID
[[ "$mgmtId" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail ":${WARN}[This Mac can't receive commands.]\n\n$serial has no valid management ID in Jamf Pro (is it MDM managed?). Nothing was changed."
readonly mgmtId

# --- Window 2: check the details and confirm ----------------------------------------
# values from Jamf go in a Markdown table, so | and line breaks are removed first
mdv() { local v; v=$(printf '%s' "${1:-}" | tr '|\n\r' '/  '); printf '%s' "${v:-not reported}"; }
details="| Detail | Value |\n|:--|:--|\n| **Serial** | $serial |\n| **Computer name** | $(mdv "$compName") |\n| **Username** | $(mdv "$username") |\n| **Email address** | $(mdv "$email") |\n| **Model** | $(mdv "$model") ($(mdv "$modelId")) |\n| **Last check-in** | $(mdv "$lastCheckIn") |"

log "Found $serial ($modelId), computer name ${compName:-not reported}, username ${username:-not reported}, last check-in ${lastCheckIn:-not reported}"

if [[ "$DRY_RUN" == "yes" ]]; then
	notify "**Dry run - nothing was changed.**\n\n$details\n\nIn a real run this Mac would ${dryAction}. Set SCRIPT_DRY_RUN to **no** in the script to make changes." info
	log "DRY_RUN=yes: nothing was sent."
	exit 0
fi

# One required list for the reason, then ERASE. The list starts empty (no default),
# and swiftDialog won't close the window until a reason is chosen. It returns the
# choice as purpose.selectedIndex: 0 = reimage, 1 = retire or sell, -1 = nothing.
purposeReimage="Reimage the device"
purposeRetire="Retired or Sold - Removed from ${ASM}"
confirmed="no"
purpose=""
retryWhy=""
if [[ "$DO_ERASE" == "yes" ]]; then
	confirmTitle="Check this Mac - it will be erased"
	confirmButton="Erase"
	[[ "$DO_LOCK" == "no" ]] || confirmButton="Clear Recovery Lock and Erase"
	confirmIcon="caution"
	reasonArgs=(--selecttitle "Why is this Mac being erased?,required,name=purpose"
		--selectvalues "$purposeReimage,$purposeRetire"
		--textfield "Type ERASE to confirm,required,name=confirm")
	if [[ "$DO_LOCK" == "yes" ]]; then
		confirmMsg="This Mac will be :${WARN}[permanently erased.] If it does not reply within ${waitText}, the erase is queued.\n\nChoose the reason below, then type **ERASE** to continue."
		confirmInfo="### What happens next\n\n1. **Recovery Lock** is cleared.\n2. The Mac is **erased**.\n\n**The Mac must be online.** If it is offline, both commands are queued in Jamf.\n\n:${WARN}[This cannot be undone.]"
	else
		confirmMsg="This Mac will be :${WARN}[permanently erased.] Recovery Lock will :${WARN}[not] be cleared. If the Mac is offline, the erase is queued.\n\nChoose the reason below, then type **ERASE** to continue."
		confirmInfo="### What happens next\n\nThe Mac is **erased**. Recovery Lock is **not** cleared.\n\n**The Mac must be online.** If it is offline, the erase is queued in Jamf.\n\n:${WARN}[This cannot be undone.]"
	fi
else
	# Recovery Lock only: nothing is erased, so there is no reason or ERASE to type
	confirmTitle="Check this Mac - Recovery Lock will be cleared"
	confirmButton="Clear Recovery Lock"
	confirmIcon="$ICON"
	reasonArgs=()
	confirmMsg="Recovery Lock will be cleared on this Mac. It will :${WARN}[not] be erased. If it does not reply within ${waitText}, the command is queued.\n\nClick **Clear Recovery Lock** to continue."
	confirmInfo="### What happens next\n\n**Recovery Lock** is cleared. The Mac is **not** erased.\n\n**The Mac must be online.** If it is offline, the command is queued in Jamf."
fi
for attempt in 1 2; do
	WIN_TITLE="$confirmTitle"
	problem=""
	if ((attempt > 1)); then
		WIN_TITLE="Please complete the form to continue"
		problem="**Please fix this:** :${WARN}[$retryWhy]\n\n"
	fi
	dialogJson 500 \
		--message "${problem}**Please check these details.**\n\n$details\n\n${confirmMsg}" \
		--icon "$confirmIcon" \
		--infobox "$confirmInfo" \
		--infoboxwidth 230 \
		${reasonArgs[@]+"${reasonArgs[@]}"} \
		--hidedefaultkeyboardaction \
		--button1text "$confirmButton" --button2text "Cancel"
	exitUnlessContinued
	if [[ "$DO_ERASE" == "no" ]]; then confirmed="yes"; break; fi
	case "$(dialogField purpose.selectedIndex SelectedIndex)" in
		0) purpose="reimage" ;;
		1) purpose="retire" ;;
		*) purpose="" ;;
	esac
	typed=$(dialogField confirm "Type ERASE to confirm")
	if [[ -z "$purpose" ]]; then
		retryWhy="Choose why this Mac is being erased."
	elif [[ "$typed" != "ERASE" ]]; then
		retryWhy="Type ERASE to confirm."
	else
		confirmed="yes"
		break
	fi
done
WIN_TITLE=""
if [[ "$confirmed" != "yes" ]]; then
	log "Not confirmed ($retryWhy) Nothing was changed."
	notify ":${WARN}[Nothing was changed.]\n\n$retryWhy" caution
	exit 0
fi
log "Technician confirmed. Reason: ${purpose:-not applicable (Recovery Lock only)}"

if [[ "$purpose" == "retire" ]]; then reasonText="Retired or sold"; else reasonText="Reimage"; fi
slackSerial="$serial"
slackName="$(mdv "$compName")"
slackModel="$(mdv "$model")"
slackUserName="$(mdv "${userRealName:-$username}")"
slackEmail="$(mdv "$email")"
slackAction="$ACTION_DESC"
[[ "$DO_ERASE" == "no" ]] || slackReason="$reasonText"
# One Slack message per run, sent at the end (done, queued or failed), so there is
# no separate "requested" post. slackRequested means the tech confirmed, so a failure
# from here on is reported.
slackRequested="yes"

# --- Clear Recovery Lock -----------------------------------------------------------
cmdUuid=""
cmdState=""
cmdError=""
readCommand() {
	cmdUuid=$(value results.0.uuid)
	cmdState=$(value results.0.commandState)
	cmdError=$(value results.0.commandError.errorEnglishDescription)
}

# sendCommand COMMAND_DATA_JSON. At most one erase per run, and the request must
# be for exactly one device.
sentId=""
eraseSent="no"
sendCommand() {
	if [[ "$1" == *'"ERASE_DEVICE"'* ]]; then
		[[ "$eraseSent" == "no" ]] || fail "Refusing to send a second erase in one run."
		eraseSent="yes"
	fi
	# clientType COMPUTER is in Jamf's documented example for this endpoint
	echo "{\"clientData\":[{\"managementId\":\"$mgmtId\",\"clientType\":\"COMPUTER\"}],\"commandData\":$1}" > "$WORK_DIR/cmd.json"
	[[ "$(plutil -extract clientData raw "$WORK_DIR/cmd.json" 2>/dev/null || true)" == "1" ]] ||
		fail "The command doesn't target exactly one device. Nothing was sent."
	api POST "/api/v2/mdm/commands" -H "Content-Type: application/json" --data @"$WORK_DIR/cmd.json"
	# one entry per device: a second entry means more than one was queued
	[[ -z "$(value 1.id)" ]] || fail "Jamf reported more than one command for a single-device request. Check the command history in Jamf now and cancel any extras."
	# Jamf doesn't document what this id is, so trackSent has a fallback
	sentId=$(value 0.id)
	log "Command accepted by Jamf (HTTP $API_STATUS). Command id: ${sentId:-not returned}"
}

# trackSent: finds the Recovery Lock command we just sent. Sets cmdUuid, cmdState,
# cmdError and tracked. Never exits.
tracked="no"
trackSent() {
	tracked="no"
	if [[ "$sentId" =~ ^[0-9A-Fa-f-]{8,64}$ ]]; then
		apiTry GET "/api/v2/mdm/commands?filter=uuid==$sentId"
		[[ "$API_STATUS" =~ ^2 ]] || return 0
		if [[ "$(value results.0.uuid)" == "$sentId" ]]; then
			readCommand
			tracked="yes"
			return 0
		fi
	fi
	# Fallback: the newest Recovery Lock command for this Mac, accepted only if it is
	# the one new command since we started (the one below it is what we saw before).
	# Otherwise it could be someone else's, so nothing is guessed.
	apiTry GET "/api/v2/mdm/commands?filter=clientManagementId==$mgmtId;command==SET_RECOVERY_LOCK&sort=dateSent:desc&page-size=2"
	[[ "$API_STATUS" =~ ^2 ]] || return 0
	readCommand
	if [[ "$cmdUuid" != "$oldUuid" && "$(value results.1.uuid)" == "$oldUuid" ]]; then tracked="yes"; fi
}

rlConfirmed="no"
waited=0
cmdState=""
if [[ "$DO_LOCK" == "yes" ]]; then
	# remember the newest existing command so an old one is never mistaken for ours
	STEP="check the Recovery Lock status"
	api GET "/api/v2/mdm/commands?filter=clientManagementId==$mgmtId;command==SET_RECOVERY_LOCK&sort=dateSent:desc&page-size=1"
	readCommand
	oldUuid="$cmdUuid"

	log "Clearing Recovery Lock on $serial..."
	STEP="send the Clear Recovery Lock command"
	sendCommand '{"commandType":"SET_RECOVERY_LOCK","newPassword":""}'

	startProgress "**Clearing Recovery Lock**\n\n$details\n\nThe command has been sent. If the Mac is offline or asleep it stays **Pending** until the Mac connects.\n\n:${WARN}[Please wait. Keep this window open.] It shows **Done** when everything has finished." \
		"$(infoText sent "not started" 00:00)"

	# Wait (WAIT_SECONDS at most) for the Mac to acknowledge. An error stops before any
	# erase. No reply in time means a requested erase is sent anyway so Jamf queues it.
	lastShown=""
	pollErrors=0
	statusText="Queued in Jamf. Waiting for the Mac to connect."
	while :; do
		# no Cancel button, but if the window is closed anyway carry on without it
		if [[ -n "$PROGRESS_PID" ]] && ! progressAlive; then
			log "The progress window was closed. Continuing without it."
			PROGRESS_PID=""
		fi

		if ((waited % POLL == 0)); then
			trackSent
			if [[ "$API_STATUS" =~ ^2 ]]; then
				pollErrors=0
				if [[ "$tracked" == "yes" ]]; then
					if [[ "$cmdState" != "$lastShown" ]]; then
						log "Recovery Lock command state: ${cmdState:-unknown}"
						lastShown="$cmdState"
					fi
					case "$cmdState" in
						ACKNOWLEDGED) log "Recovery Lock cleared."; rlConfirmed="yes"; setStep "$STEP_LOCK" success "Cleared"; break ;;
						ERROR | COMMAND_FORMAT_ERROR) fail ":${WARN}[Clearing Recovery Lock failed] (status $cmdState${cmdError:+: $cmdError}).\n\n${NOT_ERASED_NOTE}" ;;
						NOT_NOW) statusText="The Mac is busy and will try again." ;;
						*) statusText="Queued in Jamf (${cmdState:-PENDING}). The Mac hasn't picked it up yet. It may be offline or asleep." ;;
					esac
				else
					statusText="Waiting for Jamf to list the command."
				fi
			else
				# a short Jamf or network problem shouldn't stop the wait
				pollErrors=$((pollErrors + 1))
				echo "Jamf check failed (HTTP $API_STATUS), attempt $pollErrors of 6." >&2
				statusText="Could not reach Jamf (HTTP $API_STATUS). Trying again."
				((pollErrors < 6)) || fail ":${WARN}[Lost contact with Jamf Pro] (HTTP $API_STATUS) while waiting for the Mac.\n\n${NOT_ERASED_NOTE}"
			fi
		fi

		if ((waited >= WAIT_SECONDS)); then
			# only a command that exists and is still waiting may be followed by a queued erase
			if [[ "$tracked" == "yes" && ( "$cmdState" == "PENDING" || "$cmdState" == "NOT_NOW" ) ]]; then
				setStep "$STEP_LOCK" pending "No reply - queued in Jamf"
				dlgCmd "activate:"
				log "WARNING: no reply after ${WAIT_SECONDS}s (state: $cmdState). The Mac may be offline. Queuing the erase behind it."
				break
			fi
			fail ":${WARN}[Recovery Lock was not confirmed] within ${waitText} (last status: ${lastShown:-not found in Jamf}).\n\n${NOT_ERASED_NOTE}If the Mac was offline, the Recovery Lock command may still be queued in Jamf. Check its command history, then run this tool again."
		fi

		dlgCmd "progress: $((waited * 100 / WAIT_SECONDS))"
		dlgCmd "progresstext: $statusText"
		infoLive "${cmdState:-PENDING}" "not started" "$(mmss "$waited")"
		sleep "$TICK"
		waited=$((waited + TICK))
	done
else
	# erase only: no Recovery Lock command, so nothing to wait for
	startProgress "**Erasing the Mac**\n\n$details\n\nThe erase command is being sent. If the Mac is offline or asleep Jamf queues it until the Mac connects.\n\n:${WARN}[Please wait. Keep this window open.] It shows **Done** when everything has finished." \
		"$(infoText "not requested" "not started" 00:00)"
fi

# --- Erase (only when requested) -------------------------------------------------
if [[ "$DO_ERASE" == "yes" ]]; then
	# Jamf wants a 6-digit PIN on ERASE_DEVICE ("PIN cannot be null" otherwise). Apple
	# Silicon ignores it, so it is random and never shown or logged. obliterationBehavior
	# is the fallback if Erase All Content and Settings can't run.
	erasePin=$(printf '%06d' $(($(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % 1000000)))
	STEP="send the erase command"
	if [[ "$DO_LOCK" == "no" ]]; then
		AFTER_FAIL_NOTE="The erase was NOT sent. Run this tool again to erase."
	elif [[ "$rlConfirmed" == "yes" ]]; then
		AFTER_FAIL_NOTE="Recovery Lock is already cleared, but the erase was NOT sent. Run this tool again to erase."
	else
		AFTER_FAIL_NOTE="The Recovery Lock clear is still queued in Jamf, but the erase was NOT queued. Cancel the pending command in Jamf, or run this tool again."
	fi
	dlgCmd "progress: 100"
	infoLive "${cmdState:-PENDING}" "sending" "$(mmss "$waited")"
	setStep "$STEP_ERASE" wait "Sending the command"
	if [[ "$DO_LOCK" == "no" ]]; then
		dlgCmd "progresstext: Sending the erase command..."
	elif [[ "$rlConfirmed" == "yes" ]]; then
		dlgCmd "progresstext: Recovery Lock cleared. Sending the erase command..."
	else
		dlgCmd "progresstext: No reply yet. Queuing the erase command..."
	fi
	log "Sending the erase command..."
	sendCommand '{"commandType":"ERASE_DEVICE","pin":"'"$erasePin"'","obliterationBehavior":"'"$OBLITERATION"'"}'
	AFTER_FAIL_NOTE=""
fi

# --- Result ------------------------------------------------------------------------
if [[ "$purpose" == "retire" ]]; then
	asmNote="**Reminder:** :${WARN}[remove this device from ${ASM}] before the erased Mac connects to the internet, if you haven't already."
else
	asmNote="This Mac is being **reimaged**, so it stays in ${ASM}."
fi
resultTable="| Detail | Value |\n|:--|:--|\n| **Serial** | $serial |\n| **Computer name** | $(mdv "$compName") |\n| **Username** | $(mdv "$username") |\n| **Model** | $(mdv "$model") |"
[[ "$DO_ERASE" == "no" ]] || resultTable+="\n| **Reason** | $reasonText |"

if [[ "$DO_ERASE" == "no" ]]; then
	# Recovery Lock only
	if [[ "$rlConfirmed" == "yes" ]]; then
		log "RESULT: $serial - Recovery Lock cleared. The Mac was not erased (not requested)."
		slackDone="yes"
		slackPost "#008000" ":white_check_mark:" "Recovery Lock cleared" "Cleared"
		dlgCmd "progress: 100"
		dlgCmd "infobox: ### Result<br><br>**Recovery Lock:** cleared"
		finishWindow "Done" info "**Recovery Lock was cleared.**\n\n$resultTable\n\nThe Mac was **not** erased.\n\nClick **Done** to close."
	else
		log "RESULT: $serial - no reply within ${WAIT_SECONDS}s. Recovery Lock clear is queued in Jamf. The Mac was not erased (not requested)."
		slackDone="yes"
		slackPost "#FFA500" ":warning:" "Mac did not reply - Recovery Lock clear queued in Jamf" "Queued in Jamf. Sent when the Mac connects."
		dlgCmd "progress: 100"
		dlgCmd "infobox: ### Result<br><br>**Recovery Lock:** :${WARN}[queued in Jamf]"
		finishWindow "Queued - the Mac did not reply" caution "The Mac did not reply within ${waitText} (it may be offline).\n\n$resultTable\n\nThe **Clear Recovery Lock** command is :${WARN}[queued in Jamf]. Jamf sends it when the Mac connects to the internet. The Mac is **not** being erased.\n\nClick **Done** to close."
	fi
elif [[ "$DO_LOCK" == "no" ]]; then
	# erase only
	log "RESULT: $serial - erase command sent (Recovery Lock not touched). Reason: $reasonText."
	slackDone="yes"
	slackPost "#008000" ":white_check_mark:" "Device Wipe Command sent" "Device Wipe command sent"
	setStep "$STEP_ERASE" success "Command sent"
	dlgCmd "infobox: ### Result<br><br>**Erase:** command sent"
	finishWindow "Done" info "**The erase command was sent.**\n\n$resultTable\n\nRecovery Lock was not touched. The Mac will erase and restart. This can take a while.\n\n$asmNote\n\nClick **Done** to close."
elif [[ "$rlConfirmed" == "yes" ]]; then
	log "RESULT: $serial - Recovery Lock cleared, erase command sent. Reason: $reasonText."
	slackDone="yes"
	slackPost "#008000" ":white_check_mark:" "Recovery Lock cleared, Device Wipe Command sent" "Recovery Lock cleared, Device Wipe command sent"
	setStep "$STEP_ERASE" success "Command sent"
	dlgCmd "infobox: ### Result<br><br>**Recovery Lock:** cleared<br><br>**Erase:** command sent"
	finishWindow "Done" info "**Recovery Lock was cleared and the erase command was sent.**\n\n$resultTable\n\nThe Mac will erase and restart. This can take a while.\n\n$asmNote\n\nClick **Done** to close."
else
	log "RESULT: $serial - no reply within ${WAIT_SECONDS}s. Recovery Lock and erase are queued in Jamf. Reason: $reasonText."
	slackDone="yes"
	slackPost "#FFA500" ":warning:" "Mac did not reply - Recovery Lock and erase queued in Jamf" "Both commands queued in Jamf. Sent when the Mac connects."
	setStep "$STEP_ERASE" success "Queued in Jamf"
	dlgCmd "infobox: ### Result<br><br>**Recovery Lock:** :${WARN}[queued in Jamf]<br><br>**Erase:** :${WARN}[queued in Jamf]"
	finishWindow "Queued - the Mac did not reply" caution "The Mac did not reply within ${waitText} (it may be offline).\n\n$resultTable\n\nThe **Clear Recovery Lock** and **Erase** commands are :${WARN}[queued in Jamf]. Jamf sends them when the Mac connects to the internet.\n\n$asmNote\n\nClick **Done** to close."
fi
