# Installation and service configuration

The implementation remains under qualification. The steps below prepare a live
installation; the external-service scenario at the end has not been executed.
Use the [offline example](config.example.json) for local checks without credentials.

## Slack installation

Create a dedicated internal Slack app from
[the supplied manifest](../packaging/slack-manifest.json). It enables Socket Mode,
interactive buttons, a writable Messages tab, and `message.im` events. Its bot
scopes are `chat:write` and `im:history`. These settings follow Slack's
[manifest reference](https://docs.slack.dev/reference/app-manifest/) and
[Messages tab guidance](https://docs.slack.dev/surfaces/app-home/).

Install the app in the selected workspace and retain its bot token. Separately
create an app-level token with `connections:write` in Basic Information. Socket
Mode uses that token to open its WebSocket; it does not require a public request
URL. See [Slack's Socket Mode setup](https://docs.slack.dev/tools/python-slack-sdk/socket-mode/).
PAREDROS does not implement OAuth token rotation; refresh protected token files
and restart under the same configured account when needed.

Record the app, workspace, operator, bot, and owner-DM channel IDs from the actual
installation. The DM channel starts with `D`; the bot ID is distinct from its user
ID. Configure the owner explicitly. Keep other Socket Mode consumers disconnected
from this dedicated app because Slack can distribute events across its connections.
Only top-level owner text and supported buttons in the bound DM receive authority.

Audits retrieve metadata using `conversations.history` with
`include_all_metadata=true`. They do not subscribe to metadata Events API events.
Validate that this installation returns the complete activation marker before
relying on reconciliation. See Slack's
[metadata retrieval contract](https://docs.slack.dev/messaging/message-metadata/).

## Bindings and credentials

Copy [the live example](config.live.example.json) and replace every placeholder,
the numeric repository ID, UID, ref, paths, and model selection. The `account`
fields are stable local binding names. Use a GitHub credential authorized for
read-only repository contents and metadata on the selected repository. An account
label alone grants no remote capability: the four explicit `grants` select access.

Install the selected `siwc` executable and prepare its model account under the
service UID. Set its exact account, supported model slug and effort, and protected
authentication directory. Startup checks that the selected account is ready.
For an intentional no-model configuration, set `grants.model` to false and remove
`model`; conversation then reports that model access is unavailable.

Each token file must be a regular file owned by the service UID, with no group or
other permissions, containing only the token bytes. Trailing newlines and other
whitespace are rejected. The application refuses symlink token files. Keep the
secrets directory private. Configuration stores paths rather than credential
contents; do not put tokens in command arguments, task input, or the repository.

## Linux service

Build for `x86_64-linux-musl` using the README's pinned setup, then install the
binary at `/usr/local/bin/paredros` for the example service. Create the `paredros`
system account and set `current_uid` to its numeric UID. Install configuration at
`/etc/paredros/config.json`, readable by that account. Create the backup directory
with mode `0700` and the same owner.

Install [the systemd unit](../packaging/systemd/paredros.service), reload systemd,
and start the service when the bindings and intended live access are ready. The
unit creates private state and runtime directories. Run CLI commands as the
service UID; local clients authenticate the socket owner and peer UID. Inspect
`journalctl -u paredros` for startup errors and `paredros status` for task state.

`MissingCredentialReference`, `UnsafeCredentialFile`, and `InvalidConfiguration`
require fixing the referenced configuration or file. `ModelAccountNotReady`
requires checking the selected helper account. An incompatible namespace requires
the original build and a continuity export, as described in the README. Keep the
old executable and namespace until the transfer and recovery hold are resolved.

## Pending live qualification

With explicitly selected test resources, verify a confirmed activation notice
and metadata readback, a new branch commit producing one confirmed digest, a
bound button confirmation, duplicate ingress returning its original admission,
and a deliberately lost send response resolved by audit without resending.
Record observed acknowledgment latency and known/unknown model usage. Offline
fixtures and successful installation do not discharge this live operational gate.
