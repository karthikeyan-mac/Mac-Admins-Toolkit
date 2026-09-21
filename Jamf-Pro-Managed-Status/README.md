# Jamf Pro Managed Status

`update-managed-status-by-serial.sh` sets the **managed** status of computers in Jamf Pro, one serial number per line from a text file.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the script only calls `curl` and `plutil`.
- Jamf Pro with API Client (client-credentials) support and the v4 `computers-inventory` endpoints.
- Runs from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

## Requirements

- `/bin/bash`, `curl`, `plutil` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials) with an API Role that has:
  - **Read Computers**
  - **Update Computers**

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables, then script default):

| Variable | Purpose | Default |
|---|---|---|
| `MANAGED_VALUE` | `true` = managed, `false` = unmanaged | empty (prompted) |
| `SERIAL_LIST` | Path to the serial number text file (one per line, `#` lines ignored) | `~/Desktop/serialNumber.txt` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_managed_status.log` |
| `DRY_RUN` | `yes` reports only, `no` applies the change | `yes` |

## Usage

```bash
export JAMF_ENV="dev"
export MANAGED_VALUE="false"
export SERIAL_LIST="$HOME/Desktop/serialNumber.txt"

# Dry run (default): shows what would change
./update-managed-status-by-serial.sh

# Real run
DRY_RUN=no ./update-managed-status-by-serial.sh
```

Anything not set (URL, client ID, client secret, `MANAGED_VALUE`) is prompted for; the client ID and secret are entered with no echo.

## How it works

- Looks up each serial number with `GET /api/v4/computers-inventory` and reads its current managed status.
- Sets it with `PATCH /api/v4/computers-inventory-detail/{id}` and the body `{"general":{"managed":true|false}}`.
- Computers already in the requested state are skipped.
- A serial number that matches no record, or more than one record, is reported as failed and not changed.
- The token is refreshed once if Jamf Pro rejects it (401) partway through a long list. A 403 (missing privilege) stops the run.
- The access token is invalidated on exit, on success and on failure.

## Output

A summary is printed and appended to `LOG_FILE`: computers changed (or "would change" in a dry run), computers already in the requested state, and serial numbers that failed or were not found. The summary is printed even if the run stopped early. The exit code is non-zero if any serial number failed or the run stopped early.

## Testing

```bash
bash -n ./update-managed-status-by-serial.sh
shellcheck ./update-managed-status-by-serial.sh
```

Both pass clean as of this revision. The logic was exercised only against a fake `curl` returning canned responses (dry run, real run, already-correct, not found, duplicate serial, HTTP 500, 401 token refresh, 403 stop, input validation, non-interactive prod guard). It has not been run against a live Jamf Pro tenant, and the URL mismatch guard was not exercised. Test against a non-production tenant before any production use.

## Limitations

- Computers only. Mobile devices are not supported.
- Serial numbers must be letters and digits only, and match exactly one computer record.
- A serial number not yet in Jamf Pro inventory (for example right after enrollment) is reported as "Not found".
- This changes the Jamf Pro record's managed flag. Run the dry run first and check the serial list, especially when setting `false`.

## References

- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken)
- [Return paginated Computer Inventory records (v4)](https://developer.jamf.com/jamf-pro/reference/get_v4-computers-inventory)
- [Update specified Computer record (v4)](https://developer.jamf.com/jamf-pro/reference/patch_v4-computers-inventory-detail-id)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
