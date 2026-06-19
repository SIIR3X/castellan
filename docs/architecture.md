# Architecture

How Castellan is built: the project layout, the split into roles, the
anti-lockout execution flow, the audit/apply duality and the two install layouts.

Companion documents: [install.md](./install.md) (set up the control machine),
[config.md](./config.md) (what the user provides),
[security-measures.md](./security-measures.md) (the hardening catalogue).

## 1. Guiding principles

| Principle | Architectural consequence |
|-----------|---------------------------|
| Agentless | Nothing is installed on the target. Everything runs over SSH from the control machine, using the Python 3 already present on the host. |
| Audit before apply | Two modes from one codebase: audit (read-only, `--check`) reports deviations; apply remediates. An audit is always possible first. |
| Anti-lockout | A strict play and role order, plus a reconnection check, guarantee access is never cut before the new access is proven. |
| Idempotence | Running the playbook once or fifty times yields the same state, safely. |
| Reversibility | Every modified file is backed up with a timestamp, and a rollback command restores it. |
| Modularity | One security category equals one role; all run by default, each can be skipped independently with `enable_<role>=false`. |
| Variable connection | The first contact supports root + password, root + key, or an existing sudo user, per host. |

## 2. Project layout

```
castellan/
  harden                       CLI wrapper: init/audit/apply/rollback/report
  ansible.cfg                  Ansible config (accept-new host keys, pipelining, yaml callback)
  Makefile                     Quality gate (make check) and live cycle (make test)

  inventory/
    hosts.yml                  Static "vps" group (optional; init uses a dynamic inventory)
    castellan-inventory.sh     Dynamic inventory: lists hosts that have a config file
    group_vars/all.yml         Global defaults, enable_<role> toggles, measure defaults
    host_vars.example.yml      Per-host template copied by "harden init"
    host_vars/<host>.yml       Per-host config (plaintext, no secrets)

  playbooks/
    site.yml                   Imports the plays in anti-lockout order
    00-preflight.yml           Play 0: detect the working SSH identity
    00-bootstrap.yml           Play 1: create the admin user and deploy its key
    01-verify-access.yml       Play 2: reconnect as the admin, assert sudo
    10-harden.yml              Play 3: apply the roles in lockout-safe order
    99-report.yml              Play 4: Lynis scan and fetch the report
    50-rollback.yml            Standalone: restore files from a backup run

  roles/                       One role per category (see section 7)
  lib/castellan-config.sh      Terminal init/configure wizard (host config only)
  callback_plugins/castellan.py  Live per-role hardening checklist (stdout)
  files/public_keys/           Public keys to deploy
  reports/                     Generated reports (timestamped per host)
  packaging/                   .deb build and signed apt repository scripts
  test/                        Disposable test targets and the end-to-end cycle
  docs/                        This documentation
```

Anatomy of a role (identical across every role, which is what makes the set
consistent and maintainable):

```
roles/<name>/
  defaults/main.yml      Target values and options
  tasks/main.yml         Dispatch on castellan_mode -> audit.yml or apply.yml
  tasks/audit.yml        Read-only checks; report deviations
  tasks/apply.yml        Remediation; call backup_config first, then change
  handlers/main.yml      For example reload sshd, flushed at the end of the play
  templates/*.j2         Config files rendered onto the target
  meta/main.yml          Dependencies (usually none)
```

## 3. Execution flow (anti-lockout orchestration)

`site.yml` chains the plays below. The sequencing is the heart of the safety
design.

```
Play 0  PREFLIGHT        connection: read-only probe
  - Probe whether the admin is already reachable (host previously hardened)
  - Choose the connection identity for the run: the initial credentials on a
    fresh host, or the existing admin when re-running an already-hardened host
    (where the initial account is now locked out). Never changes anything.

Play 1  BOOTSTRAP        connection: INITIAL credentials (or admin on a re-run)
  - Back up the files that later plays will modify (backup_config)
  - Create the admin user, its group and sudoers drop-in
  - Deploy the admin SSH public key
  - Does NOT touch sshd yet

Play 2  VERIFY ACCESS    connection: NEW admin + key
  - Reconnect as the new admin and assert sudo works
  - Failure: stop here, root access is still intact (no lockout)
  - In audit mode the host ends gracefully instead of aborting

Play 3  HARDEN           connection: NEW admin + sudo
  - firewall   open the SSH port BEFORE enabling ufw
  - fail2ban   ignoreip set so you cannot self-ban
  - ssh        no root, no password, modern crypto, port via sshd_config
  - then sysctl, pam, audit_logging, services, network, filesystem, cron,
    updates, and the opt-in roles (confinement, integrity, boot, mfa)
  - flush handlers: reload sshd ONCE, at the very end

Play 4  REPORT
  - Run Lynis, read the hardening index, render the report
  - Fetch it into reports/<host>_<timestamp>/
```

Why this order:

- Firewall before SSH: the new port must be open before sshd starts using it.
- Fail2ban before SSH: `ignoreip` is in place before any ban could reach you.
- SSH reload last: triggered by a handler flushed at the very end, never mid-run.
- Play 2 is the safety net: if the new access does not work, nothing destructive
  has happened yet, so root and password access remain usable.

## 4. Audit versus apply

One codebase, two behaviours, driven by the `castellan_mode` variable that the
wrapper sets.

| Aspect | audit | apply |
|--------|-------|-------|
| Command | `castellan audit <host>` | `castellan apply <host>` |
| Under the hood | `ansible-playbook ... --check --diff`, `castellan_mode=audit` | real run, `castellan_mode=apply` |
| Effect on the host | None (read-only) | Modifies the configuration |
| Output | Per-measure deviations (ok / FAIL) | Applied changes and a diff |
| Role path | each role's `tasks/audit.yml` | `tasks/apply.yml` (backup, then change) |

Audit messages map to the identifiers in
[security-measures.md](./security-measures.md), for example `2.1 ok` or
`1.6 FAIL: <accounts>`. A run reports zero FAIL on a fully hardened host.

## 5. Centralized configuration

Global defaults, the per-role toggles and every measure default live in
`inventory/group_vars/all.yml`. Per-host files in `inventory/host_vars/<host>.yml`
override them, and any value can be overridden for a single run with `-e`.

There are **no profiles**: Castellan applies every measure. Each role runs by
default; flip a toggle off only to deliberately skip one.

| Block | Key variables |
|-------|---------------|
| Run mode | `castellan_mode` (set by the wrapper) |
| Toggles | `enable_<role>` for each role - all `true`, except `enable_mfa` |
| Measures | every opt-in measure is `true` (e.g. `services_disable_ipv6`, `network_egress_filter`); see `group_vars/all.yml` |
| Optional params | `notify_email`, `audit_logging_syslog_target`, `boot_grub_password_hash` - inert until set |
| Access | `sudo_mode` |
| SSH | `ssh_port`, `ssh_address_family`, `ssh_allow_groups`, `ssh_permit_root`, `ssh_password_auth` |
| Firewall | `ufw_default_incoming`, `ufw_allowed_ports`, `ufw_rate_limit_ssh` |
| Fail2ban | `f2b_maxretry`, `f2b_bantime`, `f2b_findtime`, `f2b_ignoreip` |
| Updates | `auto_reboot`, `auto_reboot_time` |
| Backups | `castellan_backup_dir` |

`mfa` is the only role off by default (`enable_mfa: false`) because it needs
per-user TOTP enrollment; enable it with `-e enable_mfa=true` or in the wizard.
Measures requiring an external value (remote syslog target, GRUB password hash,
alert email) stay inert until that value is provided.

## 6. Connection per host

The first contact (Play 1) is parameterized per host in
`inventory/host_vars/<host>.yml`. Plays 2 to 4 always use the new admin user, its
key and the new port.

| Case | Variables | Typical host |
|------|-----------|--------------|
| root + password | `connection_mode: root_password`, `initial_user: root`, `--ask-pass` | OVH, Contabo, classic Hetzner |
| root + key | `connection_mode: root_key`, `initial_user: root`, `initial_key` | DigitalOcean, Hetzner Cloud |
| user + sudo | `connection_mode: user_sudo`, `initial_user: <user>`, become | hosts with a pre-created user |

## 7. Roles and their references

Every role pairs an audit path with an apply path and maps to a section of
[security-measures.md](./security-measures.md). `backup_config` is cross-cutting:
it runs in bootstrap and powers rollback.

All roles run by default (`mfa` excepted). The order below is the lockout-safe
apply order, not a priority.

| Role | Section | Lockout risk | Default |
|------|---------|--------------|---------|
| backup_config | 17 (cross-cutting) | - | always |
| accounts | 1 | medium | on |
| ssh | 2 | high | on |
| firewall | 4 | high | on |
| fail2ban | 5 | medium | on |
| updates | 6 | - | on |
| compliance | 18 | - | on |
| sysctl | 7 | low | on |
| pam | 13 | medium | on |
| audit_logging | 11 | - | on |
| services | 10 | medium | on |
| network | 14 | low | on |
| filesystem | 9 | low | on |
| cron | 16 | - | on |
| confinement | 8 | low | on |
| integrity | 12 | - | on |
| boot | 15 | low | on |
| mfa | 3 | medium | off (needs TOTP enrollment) |

## 8. Backup and rollback

| Element | Mechanism |
|---------|-----------|
| File backup | Before any change, `backup_config` copies the file under `castellan_backup_dir` with a per-run timestamp and records a MANIFEST. |
| Rollback | `castellan rollback <host>` runs `50-rollback.yml`, which restores or removes files from the latest backup run (or a specific run via `-e castellan_rollback_stamp=<dir>`). |
| Extra safety net | A host-side VPS snapshot before the first apply is recommended where the provider allows it. |

An SSH or firewall rollback is inherently delicate (reverse lockout risk), so the
rollback restores the backed-up files and lets the next connection use them rather
than guessing at live service state.

## 9. Selective execution

The bootstrap and verify spine is tagged `always`, so it runs no matter what.
Other roles are tagged by name, which lets you target a subset safely.

```
castellan apply <host> --only ssh,firewall      apply only these roles
castellan audit <host> --only sysctl            audit a single role
```

`--only` is the friendly alias the wrapper translates to Ansible `--tags`. Any
other argument after the target passes straight through to `ansible-playbook`.

## 10. The harden wrapper

A thin layer over `ansible-playbook` that keeps day-to-day use trivial.

| Command | Action |
|---------|--------|
| `init <host>` | Interactive wizard; writes the host config |
| `configure <host>` | Edit an existing host's config (replays the wizard) |
| `list` | Configured hosts (target, connection, SSH port) |
| `audit <host>` | Read-only audit, reports deviations |
| `apply <host>` | Full hardening with the anti-lockout spine |
| `rollback <host>` | Restore the latest backup |
| `report <host>` | Show the latest report path per host |

A new server is therefore `castellan init <host>` followed by
`castellan apply <host>`.

## 11. Two install layouts

The same `harden` script runs from a source checkout and from the apt package,
detecting which layout it is in.

| | Source checkout | Installed via apt |
|--|-----------------|-------------------|
| Command | `./harden` | `castellan` (symlink) |
| Program files | the repository | `/usr/share/castellan` (read-only) |
| Host configs | `inventory/host_vars/` | `~/.config/castellan/host_vars/` |
| Public keys | `files/public_keys/` | `~/.config/castellan/public_keys/` |
| Reports | `reports/` | `~/.config/castellan/reports/` |

In installed mode the per-user data directory is created on first use, and
`group_vars` and the dynamic inventory are linked back to the read-only program
directory.

## 12. Dependencies

| Side | Prerequisites |
|------|---------------|
| Control machine | Ansible core 2.16+, OpenSSH client, Python 3; `sshpass` only if using initial password auth |
| Target | Python 3 (present by default on Ubuntu/Debian); initial SSH access from the host |
| Collections | `ansible.posix`, `community.general` (ufw, sysctl, pamd and related modules) |
