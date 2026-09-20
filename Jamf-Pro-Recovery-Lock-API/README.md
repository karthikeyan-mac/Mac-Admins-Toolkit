# Jamf Pro Recovery Lock API

`RecoveryLockAPI.sh` sets or clears macOS Recovery Lock on an Apple Silicon Mac by sending the `SET_RECOVERY_LOCK` MDM command through the Jamf Pro API.

Script version: `2.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

**Upgrading:** an environment (`prod` or `dev`) is now required. Add it as policy **Parameter 5** (or `JAMF_ENV`), or existing policies will stop with an error. The script-level URL and client ID placeholders are gone.

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

The value order, the optional plist, the URL guard and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix). Because it runs unattended from a policy, it differs in a few ways:

| Setting | Policy parameter | Environment variable | Notes |
|---|---|---|---|
| Lock mode | `4` | `LOCK_MODE` | `Set` or `Remove`. Script default `Set`. Not read from the plist. |
| Environment | `5` | `JAMF_ENV` | `prod` or `dev`. Script default `SCRIPT_JAMF_ENV`. Never chosen silently: with none chosen, the script stops. |
| Jamf URL | | `JAMF_URL` | Or plist `DevServerURL` / `ProdServerURL`. |
| Client ID | | `JAMF_CLIENT_ID` | Or plist `DevAPIClientID` / `ProdAPIClientID`. |
| Client secret | | `JAMF_CLIENT_SECRET` | Or plist `DevAPIClientSecret` / `ProdAPIClientSecret`. Never a policy parameter (parameters appear in policy logs). |

Order for each value: policy parameter (where one exists), then environment variable, then script default, then the plist, then a prompt (terminal runs only; from a policy, a missing value stops the script).

**Production.** Selecting `prod` prints a warning. On a terminal you must type `PROD`; from a policy the warning is written to the policy log and the run continues, since nobody can be asked.

**The plist is plain text.** If it holds the client secret, every Mac that has it can expose the secret to anyone who can read the file. Keep it root-owned and mode `600` (the script warns if it is more open); it is read from `/Library/Preferences/com.karthikmac.macadminstoolkit.plist` or the running user's Preferences folder. Prefer leaving the `Prod` secret out and injecting it another way.

## Usage

Make the script executable if required:

```bash
chmod 700 ./RecoveryLockAPI.sh
```

### Interactive execution

Set the non-secret values and start the script. Anything missing, including the secret, is prompted for (the secret with no echo):

```bash
export JAMF_ENV="dev"
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

Add the script to a Jamf policy and set:

- **Parameter 4**: `Set` or `Remove`
- **Parameter 5**: `prod` or `dev`

Provide the Jamf URL, client ID and client secret from the plist (see above) or the policy's execution environment through a mechanism your organization already trusts for secrets (for example a root-owned, permission-restricted file sourced by a wrapper script). Do not pass them as additional policy parameters.

## How it works

1. Resolves the environment and each setting, validates the URL, client ID, client secret and the resolved `lockMode`, and applies the URL and production checks before making any network call.
2. Prompts for anything missing on an interactive terminal; exits with an error for a non-interactive (policy) run with a value missing.
3. Reads the local Mac's serial number with `system_profiler`.
4. When `lockMode` is `Set`, generates a 26-digit pseudo-random password locally using Bash's `$RANDOM`.
5. Requests an OAuth access token, sending the client secret to `curl` via a permission-restricted temporary file (`client_secret@file`) rather than a command-line argument.
6. Looks up the computer's Jamf Pro management ID by serial number.
7. Sends the `SET_RECOVERY_LOCK` MDM command with the generated password (`Set`) or an empty password (`Remove`).
8. Invalidates the access token from an `EXIT` trap, so invalidation is attempted on both success and failure, and removes its temporary working directory.

## Output

On success, the script prints:

```text
RecoveryLockAPI.sh - 2.0.0
Environment: dev (from Jamf policy parameter 5). Settings sources (...):
  JAMF_URL=plist, JAMF_CLIENT_ID=plist, JAMF_CLIENT_SECRET=plist, lockMode=policy parameter 4
Recovery Lock Set command sent for C02XXXXXXXXX
Token successfully invalidated
```

The script does not print, log, or store the generated Recovery Lock password. Retrieve the current Recovery Lock password afterward from Jamf Pro (the **View Recovery Lock** permission granted to the API Role) rather than from this script's output.

## Exit behavior

- Exit `0`: the Recovery Lock command was accepted by Jamf Pro (HTTP 2xx).
- Exit `1`: configuration, authentication, API, or validation failure — including an invalid `lockMode`, a missing `JAMF_ENV`, `JAMF_URL`, `JAMF_CLIENT_ID` or `JAMF_CLIENT_SECRET`, a URL that does not match the selected environment, a failed serial-number lookup, a failed management-ID lookup, or a non-2xx Jamf Pro API response.

Token invalidation failures are reported as warnings on standard error and do not change the script's exit status, since by that point the requested Recovery Lock action has already been determined.

## Testing

Check Bash syntax and run ShellCheck:

```bash
bash -n ./RecoveryLockAPI.sh
shellcheck ./RecoveryLockAPI.sh
```

Both checks pass clean as of this revision.

This revision was exercised only against a local mock of the Jamf Pro API, not a live tenant, and not on a Mac managed by a Jamf policy. For functional testing, use a non-production Jamf Pro tenant and a non-production Apple Silicon Mac enrolled in it. This script has not been run against a live Jamf Pro tenant as part of preparing this revision — validate `Set` and `Remove` end to end, including MDM command completion in Jamf Pro, before any production use.

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
