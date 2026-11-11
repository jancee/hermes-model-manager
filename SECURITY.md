# Security

English | [简体中文](SECURITY.zh-CN.md)

Hermes Model Studio runs with the permissions of your macOS account. It is a local configuration editor, not an isolation boundary against other applications running as the same user.

## Credentials and data

API keys are saved to the selected endpoint's `key_env` variable in the local Hermes `.env` file. The interface shows key presence, not existing values. New keys pass to the local adapter through standard input rather than process arguments.

Backups may contain credentials. Backup files are created with mode `0600`; keep them private. Do not upload real `.env` files, configurations, preference files, backups, or screenshots containing private endpoints to the public repository.

The app reads the local Hermes model catalog and can fetch the selected endpoint's model list. Discovery refuses redirects and does not issue inference requests. The application does not collect telemetry.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository if that option is available. Otherwise, open an issue requesting a private contact channel without disclosing exploit details or secrets.

Provide the affected version, impact, and a reproduction using synthetic data. Do not test against accounts, services, or endpoints you do not control or have permission to test.

## Limits

Revision checks and atomic replacement reduce accidental overwrites. An external editor that ignores locking can still race with a write. Avoid editing the same files simultaneously.

Local builds use ad-hoc signing and are not notarized installers. The app relies on a local Python interpreter; maintain and update that interpreter separately.
