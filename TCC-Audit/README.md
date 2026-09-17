# macOS TCC Service Audit

`tcc-audit.sh` performs a read-only audit of Transparency, Consent, and Control (TCC) privacy records on macOS 27 and later.

The script uses the macOS 27 `tccutil list` command to identify applications with records for selected TCC services. It then queries each service and application combination to report the current authorization state.

The script does not create, modify, reset, grant, or revoke TCC permissions.

## Compatibility

- macOS 27 or later

The script exits with an error on macOS 26 and earlier because those releases do not provide the required `tccutil list` functionality.

## Requirements

The script uses only tools included with macOS:

- `/bin/bash`
- `/usr/bin/sw_vers`
- `/usr/bin/tccutil`
- `/bin/date`

No third-party dependencies are required.

## Usage

Run the script with Bash from Terminal:

```bash
/bin/bash ./tcc-audit.sh
```

The script accepts no command-line arguments and makes no changes to the Mac.

## Execution context

Run the script in the user context whose TCC records need to be inspected. Results depend on the account and security context used to execute `tccutil`.

When deploying through an MDM or another management system, verify whether the tool runs as root or as the logged-in user and confirm that the resulting records match the intended audit scope.

## Audited services

The current service list includes:

- Accessibility
- Contacts, Calendars, and Reminders
- Apple Events
- Audio Capture, Camera, and Microphone
- Bluetooth
- Developer Tools
- File Provider domains
- Focus Status
- Input Monitoring and Post Events
- Media Library, Photos, and Add to Photos
- Motion
- Remote Desktop
- Screen Recording
- Siri and Speech Recognition
- Full Disk Access
- App Management and App Data
- Desktop, Documents, Downloads, network volumes, and removable volumes
- System administration and developer files
- Web browser public-key credentials
- Home data (`Willow`)

The list is intentionally limited to services accepted by `tccutil list` during macOS 27 testing. Apple may add, remove, or change service support in future releases.

## Output

The report is written to standard output and begins with the operating-system version, build number, and audit date.

For each service containing records, the script prints the application identifier and authorization state:

```text
----------------------------------------
Service: Camera
----------------------------------------
com.example.application                                          granted
com.example.denied-application                                   denied
```

Applications with both granted and denied records can appear in the service-level results. The script therefore performs a separate state query for every application identifier rather than assuming that every listed record is granted.

The final output contains:

- Services with no records
- Service and authorization-state query errors
- Number of services queried successfully
- Total number of TCC records found
- Service query error count
- Authorization-state error count

Example summary:

```text
============================================================
TCC Audit Summary
============================================================
Services queried successfully : 34/34
TCC records found             : 25
Service query errors          : 0
Authorization state errors    : 0
============================================================
```

## Exit codes

| Exit code | Meaning |
|---|---|
| `0` | The audit completed without query errors. |
| `1` | The operating system is unsupported, `tccutil` is unavailable, or no service could be queried successfully. |
| `2` | The audit completed partially, but one or more service or authorization-state queries failed. |

## Privacy and security

The report can contain application bundle identifiers and privacy authorization states. Treat the output as device inventory data and store or transmit it according to organizational security requirements.

The script does not require credentials and does not access or modify the TCC database directly.

## Testing

Check Bash syntax:

```bash
/bin/bash -n ./tcc-audit.sh
```

Functional testing should confirm:

- macOS 26 and earlier are rejected with exit code `1`.
- Services with records show an application identifier and state.
- Services without records appear in the appropriate section.
- Query failures include the service, exit code, and error text.
- A complete audit exits `0`.
- A partial audit exits `2`.

## Limitations

- The script audits only the fixed list of services included in the script.
- A TCC record may remain after an application has been removed.
- Results show recorded authorization state, not whether an application is currently installed or actively using the protected resource.
- Output and supported service names may change in future macOS releases.
- The script does not distinguish between user decisions, MDM-delivered policy, and other sources of authorization.
- The report is human-readable and is not intended as a stable machine-readable interface.

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
