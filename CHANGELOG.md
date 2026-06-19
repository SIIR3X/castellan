# Changelog

All notable changes to Castellan are documented here. The format follows
Keep a Changelog (https://keepachangelog.com), and the project aims to follow
Semantic Versioning (https://semver.org).

## [1.1.0] - Unreleased

### Added

- Six extra hardening measures, on by default with individual toggles, that lift
  the Lynis hardening index: disable core dumps (1.15), stronger password hashing
  cost in `login.defs` (1.16), verbose SSH logging and no TCPKeepAlive (2.21/2.22),
  patch-management visibility via apt-show-versions (6.9), and process/system
  accounting with acct + sysstat (11.11).

### Changed

- Castellan now applies **every** measure: hardening profiles
  (minimal / standard / paranoid) are gone. To skip a measure or role, set its
  toggle off per host (`enable_<role>: false`) or per run (`-e enable_<role>=false`
  / `--only`); `mfa` remains the only measure off by default.
- The `init` / `configure` wizard is now a plain terminal questionnaire with no
  `whiptail` (or other TUI) dependency; it collects host configuration only and
  no longer offers a per-measure selector.
- Live per-role hardening checklist during `audit` / `apply` (Castellan stdout
  callback plugin); set `CASTELLAN_RAW=1` for Ansible's default output.

### Fixed

- SSH listening port is now set via `sshd_config` rather than a manual
  `ssh.socket` drop-in, fixing the port change on Ubuntu 24.04 (socket
  generator).
- Re-running `audit` / `apply` against an already-hardened host no longer fails:
  a new preflight play (Play 0) detects that the initial account is locked out
  and connects as the existing admin instead. On a fresh host it still uses the
  initial credentials. The live dashboard no longer shows the tolerated identity
  probe as a `[FAIL]`.

### Removed

- `whiptail` recommendation from the `.deb` package metadata (the wizard no
  longer uses it).

## [1.0.0] - 2026-06-18

## [1.0.0] - 2026-06-18

First stable release. Agentless hardening of Ubuntu and Debian servers, driven
by Ansible from a control machine over SSH - nothing is installed on the target
beyond the Python 3 the distribution already ships.

### Added

- Three operations from a single CLI (`harden` from source, `castellan` once
  installed): read-only `audit` (`--check`), `apply`, and `rollback` of the
  latest backup, plus `init`, `configure`, `list` and `report`.
- 18 hardening categories aligned with CIS, ANSSI, DISA STIG and Lynis:
  accounts, SSH, firewall (ufw), fail2ban, updates, sysctl, PAM, audit logging,
  services, network, filesystem, cron, confinement, integrity, boot, MFA and
  compliance reporting.
- Anti-lockout design: the admin user and its key are deployed first, sudo and
  a fresh reconnection are verified before root and password auth are cut, the
  new SSH port is opened in the firewall before ufw is enabled, and sshd is
  reloaded once at the very end. Every modified file is backed up for rollback.
- Hardening profiles (minimal / standard / paranoid), per-measure selection,
  an interactive setup wizard, and multi-host inventories.
- Per-run timestamped backups with a MANIFEST, powering one-command rollback.
- Compliance reporting via Lynis (hardening index, fetched report, weekly
  timer).
- Plaintext, versionable YAML configuration with no secrets stored in clear:
  Ansible Vault for persistent secrets, the local ssh-agent for private keys,
  runtime prompt for the initial password.
- Packaging: apt-installable `.deb` and a signed apt repository, plus a release
  workflow that builds, verifies and publishes them.
- Quality gate (`make check`: ascii, syntax, ansible-lint at the production
  profile, shellcheck, actionlint, gitleaks) and a full end-to-end VM cycle
  (`make test`) validated on Ubuntu Server 24.04.
