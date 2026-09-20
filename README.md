# Mac Admins Toolkit

A collection of practical **macOS administration scripts, MDM utilities, Jamf Pro tools, Extension Attributes, and automation** for Apple device management.

The repository includes both **MDM-agnostic scripts** and tools designed for specific management platforms such as Jamf Pro.

---

## Requirements

Requirements vary by script or tool.

Scripts are developed with the following macOS versions in mind:

- macOS 27
- macOS 26
- macOS 15

Check the documentation and comments included with each script for specific requirements, dependencies, permissions, and MDM requirements.

---

## Disclaimer

Some scripts in this repository may have been developed or refined with the assistance of AI tools.

**Review and understand every script before running it. Always test thoroughly in a non-production environment before deploying to production devices.**

Compatibility with the macOS versions listed above is a development target and does not mean every script has been tested against every macOS version, Mac model, architecture, MDM platform, or configuration.

Use these tools at your own risk and validate them against your organisation's requirements and security policies.

---

## Installation

Clone the repository:

```bash
git clone https://github.com/karthikeyan-mac/Mac-Admins-Toolkit.git
cd Mac-Admins-Toolkit
```

Browse to the required tool or script and review its documentation before use.

---

## Tools

| Tool | Purpose | Runs |
|---|---|---|
| [Jamf-Pro-ScopeMap-API-Role](Jamf-Pro-ScopeMap-API-Role/) | Creates the read-only Jamf Pro API Role that ScopeMap needs | Admin Mac |
| [Jamf-Pro-Delete-Devices](Jamf-Pro-Delete-Devices/) | Deletes computer or mobile device records by serial number | Admin Mac |
| [JAMF-macOS-Profile-Deprecation-Audit](JAMF-macOS-Profile-Deprecation-Audit/) | Read-only audit of configuration profiles for macOS 27 deprecations | Admin Mac |
| [Jamf-Pro-Recovery-Lock-API](Jamf-Pro-Recovery-Lock-API/) | Sets or clears Recovery Lock through the Jamf Pro API | Managed Mac, Jamf policy |
| [Jamf-Pro-Slack-Notifications](Jamf-Pro-Slack-Notifications/) | Sends a Slack message from a Jamf policy | Managed Mac, Jamf policy |
| [TCC-Audit](TCC-Audit/) | Read-only audit of TCC privacy records | Mac |

---

## Jamf Pro API tools: shared configuration

Applies to the Jamf Pro API tools above. Those marked **Admin Mac** run from a terminal, not from a Jamf policy, and do not use Jamf policy parameters. `Jamf-Pro-Recovery-Lock-API` runs from a Jamf policy and uses the same plist and keys, with unattended differences described in its README (environment as policy parameter 5, no typed `PROD`). `Jamf-Pro-Slack-Notifications` has its own configuration.

**Where values come from**, highest priority first:

1. Environment variable
2. Script default (the `SCRIPT_*` variables at the top of the script)
3. Optional plist `com.karthikmac.macadminstoolkit`
4. A prompt for anything still missing. Client ID, client secret and passwords are entered with no echo, so nothing is shown when pasted. Non-interactive runs stop with an error instead.

**Environment.** Choose `prod` or `dev` with `JAMF_ENV`, then the `SCRIPT_JAMF_ENV` value in the script, then a prompt. It is never chosen silently.

**Production guard.** Choosing `prod` shows a clear warning (server, account, what will happen) and requires typing `PROD` to continue, even for read-only tools. A non-interactive prod run that changes things also needs `JAMF_PROD_CONFIRM=PROD`.

**URL guard.** The script stops before authenticating if the URL is the other environment's URL in the plist, or differs from the selected environment's URL in the plist.

**Safe by default.** Tools that change Jamf Pro start with `DRY_RUN=yes` (report only). Set `DRY_RUN=no` for a real run. `DRY_RUN` is only read from the environment, never from the plist.

**Output.** Line 1 is `script name - version`. Lines 2-3 show the environment and where each setting came from (`environment`, `script default`, `plist` or `not set`), never the values.

### Optional plist

Created by a Jamf admin on the admin Mac (`~/Library/Preferences/com.karthikmac.macadminstoolkit.plist`). The selected environment decides which keys are read:

| Environment variable | Dev key | Prod key |
|---|---|---|
| `JAMF_URL` | `DevServerURL` | `ProdServerURL` |
| `JAMF_CLIENT_ID` | `DevAPIClientID` | `ProdAPIClientID` |
| `JAMF_CLIENT_SECRET` | `DevAPIClientSecret` | `ProdAPIClientSecret` |
| `JAMF_USER` (tools that use an admin account) | `DevAdminUsername` | `ProdAdminUsername` |
| `JAMF_PASS` (tools that use an admin account) | `DevAdminPassword` | `ProdAdminPassword` |

```bash
defaults write com.karthikmac.macadminstoolkit DevServerURL -string "https://dev.jamfcloud.com"
defaults write com.karthikmac.macadminstoolkit DevAPIClientID -string "your-api-client-id"
chmod 600 ~/Library/Preferences/com.karthikmac.macadminstoolkit.plist
```

**The plist is plain text.** Use it on admin Macs only and keep it `chmod 600` (the tools warn if it is more open). Never commit it. Consider leaving the `Prod` secrets out so prod always prompts. A tool's own settings are listed in that tool's README.

---

## Usage

Scripts may be used directly on macOS or deployed through an MDM platform, depending on their purpose.

Before using a script:

1. Read the script and its documentation.
2. Check any required variables, parameters, permissions, or dependencies.
3. Test on a non-production Mac.
4. Validate the expected result.
5. Deploy to production only after successful testing.

---

## Security

Never add credentials, passwords, API tokens, client secrets, private keys, certificates, or organisation-specific sensitive information directly to scripts.

**Always review your changes before committing or pushing to a remote Git repository to ensure credentials or sensitive information have not been included accidentally.**

If a credential is accidentally committed or pushed, consider it exposed and rotate or revoke it immediately.

---

## Issues

Found a bug or something that doesn't work as expected?

Please open an issue with details about the script, macOS version, MDM platform (if applicable), and the behaviour you observed.

---

## License

MIT — see `LICENSE`.

---


[Karthikeyan Marappan](https://www.linkedin.com/in/bewithkarthi/)
