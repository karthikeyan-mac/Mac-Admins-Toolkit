# Mac Admin Toolkit

Practical **macOS administration scripts, MDM utilities, Jamf Pro tools, Extension Attributes, and automation** for Apple device management.

The toolkit includes both **MDM-agnostic tools** and platform-specific utilities where required.

> Independent project. Not affiliated with or endorsed by Apple, Jamf, Microsoft, Kandji, VMware, or any other vendor.

## macOS Support

Scripts should target **macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate**, unless a tool states otherwise. Individual tools should document any OS, architecture, or feature limitations.

## Clone

```bash
git clone https://github.com/karthikeyan-mac/Mac-Admins-Toolkit.git
cd Mac-Admins-Toolkit
```

## Use

Review the script documentation and comments before deployment, then run the required script directly or deploy it through your MDM platform.

For example:

```bash
bash path/to/script.sh
```

Scripts should document any required permissions, dependencies, parameters, MDM requirements, and expected output.

## Security

Never commit passwords, API tokens, client secrets, private keys, certificates containing private material, `.env` files with secrets, or sensitive organisation/device data.


## Disclaimer

The scripts and tools in this repository are provided **as-is**, without warranty of any kind.

Scripts may make system, configuration, security, or device-management changes. **Review and understand the code before running it.**

Always test scripts in a **non-production environment** and validate compatibility with your macOS version, MDM platform, security controls, and organisational requirements before production deployment.

Compatibility with listed macOS versions is a development target and should **not be considered a guarantee** that every script has been tested against every macOS release, hardware configuration, or MDM environment.

You are responsible for evaluating, testing, and validating these tools before use in your environment.

## License

MIT License. See [LICENSE](LICENSE).

## Author

**Karthikeyan Marappan**  
Apple Enterprise & Device Management
