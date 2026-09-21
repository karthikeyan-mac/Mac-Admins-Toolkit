# Jamf Pro Delete All macOS Configuration Profiles

`delete-all-macos-config-profiles.sh` deletes **all** macOS configuration profiles in Jamf Pro.

It is a delete-all tool, not a list-driven one: it finds every profile and deletes it, except profiles on an optional **exclude list**. A real run saves a backup of each profile first.

`restore-macos-config-profiles.sh` creates profiles again from those backups (see [Restore](#restore)).

Script versions: delete `1.1.0`, restore `1.0.0` (see `SCRIPT_VERSION` in each script). Every run prints `script name - version` as its first line.

> **Disclaimer: this tool permanently deletes configuration profiles.** Deleting a profile in Jamf Pro also **removes it from every Mac in its scope** at the next check-in, along with whatever it enforced (restrictions, PPPC, FileVault, Wi-Fi, certificates, system extension approvals). Run the dry run first, review the list, and test in a non-production Jamf Pro before any production use. Provided as is, with no warranty; you are responsible for the result.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the script only calls `curl` and `plutil`.
- Jamf Pro with API Client (client-credentials) support.
- Runs from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

## Requirements

- `/bin/bash`, `curl`, `plutil` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials) with an API Role that has:
  - **Read macOS Configuration Profiles**
  - **Delete macOS Configuration Profiles**

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables, then script default):

| Variable | Purpose | Default |
|---|---|---|
| `EXCLUDE_LIST` | Optional text file of profile IDs or exact names to keep, one per line (`#` lines ignored) | empty (nothing excluded) |
| `BACKUP_DIR` | Where the pre-delete backup folder is created | `~/Library/Logs/jamf_delete_macos_config_profiles_backup` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_delete_macos_config_profiles.log` |
| `DRY_RUN` | `yes` reports only, `no` deletes | `yes` |
| `JAMF_DELETE_CONFIRM` | Must be `DELETE` for a non-interactive real run | not set |

`EXCLUDE_LIST`, `BACKUP_DIR` and `LOG_FILE` may be written the way Terminal writes a path: with `\ ` escapes, in quotes, with a leading `~`, or with a trailing space.

## Usage

```bash
export JAMF_ENV="dev"

# Dry run (default): lists the profiles and shows what would be deleted
./delete-all-macos-config-profiles.sh

# Real run
DRY_RUN=no ./delete-all-macos-config-profiles.sh
```

Anything not set (URL, client ID, client secret) is prompted for; the client ID and secret are entered with no echo.

A real run (dev or prod) prints the disclaimer first. Confirmations:

- **Prod:** type `PROD` first.
- **Interactive:** after listing the profiles, the script shows how many it found and asks you to type `DELETE`.
- **Non-interactive:** set `JAMF_DELETE_CONFIRM=DELETE` (and `JAMF_PROD_CONFIRM=PROD` for prod), or the script stops before authenticating.

## How it works

- Lists profiles with `GET /JSSResource/osxconfigurationprofiles` (Classic API). All profiles are listed before any delete starts.
- Keeps any profile whose ID or exact name is on the exclude list. Excluded profiles are never backed up or deleted, in a dry run or a real run.
- Before the first delete of a real run, saves every profile that is about to be deleted to `BACKUP_DIR/<timestamp>/<prod|dev>-<name>-<id>.xml` (`GET /JSSResource/osxconfigurationprofiles/id/{id}`). Every `<id>` element is removed from the saved XML, the same "trimmed" form Jamf Replicator writes, so the file can be posted back to Jamf Pro. In the file name, `/`, `:` and `\` in the profile name become `_` and the name is cut to 50 characters; the ID keeps names unique. A profile whose backup fails is **not** deleted and is reported as failed.
- Deletes each with `DELETE /JSSResource/osxconfigurationprofiles/id/{id}`. A profile that fails (for example HTTP 404 or 500) is reported and the run continues.
- The token is refreshed once if Jamf Pro rejects it (401). A 403 (missing privilege) stops the run.
- The access token is invalidated on exit, on success and on failure.

## Restore

`restore-macos-config-profiles.sh` creates macOS configuration profiles from backup files. It uses the same shared configuration, `JAMF_ENV`, prod `PROD` confirmation, URL guard and dry run as the delete script.

> **A restored profile is applied to its scope straight away.** A profile scoped to All Computers is deployed to every Mac. Run the dry run first and test in dev.

Extra API privilege: **Create macOS Configuration Profiles** (plus Read).

| Variable | Purpose | Default |
|---|---|---|
| `RESTORE_PATH` | A backup folder (its `*.xml` files) or one `.xml` file. Prompted for if not set | empty |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_restore_macos_config_profiles.log` |
| `DRY_RUN` | `yes` reports only, `no` creates | `yes` |
| `JAMF_RESTORE_CONFIRM` | Must be `RESTORE` for a non-interactive real run | not set |

```bash
export JAMF_ENV="dev"
export RESTORE_PATH="$HOME/Library/Logs/jamf_delete_macos_config_profiles_backup/<timestamp>"

# Dry run (default): shows what would be restored or skipped
./restore-macos-config-profiles.sh

# Real run
DRY_RUN=no ./restore-macos-config-profiles.sh
```

If `RESTORE_PATH` is not set, the script asks for it. The path may be pasted or typed the way Terminal writes it: with `\ ` escapes, in quotes, with a leading `~`, or with a trailing space.

Restoring groups as well? Restore the computer groups first (see [Jamf-Pro-Delete-All-Computer-Groups](../Jamf-Pro-Delete-All-Computer-Groups/)), because a profile's scope refers to them by name.

How it works:

- Only files named `<env>-...xml` for the selected environment are used. If any file belongs to the other environment the script stops before signing in, so a dev backup cannot go into prod.
- Removes any `<id>` element (a backup has none; a raw Replicator export does), then creates each profile with `POST /JSSResource/osxconfigurationprofiles/id/0`. A restored profile gets a new ID.
- Skips a profile whose name already exists in Jamf Pro, or that repeats an earlier file in the same run. Nothing existing is changed.
- A real run prints a disclaimer, then interactive runs ask you to type `RESTORE`; non-interactive runs need `JAMF_RESTORE_CONFIRM=RESTORE` (and `JAMF_PROD_CONFIRM=PROD` for prod).
- Continues after a failed profile and reports it. A 403 (missing privilege) stops the run. POST is never retried automatically, to avoid creating a profile twice.
- Scope is restored by name (a backup has no IDs). Groups or computers that no longer exist may make Jamf Pro reject the profile or leave its scope smaller, so recreate groups first and check each restored profile.

## Output

A summary is printed and appended to `LOG_FILE`: profiles found, kept (exclude list), deleted (or "would delete" in a dry run), failed with the reason, and the backup folder path on a real run. A dry run writes no files except the log. The exit code is non-zero if any profile failed or the run stopped early.

## Testing

```bash
bash -n ./delete-all-macos-config-profiles.sh ./restore-macos-config-profiles.sh
shellcheck ./delete-all-macos-config-profiles.sh ./restore-macos-config-profiles.sh
```

Both pass clean as of this revision. The logic was exercised only against a fake `curl` returning canned responses: dry run, real run, exclude list, backup files, HTTP 404 and 500 on delete, 403 on the list, an empty list, a malformed list, an invalid profile ID, and the non-interactive `DELETE` and `PROD` confirmations. Backups of three real Jamf Replicator raw exports were compared with Replicator's own trimmed files and are byte-for-byte identical; awkward profile names, a single-line response, and a response that is not a profile (that profile is not deleted) were also checked. It has **not** been run against a live Jamf Pro tenant. The interactive prompts, the 401 token refresh and a 403 during delete were not exercised. Test against a non-production tenant before any production use.

The restore script was exercised the same way (fake `curl`, macOS `/bin/bash` 3.2): dry run, real run, skip of an existing name and of a repeated name, a single-line file, a raw Replicator export, a file that is not a profile, HTTP 500 on create (run continues), 403 on create (run stops), the environment guard, the non-interactive `RESTORE` and `PROD` confirmations, and pasted paths with escapes, quotes and `~` (also for `EXCLUDE_LIST`, `BACKUP_DIR` and `LOG_FILE` in the delete script). The XML it sent was byte-for-byte identical to Replicator's trimmed files. It has **not** been run against a live Jamf Pro tenant, so whether Jamf Pro accepts the restored XML, and how it treats a scope that refers to missing groups, is unverified. The interactive `RESTORE` prompt and the 401 refresh were not exercised.

## Limitations

- Deleting a profile is permanent, and it removes the profile from every Mac in scope. Run the dry run first.
- The backup is the XML Jamf Pro returns with the `<id>` elements removed. The trimmed form matches what Replicator saves; restore it with `restore-macos-config-profiles.sh`, which has not been run against a live tenant. Because IDs are removed, scope entries are kept by name only. Profile backups can contain sensitive payload data (for example certificates or Wi-Fi settings), so keep them private. The script creates them readable by you only.
- Restoring a deleted profile does not bring back the ID it had.
- macOS configuration profiles only. iOS/iPadOS/tvOS (mobile device) profiles are not covered.
- Uses the Classic API, which is not paged. Exclusions match the exact ID or exact name (case-sensitive); there are no wildcards.

## References

- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken)
- [Jamf Pro Classic API: macOS configuration profiles](https://developer.jamf.com/jamf-pro/reference/osxconfigurationprofiles)
- [Create a macOS configuration profile by ID (Classic API)](https://developer.jamf.com/jamf-pro/reference/createosxconfigurationprofilebyid)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
