# Jamf macOS Profile Deprecation Audit

`jamf-macos-profile-deprecation-audit.sh` audits Jamf Pro macOS configuration profiles for settings that Apple has deprecated or removed in macOS 27.

The script is read-only. It retrieves configuration profiles from Jamf Pro, examines their embedded property lists, prints a summary, and writes detailed findings to a CSV report. It does not modify profiles, scope, devices, or Jamf Pro settings.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate
- Jamf Pro 10.49 or later for API Client client-credentials authentication

The macOS 27 rule set is static and versioned independently from the script. Review Apple's documentation again before relying on the results for a final macOS 27 production rollout.

## Requirements

The script uses tools included with macOS:

- `/bin/bash`
- `curl`
- `xmllint`
- `awk`, `sed`, and other standard command-line utilities

No third-party packages are required.

### Jamf Pro API permission

Create an API Role containing only:

- **Read – Computer Configuration Profiles**

Assign the role to an enabled API Client and generate a client secret. The script obtains an OAuth access token and uses it with the Jamf Pro Classic API configuration-profile endpoints.

Never commit a real client secret to this repository. Treat any committed or otherwise exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables):

| Variable | Purpose | Default |
|---|---|---|
| `OUTPUT_DIR` | Directory for the CSV report | Current working directory |
| `DEBUG` | Set to `1` to print failed Jamf response bodies | `0` |

The script is read-only, so it has no `DRY_RUN`. Selecting `prod` still shows the warning and asks for `PROD`.

## Usage

Run it from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

```bash
chmod 700 ./jamf-macos-profile-deprecation-audit.sh

export JAMF_ENV="dev"
export OUTPUT_DIR="$(pwd)"

./jamf-macos-profile-deprecation-audit.sh
```

Anything not set (URL, client ID, client secret) is prompted for; the client ID and secret are entered with no echo. Do not put a real secret directly on a command line because it may be retained in shell history or exposed to process inspection. The access token is invalidated when the script exits.

## Audit rules

The current rule set detects:

| Category | macOS 27 status | Suggested replacement |
|---|---|---|
| PPPC Accessibility grant | Grant removed | DDM `com.apple.configuration.app.settings` with the `Privacy` key |
| PPPC Accessibility non-grant rule | Deprecated | DDM `com.apple.configuration.app.settings` with the `Privacy` key |
| `com.apple.SoftwareUpdate` payload | Removed | DDM `com.apple.configuration.softwareupdate.settings` |
| Legacy software-update deferral restrictions | Removed | DDM `com.apple.configuration.softwareupdate.settings` |
| `com.apple.dnsSettings.managed` | Deprecated | DDM `com.apple.configuration.network.dns-settings` |
| `com.apple.AssetCache.managed` | Deprecated | DDM `com.apple.configuration.content-cache.settings` |
| `com.apple.applicationaccess.new` | Deprecated | DDM `com.apple.configuration.app.settings` |

The software-update deferral check includes generic, major OS, minor OS, and non-OS/app deferral keys.

## Output

The first line is `script name - version`, followed by the environment and where each setting came from (never the values), then the Jamf Pro tenant being audited:

```text
jamf-macos-profile-deprecation-audit.sh - 2.0.0
Environment: dev (from JAMF_ENV variable). Settings sources (...):
  JAMF_URL=plist, JAMF_CLIENT_ID=plist, JAMF_CLIENT_SECRET=plist
Jamf Pro URL: https://your-instance.jamfcloud.com
```

Progress is then written to standard error while profiles are checked. At completion, the script prints a summary similar to:

```text
============================================================
Jamf macOS 27 Configuration Profile Audit Summary
============================================================
Profiles scanned:      42
Profiles affected:     8
Total findings:        12

Findings by category:
  Content Caching payload                      1
  PPPC Accessibility                           5
  Software Update deferral restriction         6

Findings by status:
  Deprecated in macOS 27                       3
  Grant removed in macOS 27                    4
  Removed in macOS 27                          5

CSV report:            /path/jamf-deprecated-mdm-audit.csv
Script version:        2.0.0
Rule set:              macOS-27.2026-09-17
============================================================
```

The detailed report is written to:

```text
jamf-deprecated-mdm-audit.csv
```

CSV columns:

| Column | Description |
|---|---|
| `category` | Detected deprecated or removed setting category |
| `status` | macOS 27 status assigned by the rule set |
| `replacement` | Recommended declarative management replacement |
| `profile_id` | Jamf Pro configuration-profile ID |
| `profile_url` | Direct link to the profile in the Jamf Pro web interface |
| `profile_name` | Jamf Pro profile name |
| `profile_uuid` | Jamf Pro profile UUID, when returned |
| `payload_uuid` | Matching PPPC payload UUID, when applicable |

The CSV is created with mode `600`. It is assembled in a temporary file and moved into place only after a successful audit. If an API or validation error occurs, an existing complete report is preserved.

## Testing

Check Bash syntax:

```bash
bash -n ./jamf-macos-profile-deprecation-audit.sh
```

For functional testing, use a non-production Jamf Pro tenant containing representative profiles, including:

- PPPC Accessibility with `Allow`
- PPPC Accessibility with `Deny`
- A legacy Software Update payload
- Major, minor, and app software-update deferrals
- Encrypted DNS
- Content Caching
- App allow/deny restrictions

Verify that Accessibility grants and non-grant rules receive different statuses, PPPC payload UUIDs are populated, and each `profile_url` opens the expected Jamf Pro profile.

## Exit behavior

- Exit `0`: the audit completed and the CSV was written successfully.
- Exit `1`: configuration, authentication, API, XML, plist, or output validation failed.
- Exit `0` with "Cancelled": you did not type `PROD` at the production prompt, so nothing ran.

A successful audit with zero findings still exits `0` and produces a header-only CSV.

## Limitations

- This is a static rule set, not a deprecation status returned by Jamf Pro.
- Apple does not publish a supported machine-readable catalog covering every MDM deprecation.
- The script audits macOS configuration profiles only. It does not audit Jamf policies, scripts, restricted software, PreStage settings, software-update plans, or existing DDM declarations.
- A finding shows that a matching payload or key exists; migration still requires administrative review and testing.
- Direct `profile_url` links depend on Jamf Pro retaining the `/OSXConfigurationProfiles.html?id=<id>` interface path.
- No changes are made automatically.

## References

- [Apple Device Management documentation](https://developer.apple.com/documentation/devicemanagement)
- [Apple removed commands and profiles](https://developer.apple.com/documentation/devicemanagement/removed-commands-and-profiles)
- [Apple PPPC services](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary)
- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Jamf Pro Classic API configuration profiles](https://developer.jamf.com/jamf-pro/reference/osxconfigurationprofiles)
- [Jamf Pro deprecations and removals](https://learn.jamf.com/r/en-US/jamf-pro-release-notes-current/Deprecations_and_Removals)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
