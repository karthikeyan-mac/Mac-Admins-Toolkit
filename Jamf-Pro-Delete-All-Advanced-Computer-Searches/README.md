# Jamf Pro Delete All Advanced Computer Searches

`delete-all-advanced-computer-searches.sh` deletes **all** advanced computer searches in Jamf Pro.

It is a delete-all tool, not a list-driven one: it finds every search and deletes it, except searches on an optional **exclude list**. A real run saves a backup of each search first.

`restore-advanced-computer-searches.sh` creates searches again from those backups (see [Restore](#restore)).

Script versions: delete `1.0.0`, restore `1.0.0` (see `SCRIPT_VERSION` in each script). Every run prints `script name - version` as its first line.

> **Disclaimer: this tool permanently deletes advanced computer searches.** No Mac is changed, but each search (its criteria and display fields) is removed from Jamf Pro. Run the dry run first, review the list, and test in a non-production Jamf Pro before any production use. Provided as is, with no warranty; you are responsible for the result.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the scripts only call `curl`, `plutil` and `perl`.
- Jamf Pro with API Client (client-credentials) support.
- Runs from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

## Requirements

- `/bin/bash`, `curl`, `plutil`, `perl` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials) with an API Role that has:
  - **Read Advanced Computer Searches**
  - **Delete Advanced Computer Searches**
  - **Create Advanced Computer Searches** (restore only)

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables, then script default):

| Variable | Purpose | Default |
|---|---|---|
| `EXCLUDE_LIST` | Optional text file of search IDs or exact names to keep, one per line (`#` lines ignored) | empty (nothing excluded) |
| `BACKUP_DIR` | Where the pre-delete backup folder is created | `~/Library/Logs/jamf_delete_advanced_computer_searches_backup` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_delete_advanced_computer_searches.log` |
| `DRY_RUN` | `yes` reports only, `no` deletes | `yes` |
| `JAMF_DELETE_CONFIRM` | Must be `DELETE` for a non-interactive real run | not set |

## Usage

```bash
export JAMF_ENV="dev"

# Dry run (default): lists the searches and shows what would be deleted
./delete-all-advanced-computer-searches.sh

# Real run
DRY_RUN=no ./delete-all-advanced-computer-searches.sh
```

Anything not set (URL, client ID, client secret) is prompted for; the client ID and secret are entered with no echo.

A real run (dev or prod) prints the disclaimer first. Confirmations:

- **Prod:** type `PROD` first.
- **Interactive:** after listing the searches, the script shows how many it found and asks you to type `DELETE`.
- **Non-interactive:** set `JAMF_DELETE_CONFIRM=DELETE` (and `JAMF_PROD_CONFIRM=PROD` for prod), or the script stops before authenticating.

## How it works

- Lists searches with `GET /JSSResource/advancedcomputersearches` (Classic API, not paged). All searches are listed before any delete starts.
- Keeps any search whose ID or exact name is on the exclude list. Excluded searches are never backed up or deleted.
- Before the first delete of a real run, saves each search to `BACKUP_DIR/<timestamp>/<prod|dev>-<name>-<id>.xml` (`GET /JSSResource/advancedcomputersearches/id/{id}`). Every `<id>` element is removed, so the file can be posted back to Jamf Pro. The `<computers>` block (the search's current results) is left out, so no device data is saved. A search whose backup fails is **not** deleted and is reported as failed.
- Deletes each with `DELETE /JSSResource/advancedcomputersearches/id/{id}`. A search that fails is reported and the run continues. A 403 (missing privilege) stops the run.
- The token is refreshed once if Jamf Pro rejects it (401), and is invalidated on exit.

## Restore

`restore-advanced-computer-searches.sh` creates searches from backup files. It uses the same shared configuration, `JAMF_ENV`, prod `PROD` confirmation, URL guard and dry run as the delete script.

| Variable | Purpose | Default |
|---|---|---|
| `RESTORE_PATH` | A backup folder (its `*.xml` files) or one `.xml` file. Prompted for if not set | empty |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_restore_advanced_computer_searches.log` |
| `DRY_RUN` | `yes` reports only, `no` creates | `yes` |
| `JAMF_RESTORE_CONFIRM` | Must be `RESTORE` for a non-interactive real run | not set |

```bash
export JAMF_ENV="dev"
export RESTORE_PATH="$HOME/Library/Logs/jamf_delete_advanced_computer_searches_backup/<timestamp>"

# Dry run (default)
./restore-advanced-computer-searches.sh

# Real run
DRY_RUN=no ./restore-advanced-computer-searches.sh
```

- Only files named `<env>-...xml` for the selected environment are used; otherwise it stops before signing in.
- Creates each search with `POST /JSSResource/advancedcomputersearches/id/0`. The restored search gets a new ID.
- Skips a search whose name already exists. Nothing existing is changed. POST is never retried, to avoid creating a search twice.
- Criteria that use a group, site or Extension Attribute that no longer exists may be rejected by Jamf Pro. Recreate those first (groups: [Jamf-Pro-Delete-All-Computer-Groups](../Jamf-Pro-Delete-All-Computer-Groups/)).

## Output

A summary is printed and appended to `LOG_FILE`: searches found, kept, deleted (or "would delete" in a dry run), failed with the reason, and the backup folder on a real run. The exit code is non-zero if any search failed or the run stopped early.

## Testing

Jamf API documentation check (2026-09-21): the Classic API `advancedcomputersearches` endpoints used here (list, get by ID, create, delete by ID) are documented and not marked deprecated. No modern Jamf Pro API equivalent for advanced computer searches was found (the modern API has advanced mobile device and user content searches only). `POST /v1/oauth/token` and `POST /v1/auth/invalidate-token` are documented and not deprecated. Re-check when the script changes.

`bash -n` and `shellcheck` pass on both scripts. The backup XML clean-up (remove `<computers>` and every `<id>`, on one-line and multi-line XML) and the environment and URL guards were checked locally. The scripts have **not** been run against a live Jamf Pro tenant: the API calls, the backup and restore round trip, and whether Jamf Pro accepts the restored XML are unverified. Test against a non-production tenant first.

## Limitations

- Deleting a search is permanent. Run the dry run first.
- A backup holds the search definition only, not its results.
- Restoring does not bring back the original ID.
- Advanced **computer** searches only. Mobile device searches are not covered.
- Exclusions match the exact ID or exact name (case-sensitive); there are no wildcards.

## References

- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken)
- [Jamf Pro Classic API: advanced computer searches](https://developer.jamf.com/jamf-pro/reference/advancedcomputersearches)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
