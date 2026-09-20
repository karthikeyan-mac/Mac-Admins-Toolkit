# Jamf Pro Delete Devices

`delete-devices-by-serial.sh` deletes computer or mobile device records from Jamf Pro, one serial number per line from a text file.

Script version: `2.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## What changed in 2.0.0

- **`DRY_RUN` defaults to `yes`.** The script reports what it would delete and deletes nothing. Set `DRY_RUN=no` to delete.
- **An environment is required:** `prod` or `dev` (`JAMF_ENV`, or a prompt). Prod shows a warning and asks you to type `PROD`.
- Values can come from a prompt or the shared plist. The old script-level URL placeholder is gone.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the script only calls `curl`/`plutil`, so no OS-specific behavior is expected.
- Jamf Pro with API Client (client-credentials) OAuth support and the `/v4/computers-inventory` endpoints.
- Runs from a terminal on an admin Mac. It is not a Jamf policy script and does not use policy parameters.

## Requirements

- `/bin/bash`, `curl`, `plutil` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials)

### Jamf Pro API permission

Create an API Role with:

- **Read Computers**
- **Delete Computers**
- **Read Mobile Devices**
- **Delete Mobile Devices**

One role covering both device types, since `DEVICE_TYPE` can be switched without regenerating the API Client. The read privileges are also what the dry run uses.

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration). This tool uses the API Client keys (`ServerURL`, `APIClientID`, `APIClientSecret`, each with a `Dev` or `Prod` prefix).

Tool settings (environment variables, then script default):

| Variable | Purpose | Default |
|---|---|---|
| `DEVICE_TYPE` | `computer` or `mobile` | `computer` |
| `SERIAL_LIST` | Path to the serial number text file (one per line) | `~/Desktop/serialNumber.txt` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_delete_devices.log` |
| `DRY_RUN` | `yes` reports only, `no` deletes | `yes` |

## Usage

```bash
export JAMF_ENV="dev"
export DEVICE_TYPE="mobile"
export SERIAL_LIST="$HOME/Desktop/serialNumber.txt"

# Dry run (default): shows what would be deleted
./delete-devices-by-serial.sh

# Real run
DRY_RUN=no ./delete-devices-by-serial.sh
```

Anything not set (URL, client ID, client secret) is prompted for; the client ID and secret are entered with no echo.

## How it works

- **`computer`**: looks up the Jamf Pro ID via `GET /api/v4/computers-inventory` filtered by serial number, then deletes with `DELETE /api/v4/computers-inventory/{id}` (the modern Jamf Pro API; the Classic API's serial-number delete was deprecated by Jamf on 2025-02-11, and the v1-v3 `computers-inventory` GET endpoints are deprecated as well, so v4 is used throughout).
- **`mobile`**: deletes with `DELETE /JSSResource/mobiledevices/serialnumber/{serial}` (Classic API). Jamf Pro has no modern, non-Classic delete endpoint for mobile devices as of this writing. The dry run checks existence with `GET` on the same Classic path.
- The access token is invalidated from an `EXIT` trap on both success and failure.

## Output

A summary is always printed and appended to `LOG_FILE` (and stdout) at the end of the run: counts and lists of successfully and unsuccessfully processed serial numbers. In a dry run the counts read "Would delete" and nothing is deleted. The summary is printed even if the run stopped early (e.g. an unauthorized API role or an unexpected error partway through the list), and then includes a "Run stopped early. Reason: ..." line.

## Testing

```bash
bash -n ./delete-devices-by-serial.sh
shellcheck ./delete-devices-by-serial.sh
```

Both pass clean as of this revision. Test against a non-production Jamf Pro tenant before any production use. This revision was exercised only against a local mock of the Jamf Pro API, not a live tenant.

## Limitations

- Deletion is permanent. Run the dry run first, and check the serial list.
- `computer` lookups match on exact serial number; a serial not yet present in Jamf Pro inventory (e.g. immediately after enrollment) is reported as "Not found."
- `mobile` deletion depends on the Jamf Pro Classic API, since no modern replacement endpoint exists yet.
- `curl --retry` only retries connection-level failures and a small set of 5xx/429 responses before a response is received; it never re-sends a request that already got a definitive result.

## References

- [Jamf Pro client credentials](https://developer.jamf.com/jamf-pro/docs/client-credentials)
- [Obtain an access token using an API Client](https://developer.jamf.com/jamf-pro/reference/postoauthtoken)
- [Return paginated Computer Inventory records (v4)](https://developer.jamf.com/jamf-pro/reference/get_v4-computers-inventory)
- [Remove specified Computer record (v4)](https://developer.jamf.com/jamf-pro/reference/delete_v4-computers-inventory-id)
- [Deletes a mobile device by serial number (Classic API)](https://developer.jamf.com/jamf-pro/reference/deletemobiledevicebyserialnumber)
- [Deprecation of Classic API Computer Inventory Endpoints](https://developer.jamf.com/jamf-pro/docs/deprecation-of-classic-api-computer-inventory-endpoints)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
