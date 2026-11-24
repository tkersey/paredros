# Installation and service configuration

The implementation remains under qualification. The steps below prepare a live
installation; the external-service scenario at the end has not been executed.
Use the [offline example](config.example.json) for local checks without credentials.

## Bindings and credentials

Copy [the live example](config.live.example.json) and replace every placeholder,
the numeric repository ID, UID, ref, paths, and model selection. The `account`
fields are stable local binding names. Use a GitHub credential authorized for
read-only repository contents and metadata on the selected repository. An account
label alone grants no remote capability: the two explicit `grants` select access.
The configuration schema is closed; an unknown field is refused.

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
old executable and namespace until the transfer import has materialized.

## Pending live qualification

With explicitly selected test resources, verify an activation message readable
with `messages`, a new branch commit producing one digest message, a question
answered with `question answer`, and duplicate ingress returning its original
admission. Record known/unknown model usage. Offline fixtures and successful
installation do not discharge this live operational gate.
