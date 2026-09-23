# Check Dock Status

`check-dock-status.sh` waits until the Dock is running, then runs the commands you add at the end of the script. Use it to launch an app or run a script only after a user has logged in.

Script version: `1.0.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## Behaviour

- Checks for the Dock every 5 seconds and waits with no time limit.
- Any user's Dock ends the wait.
- Waits 5 more seconds after the Dock appears, then runs your commands.

## Usage

Add your commands at the end of the script, then run it or deploy it with any MDM:

```bash
/bin/bash ./check-dock-status.sh
```

Commands run as whoever runs the script, usually root when deployed through an MDM. To run a command as the logged-in user, use `launchctl asuser` (see the comment in the script).

## Compatibility

macOS 15 Sequoia, macOS 26 Tahoe and macOS 27 Golden Gate. Uses only tools included with macOS.

## Reference

- `man pgrep`
- `man launchctl` (`asuser`)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
