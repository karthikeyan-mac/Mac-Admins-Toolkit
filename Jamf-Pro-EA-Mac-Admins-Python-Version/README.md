# Jamf Pro EA: Mac Admins Python Version

`mac-admins-python-version-ea.sh` is a Jamf Pro Extension Attribute. It reports the version of Mac Admins Python, or `Not Installed`.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## Result values

| Result | Meaning |
|---|---|
| `3.15.1` (a version number) | Installed. The version from `managed_python3 --version` |
| `Not Installed` | `/usr/local/bin/managed_python3` is missing or cannot be run |
| `Unknown` | The launcher exists but did not report a version |

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe and macOS 27 Golden Gate (the toolkit's general targets).
- Requires Mac Admins Python to be installed. See [github.com/macadmins/python](https://github.com/macadmins/python).

## Requirements

- `/bin/bash` and `sed` (both included with macOS).
- Jamf Pro. No API client, credentials or policy parameters are needed.

## Jamf Pro setup

1. Jamf Pro > Settings > Computer Management > Extension Attributes > New.
2. Display name: `Mac Admins Python Version` (or your choice).
3. Data type: **String**. Input type: **Script**.
4. Paste the contents of `mac-admins-python-version-ea.sh` into the script box and save.
5. Run Inventory on a test Mac and check the value.

## Testing

```bash
bash -n ./mac-admins-python-version-ea.sh
shellcheck ./mac-admins-python-version-ea.sh
./mac-admins-python-version-ea.sh
```

Verified on one Mac with Mac Admins Python installed (output `3.15.1`), and with the launcher path changed to a missing file (`Not Installed`) and to a command that prints no version (`Unknown`). Not yet tested in a Jamf Pro tenant.

## Limitations

- Checks only the path `/usr/local/bin/managed_python3`. A Mac Admins Python install whose launcher is elsewhere reports `Not Installed`.
- Reports the version of the launcher, not of any other Python on the Mac.

## References

- [Jamf Pro extension attribute best practices](https://developer.jamf.com/jamf-pro/docs/extension-attribute-best-practices)
- [macadmins/python](https://github.com/macadmins/python)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
