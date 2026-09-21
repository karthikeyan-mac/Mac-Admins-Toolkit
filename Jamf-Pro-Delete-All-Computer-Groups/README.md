# Jamf Pro Delete Computer Groups

`delete-all-computer-groups.sh` deletes **all** smart and/or static computer groups in Jamf Pro.

It is a delete-all tool, not a list-driven one: it does not take a list of groups to delete. It finds every group of the chosen type and deletes it, except groups on an optional **exclude list**. A real run saves a backup of each group first.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

> **Disclaimer: this tool permanently deletes computer groups.** Deleted groups cannot be recovered by this script (see the backup below). Jamf Pro will not delete a group that is scoped to other objects such as policies or configuration profiles (see "Groups that are in use"). Run the dry run first, review the list, and test in a non-production Jamf Pro before any production use. Provided as is, with no warranty; you are responsible for the result.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the script only calls `curl` and `plutil`.
- Jamf Pro with API Client (client-credentials) support and the v3 `computer-groups` endpoints.
- Runs from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

## Requirements

- `/bin/bash`, `curl`, `plutil` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials) with an API Role that has:
  - **Read Smart Computer Groups** and **Delete Smart Computer Groups**
  - **Read Static Computer Groups** and **Delete Static Computer Groups**

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables, then script default):

| Variable | Purpose | Default |
|---|---|---|
| `GROUP_TYPE` | `smart`, `static` or `all` | `all` |
| `EXCLUDE_LIST` | Optional text file of group IDs or exact names to keep, one per line (`#` lines ignored) | empty (nothing excluded) |
| `BACKUP_DIR` | Where the pre-delete backup folder is created | `~/Library/Logs/jamf_delete_computer_groups_backup` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_delete_computer_groups.log` |
| `DRY_RUN` | `yes` reports only, `no` deletes | `yes` |
| `JAMF_DELETE_CONFIRM` | Must be `DELETE` for a non-interactive real run | not set |

## Usage

```bash
export JAMF_ENV="dev"
export GROUP_TYPE="all"

# Dry run (default): lists the groups and shows what would be deleted
./delete-all-computer-groups.sh

# Real run
DRY_RUN=no ./delete-all-computer-groups.sh
```

Anything not set (URL, client ID, client secret) is prompted for; the client ID and secret are entered with no echo.

A real run (dev or prod) prints the disclaimer first. Confirmations:

- **Prod:** type `PROD` first.
- **Interactive:** after listing the groups, the script shows how many it found and asks you to type `DELETE`.
- **Non-interactive:** set `JAMF_DELETE_CONFIRM=DELETE` (and `JAMF_PROD_CONFIRM=PROD` for prod), or the script stops before authenticating.

## How it works

- Keeps any group whose ID or exact name is on the exclude list. Excluded groups are never backed up or deleted, in a dry run or a real run.
- Lists groups with `GET /api/v3/computer-groups/smart-groups` and `/static-groups` (paged, 100 at a time). All groups are listed before any delete starts.
- Before the first delete of a real run, saves every group that is about to be deleted to `BACKUP_DIR/<timestamp>/`: one JSON file per group (`GET /api/v3/computer-groups/smart-groups/{id}` or `/static-groups/{id}`, so smart group criteria and static group members). A group whose backup fails is **not** deleted and is reported as failed.
- Deletes each with `DELETE /api/v3/computer-groups/smart-groups/{id}` or `/static-groups/{id}`.
- Jamf Pro refuses to delete a group that is in use (HTTP 422). That group is reported as failed and left in place, and the run continues. See below.
- The token is refreshed once if Jamf Pro rejects it (401). A 403 (missing privilege) stops the run.
- The access token is invalidated on exit, on success and on failure.

## Groups that are in use

A computer group cannot be deleted while it is scoped to other objects, such as policies or configuration profiles. Jamf Pro refuses the delete (HTTP 422, "group has dependencies"), so:

- The group stays in Jamf Pro and is reported as failed (`in use, HTTP 422`) in the log and summary. The run continues with the next group.
- The exit code is non-zero when any group could not be deleted.
- The **dry run cannot tell** which groups are in use. It only lists groups, so an in-use group still shows as "would delete". Expect the real run to leave some of them.
- A group's backup is saved before its delete is attempted, so an in-use group that is not deleted still has a backup in the folder.
- To delete an in-use group, remove it from the scope of every object that uses it first, then run the script again. To keep it, add it to the exclude list.

Which objects count as "using" a group is decided by Jamf Pro, not by this script.

## Output

A summary is printed and appended to `LOG_FILE`: groups found, groups kept (exclude list), groups deleted (or "would delete" in a dry run), groups that failed with the reason, and the backup folder path on a real run. A dry run writes no files except the log. The summary is printed even if the run stopped early. The exit code is non-zero if any group failed or the run stopped early.

## Testing

```bash
bash -n ./delete-all-computer-groups.sh
shellcheck ./delete-all-computer-groups.sh
```

Both pass clean as of this revision. The logic was exercised only against a fake `curl` returning canned responses (dry run, real run, paging, exclude list, backup and a failed backup, 422 in use, HTTP 500, 401 token refresh, group type selection, invalid input, the non-interactive prod and delete confirmations, and the interactive `DELETE` prompt). It has not been run against a live Jamf Pro tenant. The 403 stop and the URL mismatch guard were not exercised. Test against a non-production tenant before any production use.

## Limitations

- Deleting a group is permanent. Run the dry run first.
- The backup is the raw JSON Jamf Pro returns (smart group criteria, static group members). Jamf Pro has no import for it, so use it as a reference to rebuild groups by hand. The backup files contain computer names and criteria, so keep them private. The script creates them readable by you only.
- Restoring a deleted group does not bring back the ID it had. Scope, exclusions and reports that referenced the old group will need to be pointed at the new one.
- Computer groups only. Mobile device groups are not covered.
- Whether Jamf Pro lists or refuses to delete its built-in groups (for example All Managed Clients) has not been verified. If it lists them, expect them to be reported as failed.
- It deletes every group of the chosen type that is not on the exclude list. Exclusions match the exact ID or exact name (case-sensitive); there are no wildcards.

## References

- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken)
- [Search for Smart Computer Groups (v3)](https://developer.jamf.com/jamf-pro/reference/get_v3-computer-groups-smart-groups)
- [Search for Static Computer Groups (v3)](https://developer.jamf.com/jamf-pro/reference/get_v3-computer-groups-static-groups)
- [Remove specified Smart Computer Group (v3)](https://developer.jamf.com/jamf-pro/reference/delete_v3-computer-groups-smart-groups-id)
- [Remove Static Computer Group by Id (v3)](https://developer.jamf.com/jamf-pro/reference/delete_v3-computer-groups-static-groups-id)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
