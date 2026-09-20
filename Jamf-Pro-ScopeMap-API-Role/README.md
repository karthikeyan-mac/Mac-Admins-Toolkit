# Jamf Pro ScopeMap API Role

`create-jamfscopemap-api-role.sh` creates (or updates) the read-only Jamf Pro API Role that [ScopeMap](https://github.com/Jamf-Concepts/scope-map) needs, and can optionally create an API Client bound to that role.

Script version: `1.1.0` (see `SCRIPT_VERSION` in the script). Every run prints `script name - version` as its first line.

## What changed in 1.1.0

- With `CREATE_CLIENT=yes` the API Client is now named the same as the role, and `CLIENT_NAME` is gone.
- No duplicate clients: if a client with that name, or any client already assigned the role, exists, no new one is created.

## Compatibility

- macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 Golden Gate (the toolkit's general targets). The script only calls `curl` and `jq`, so no OS-specific behavior is expected.

## Requirements

- `/bin/bash`, `curl`, `jq` (all included with macOS 15 and later)
- Run it from a terminal on an admin Mac. It is not written as a Jamf policy script and does not use Jamf policy parameters.
- A Jamf Pro **user account** (not an API Client) with the **Administrator** privilege set. Jamf Pro only lets you assign API privileges you already hold, so an Administrator account is the simplest way to create the role.

## Usage

```bash
export JAMF_URL="https://yourorg.jamfcloud.com"
export JAMF_USER="admin-account"

# Choose the environment: prod or dev (JAMF_ENV, or SCRIPT_JAMF_ENV in the script, or a prompt)
export JAMF_ENV="dev"

# Dry run (default): authenticates, validates privilege names, prints the payload, changes nothing
./create-jamfscopemap-api-role.sh

# Real run
DRY_RUN=no ./create-jamfscopemap-api-role.sh

# Real run, also create an API Client and print its secret once
DRY_RUN=no CREATE_CLIENT=yes ./create-jamfscopemap-api-role.sh
```

Environment selection (`JAMF_ENV`), the value order, the prod `PROD` confirmation, the URL guard, the optional plist and the output lines are shared by the Jamf Pro API tools. See [Jamf Pro API tools: shared configuration](../README.md#jamf-pro-api-tools-shared-configuration).

## Tool settings

| Environment variable | Plist key | Purpose | Script default |
|---|---|---|---|
| `JAMF_USER` | `DevAdminUsername` / `ProdAdminUsername` | Administrator account | none |
| `JAMF_PASS` | `DevAdminPassword` / `ProdAdminPassword` | Administrator password | none |
| `JAMF_CLIENT_ID` / `JAMF_CLIENT_SECRET` | `Dev`/`Prod` `APIClientID` / `APIClientSecret` | Fallback API Client, used if no username is given; must already hold every privilege being assigned | none |
| `ROLE_NAME` | `ScopeMapRoleName` | API Role name | `ScopeMap Read-Only_DEV` |
| `CREATE_CLIENT` | `ScopeMapCreateClient` | `yes` also creates an API Client, named the same as the role | `yes` |
| `DRY_RUN` | (not read) | `yes` changes nothing | `yes` |

The script default wins over the plist, so the `ScopeMap` plist keys only take effect if you blank that default in the script. A real run needs `DRY_RUN=no`.

## Limitations

- Blueprints and Compliance use Jamf Platform scopes and can't be set through an API Role.
- With `CREATE_CLIENT=yes` the API Client gets the same name as the role. If a client with that name, or any client already assigned this role, exists, no new one is created. The secret of a client that already exists can't be shown again; delete it in Jamf Pro first if you need a new one. The secret of a new client is printed once and not stored.
- Privilege names are checked against your server before any change; if Jamf renames one, the run stops and lists it.

## Testing

```bash
bash -n ./create-jamfscopemap-api-role.sh
shellcheck ./create-jamfscopemap-api-role.sh
```

Test against a non-production Jamf Pro tenant before production use.

## References

- [Jamf Pro API Roles and Clients](https://learn.jamf.com/en-US/bundle/jamf-pro-documentation-current/page/API_Roles_and_Clients.html)
- [Jamf Pro API reference](https://developer.jamf.com/jamf-pro/reference/jamf-pro-api)
- [ScopeMap](https://github.com/Jamf-Concepts/scope-map)

<p align="center">
  <a href="https://www.linkedin.com/in/bewithkarthi/">Karthikeyan Marappan</a>
</p>
