# Set Computer Name

`set-computer-name.sh` sets the Mac's name to `<model>-<serial>` (for example `MacBookPro-XXXXXXXXXX`) or to the serial number only.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## Behaviour

- Sets ComputerName, LocalHostName and HostName with `scutil`.
- Reads the model name and serial number from `system_profiler`. Spaces are removed from the model name, and the name is limited to letters, digits and hyphens (63 characters at most).
- Does nothing when all three names already match.
- Does not update MDM inventory. Let the MDM do that (in Jamf Pro, enable Update Inventory in the policy).

## Usage

Run as root, or deploy with any MDM:

```bash
sudo /bin/bash ./set-computer-name.sh
```

## Name format

| `NAME_FORMAT` | Result |
|---|---|
| `model-serial` (default) | `MacBookPro-XXXXXXXXXX` |
| `serial` | `XXXXXXXXXX` |

Set `NAME_FORMAT` in the environment, or change `SCRIPT_NAME_FORMAT` in the script. Most MDMs can't set environment variables, so for MDM deployment edit `SCRIPT_NAME_FORMAT`.

```bash
sudo NAME_FORMAT=serial /bin/bash ./set-computer-name.sh
```

| Exit code | Meaning |
|---|---|
| `0` | Names set, or already correct |
| `1` | Not run as root, invalid `NAME_FORMAT`, model or serial not found, or a name could not be set |

## Compatibility

macOS 15 Sequoia, macOS 26 Tahoe and macOS 27 Golden Gate. Uses only tools included with macOS.

## Privacy

The name includes the serial number. Other devices can see it on the local network (Bonjour, AirDrop), and so can any network where the HostName is registered.

## Reference

- `man scutil`
- `man system_profiler`

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
