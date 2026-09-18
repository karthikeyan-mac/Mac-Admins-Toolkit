# Jamf Pro Recovery Lock API

`RecoveryLockAPI.sh` sets or clears macOS Recovery Lock on an Apple Silicon Mac by sending the `SET_RECOVERY_LOCK` MDM command through the Jamf Pro API.

The script identifies the target Mac by its own serial number, obtains a Jamf Pro OAuth access token, looks up the computer's management ID, sends the Recovery Lock command, and invalidates the access token afterward — on both success and failure.

## Compatibility

- Apple Silicon Macs running macOS 11.5 or later. Recovery Lock is an Apple Silicon feature; Intel Macs do not support the `SET_RECOVERY_LOCK` MDM command.
- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets) are all supported for the client side of this script.
- Jamf Pro with API Client (client-credentials) OAuth support.

## Requirements

The script uses tools included with macOS:

- `/bin/bash`
- `curl`
- `plutil`
- `system_profiler`, `awk`, and other standard command-line utilities

No third-party packages are required.

### Jamf Pro API permission

Create an API Role containing only:

- **Send Set Recovery Lock Command**
- **View MDM Command Information**
- **Read Computers**
- **View Recovery Lock**

Assign the role to an enabled API Client and generate a client secret. The script obtains an OAuth access token and uses it with the Jamf Pro API.

Never commit a real client secret to this repository. Treat any committed or otherwise exposed secret as compromised and rotate it in Jamf Pro immediately.

## Configuration

Environment variables take precedence over the corresponding script-level values.

| Variable | Purpose | Default |
|---|---|---|
| `JAMF_URL` | Jamf Pro base URL, including `https://` | Script-level placeholder |
| `JAMF_CLIENT_ID` | Jamf Pro API Client ID | Script-level placeholder |
| `JAMF_CLIENT_SECRET` | Jamf Pro API Client secret | Script value, then interactive prompt |
| `LOCK_MODE` | `Set` or `Remove` | Script-level `SCRIPT_LOCK_MODE` |
| Jamf policy parameter `4` | `Set` or `Remove` (Jamf policy execution) | Overrides `LOCK_MODE` when present |

The script-level configuration is near the beginning of the script:

```bash
SCRIPT_JAMF_URL="https://karthikeyan.jamfcloud.com"
SCRIPT_JAMF_CLIENT_ID="your-api-client-id"
SCRIPT_JAMF_CLIENT_SECRET=""
SCRIPT_LOCK_MODE="Set"
```

`https://karthikeyan.jamfcloud.com` and `your-api-client-id` are placeholders and are deliberately rejected — the script exits with an error until you either replace them locally or provide `JAMF_URL` / `JAMF_CLIENT_ID` through the environment.

Keep `SCRIPT_JAMF_CLIENT_SECRET` empty in committed and shared copies. For unattended execution (including a Jamf policy), provide the secret through your deployment system's protected secret store — never as a Jamf policy script parameter, since those are visible in policy logs.

`lockMode` resolves in this order: Jamf policy parameter `4`, then `LOCK_MODE`, then `SCRIPT_LOCK_MODE`. The resolved value is validated as `Set` or `Remove` before any network call is made.

## Usage

Make the script executable if required:

```bash
chmod 700 ./RecoveryLockAPI.sh
```

### Interactive execution

Set the non-secret values and start the script. It prompts for the secret without echoing it:

```bash
export JAMF_URL="https://your-instance.jamfcloud.com"
export JAMF_CLIENT_ID="your-api-client-id"
export LOCK_MODE="Remove"

./RecoveryLockAPI.sh
```

### Supply the secret from Zsh

```zsh
read -r -s "JAMF_CLIENT_SECRET?Jamf API client secret: "
printf '\n'
export JAMF_CLIENT_SECRET

./RecoveryLockAPI.sh

unset JAMF_CLIENT_SECRET
```

### Supply the secret from Bash

```bash
read -r -s -p "Jamf API client secret: " JAMF_CLIENT_SECRET
printf '\n'
export JAMF_CLIENT_SECRET

./RecoveryLockAPI.sh

unset JAMF_CLIENT_SECRET
```

Do not put a real secret directly on a command line because it may be retained in shell history or exposed to process inspection.

### Jamf policy execution

Add the script to a Jamf policy and provide `Set` or `Remove` as **Parameter 4**. Provide `JAMF_URL`, `JAMF_CLIENT_ID`, and `JAMF_CLIENT_SECRET` to the policy's execution environment through a mechanism your organization already trusts for secrets (for example, a root-owned, permission-restricted file sourced by a wrapper script) — not as additional policy parameters.

## How it works

1. Validates `JAMF_URL`, `JAMF_CLIENT_ID`, and the resolved `lockMode` before making any network call.
2. Prompts for `JAMF_CLIENT_SECRET` on an interactive terminal if it was not exported; exits with an error for non-interactive runs with no secret.
3. Reads the local Mac's serial number with `system_profiler`.
4. When `lockMode` is `Set`, generates a 26-digit pseudo-random password locally using Bash's `$RANDOM`.
5. Requests an OAuth access token, sending the client secret to `curl` via a permission-restricted temporary file (`client_secret@file`) rather than a command-line argument.
6. Looks up the computer's Jamf Pro management ID by serial number.
7. Sends the `SET_RECOVERY_LOCK` MDM command with the generated password (`Set`) or an empty password (`Remove`).
8. Invalidates the access token from an `EXIT` trap, so invalidation is attempted on both success and failure, and removes its temporary working directory.

## Output

On success, the script prints:

```text
Recovery Lock Set command sent for C02XXXXXXXXX
Token successfully invalidated
```

The script does not print, log, or store the generated Recovery Lock password. Retrieve the current Recovery Lock password afterward from Jamf Pro (the **View Recovery Lock** permission granted to the API Role) rather than from this script's output.

## Exit behavior

- Exit `0`: the Recovery Lock command was accepted by Jamf Pro (HTTP 2xx).
- Exit `1`: configuration, authentication, API, or validation failure — including an invalid `lockMode`, a missing/placeholder `JAMF_URL` or `JAMF_CLIENT_ID`, an empty `JAMF_CLIENT_SECRET`, a failed serial-number lookup, a failed management-ID lookup, or a non-2xx Jamf Pro API response.

Token invalidation failures are reported as warnings on standard error and do not change the script's exit status, since by that point the requested Recovery Lock action has already been determined.

## Testing

Check Bash syntax and run ShellCheck:

```bash
bash -n ./RecoveryLockAPI.sh
shellcheck ./RecoveryLockAPI.sh
```

Both checks pass clean as of this revision.

For functional testing, use a non-production Jamf Pro tenant and a non-production Apple Silicon Mac enrolled in it. This script has not been run against a live Jamf Pro tenant as part of preparing this revision — validate `Set` and `Remove` end to end, including MDM command completion in Jamf Pro, before any production use.

## Limitations

- Apple Silicon only; the `SET_RECOVERY_LOCK` MDM command is not supported on Intel Macs.
- The 26-digit password is generated with Bash's `$RANDOM`, which is not a cryptographically secure source of randomness.
- The script sends the MDM command and confirms it was accepted; it does not poll for or confirm on-device completion of the command.
- `getManagementId` matches on exact serial number via a Jamf Pro Advanced computer search filter; a serial number not yet present in Jamf Pro inventory (e.g. immediately after enrollment) will fail the lookup.

## References

- [Recovery Lock Enablement in macOS Using the Jamf Pro API](https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html)
- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Jamf Pro API — MDM commands](https://developer.jamf.com/jamf-pro/reference/post_v2-mdm-commands)
- [Apple Platform Deployment — Recovery Lock](https://support.apple.com/guide/deployment/use-recovery-lock-on-a-mac-dep24dbdcf9e/web)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
