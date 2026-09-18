# Jamf Pro Delete Devices

`delete-devices-by-serial.sh` deletes computer or mobile device records from Jamf Pro, one serial number per line from a text file.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run logs the script version on its first line.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets); the script only calls `curl`/`plutil`, so no OS-specific behavior is expected.
- Jamf Pro with API Client (client-credentials) OAuth support and the `/v4/computers-inventory` endpoints.

## Requirements

- `/bin/bash`, `curl`, `plutil` (all included with macOS)
- A Jamf Pro API Client (OAuth client credentials)

### Jamf Pro API permission

Create an API Role with:

- **Read Computers**
- **Delete Computers**
- **Read Mobile Devices**
- **Delete Mobile Devices**

One role covering both device types, since `DEVICE_TYPE` can be switched without regenerating the API Client.

Never commit a real client secret to this repository. Treat any exposed secret as compromised and rotate it in Jamf Pro.

## Configuration

Environment variables override the script-level defaults:

| Variable | Purpose | Default |
|---|---|---|
| `JAMF_URL` | Jamf Pro base URL, including `https://` | Script-level placeholder |
| `JAMF_CLIENT_ID` | Jamf Pro API Client ID | Script-level placeholder |
| `JAMF_CLIENT_SECRET` | Jamf Pro API Client secret | Script value, then interactive prompt |
| `DEVICE_TYPE` | `computer` or `mobile` | `mobile` |
| `SERIAL_LIST` | Path to the serial number text file (one per line) | `~/Desktop/serialNumber.txt` |
| `LOG_FILE` | Path to the run log | `~/Library/Logs/jamf_delete_devices.log` |

`https://karthikeyan.jamfcloud.com` and `your-api-client-id` are placeholders and are deliberately rejected — replace them locally or provide `JAMF_URL` / `JAMF_CLIENT_ID` through the environment.

## Usage

```bash
export JAMF_URL="https://your-instance.jamfcloud.com"
export JAMF_CLIENT_ID="your-api-client-id"
export DEVICE_TYPE="mobile"
export SERIAL_LIST="$HOME/Desktop/serialNumber.txt"

./delete-devices-by-serial.sh
```

The script prompts for `JAMF_CLIENT_SECRET` without echoing it if not already exported, and refuses to run non-interactively without one.

## How it works

- **`computer`**: looks up the Jamf Pro ID via `GET /api/v4/computers-inventory` filtered by serial number, then deletes with `DELETE /api/v4/computers-inventory/{id}` (the modern Jamf Pro API; the Classic API's serial-number delete was deprecated by Jamf on 2025-02-11, and the v1-v3 `computers-inventory` GET endpoints are deprecated as well, so v4 is used throughout).
- **`mobile`**: deletes with `DELETE /JSSResource/mobiledevices/serialnumber/{serial}` (Classic API). Jamf Pro has no modern, non-Classic delete endpoint for mobile devices as of this writing.
- The access token is invalidated from an `EXIT` trap on both success and failure.

## Output

A summary is always printed and appended to `LOG_FILE` (and stdout) at the end of the run — counts and lists of successfully and unsuccessfully deleted serial numbers — even if the run stopped early (e.g. an unauthorized API role or an unexpected error partway through the list). In that case the summary also includes a "Run stopped early. Reason: ..." line.

## Testing

```bash
bash -n ./delete-devices-by-serial.sh
shellcheck ./delete-devices-by-serial.sh
```

Both pass clean as of this revision. Test against a non-production Jamf Pro tenant before any production use — this script has not been run against a live Jamf Pro tenant as part of preparing this revision.

## Limitations

- Deletion is permanent; there is no confirmation prompt or dry-run mode.
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
