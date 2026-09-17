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
