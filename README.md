# Castellan

<p align="center">
  <img src="docs/assets/castellan-banner.svg" alt="Castellan" width="780">
</p>

<p align="center">
  <a href="https://github.com/SIIR3X/castellan/releases/latest"><img src="https://img.shields.io/github/v/release/SIIR3X/castellan?color=blue&label=version" alt="Latest release"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-Linux-1793d1.svg" alt="Platform: Linux">
  <img src="https://img.shields.io/badge/ansible-core%202.16%2B-1f3b4d.svg" alt="Ansible core 2.16+">
  <img src="https://img.shields.io/badge/targets-Ubuntu%20%7C%20Debian-e2761b.svg" alt="Targets: Ubuntu / Debian">
  <img src="https://img.shields.io/badge/agentless-yes-2ea44f.svg" alt="Agentless">
</p>

**Agentless security hardening for Ubuntu and Debian servers, driven by Ansible
from your machine. One command runs a read-only audit, another applies the
fixes - nothing is ever installed on the target.**

## Description

Castellan turns a freshly provisioned Ubuntu/Debian VPS into a hardened server
by applying the state of the art (CIS, ANSSI, DISA STIG, Lynis) across 18
categories - accounts, SSH, firewall, kernel, logging, integrity and more.

It is **agentless**: everything runs over SSH using the Python 3 interpreter
that already ships with the distribution. There is no daemon to install, no
package to leave behind, and the whole configuration lives in plain, versionable
YAML.

Two principles drive the design:

- **Never lock yourself out.** Castellan creates and verifies the new admin user
  (key + sudo, fresh reconnection) *before* it ever touches root, passwords, the
  SSH port or the firewall. sshd is reloaded once, at the very end. Every changed
  file is backed up and a `rollback` command restores it.
- **Audit before you apply.** Every role ships a read-only audit that reports
  deviations without changing anything, and an apply path that remediates them.
  A post-run Lynis scan gives you a measurable hardening index.

Hardening is selected with **profiles** (`minimal`, `standard`, `paranoid`) and
fine-tuned per host with an interactive selector - no manual file editing
required.

### What it hardens

| Area | Examples |
|------|----------|
| Accounts & auth | non-root admin, root lockdown, sudo logging, password aging, umask, `su` restriction |
| SSH | key-only, no root, modern crypto, `AllowGroups`, optional banner / FIDO2 / port change |
| MFA (opt-in) | TOTP 2FA over keyboard-interactive, with the automation account exempted |
| Firewall (ufw) | default-deny, SSH opened first, rate-limit, anti-spoofing, optional egress filter |
| Intrusion prevention | Fail2ban sshd jail, `banaction=ufw`, allowlist |
| Updates | unattended security upgrades, authenticity enforcement |
| Kernel (sysctl) | ASLR, ptrace/dmesg/kptr restrictions, network hardening |
| Logging & audit | auditd CIS rules, persistent journald, optional remote syslog |
| Integrity | AIDE baseline, debsums, optional rkhunter / ClamAV |
| Filesystem | hardened `/tmp` mounts, sensitive file permissions |
| Confinement | AppArmor enforce, rare-FS / protocol blacklists |
| Services | minimize packages, disable unused units |
| Cron, PAM, Boot, Network, Compliance | see [`docs/security-measures.md`](docs/security-measures.md) |

The full catalogue, with priorities (CRITICAL / IMPORTANT / RECOMMENDED /
OPTIONAL), is documented in
[`docs/security-measures.md`](docs/security-measures.md). The architecture and
the configuration model are described in
[`docs/architecture.md`](docs/architecture.md) and
[`docs/config.md`](docs/config.md).

## Requirements

**Control machine (where you run Castellan):**

- Linux/macOS with **Ansible core 2.16+** and **Python 3**
- An SSH key loaded in your `ssh-agent` (Castellan never reads or copies private
  keys)
- `whiptail` is used for the interactive menus when present; otherwise a plain
  text prompt fallback is used (no install required)

**Target server:**

- **Ubuntu 22.04 / 24.04 LTS** or **Debian 11 / 12**
- Reachable over SSH with the initial credentials provided by your host
  (root + password, root + key, or an existing sudo user)
- The pre-installed **Python 3** (already present on these distributions) -
  nothing else

## Installation

The essentials are below; see [`docs/install.md`](docs/install.md) for the full
guide (prerequisites, direct `.deb`, first run, updates, uninstall, building the
package yourself).

### Via apt (recommended)

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://siir3x.github.io/castellan/castellan-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/castellan.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/castellan.gpg] https://siir3x.github.io/castellan ./" \
  | sudo tee /etc/apt/sources.list.d/castellan.list
sudo apt update && sudo apt install castellan
```

apt pulls Ansible automatically. The command is then `castellan` (per-host config
lives in `~/.config/castellan/`). Updates arrive through `apt upgrade`.

You can also grab the `.deb` from the
[releases page](https://github.com/SIIR3X/castellan/releases) and
`sudo apt install ./castellan_*_all.deb`.

### From source

```bash
git clone https://github.com/SIIR3X/castellan.git
cd castellan
sudo apt install ansible          # control machine only, if needed
ansible-playbook playbooks/site.yml --syntax-check
```

There is nothing to install on the server. From a checkout the command is
`./harden`; installed via apt it is `castellan` - same interface.

## Usage

The command is **`castellan`** when installed via apt; from a source checkout it
is **`./harden`** - the interface is identical. Examples below use `castellan`.
Per-host config is stored under `~/.config/castellan/` (or `inventory/host_vars/`
from a checkout); you never edit an inventory file by hand.

### 1. Set up a host (interactive wizard)

```bash
castellan init srv-01
```

The wizard asks for the initial connection (root + password, root + key, or an
existing sudo user), the admin user to create, the public key to deploy, the
hardening profile and the ports, then writes the host's config. The host is then
known automatically (dynamic inventory).

### 2. Choose what to harden (profile + measures)

```bash
castellan configure srv-01
```

A menu lists every role; open a role to tick individual measures, or tick the
whole role at once. The selection is saved back to the host's config. Where
`whiptail` is unavailable, a plain text menu is used instead.

```
Configure srv-01                         Profile: standard
  Profile .......... standard
  ssh .............. 1/3 extra
  firewall ......... 0/1 extra
  ...

  ssh - measures
  [*]  >> WHOLE ROLE (every measure)
  [*]  2.14  Pre-auth legal banner
  [ ]  3.2   Accept FIDO2/U2F security keys
```

### 3. Audit, then apply

```bash
castellan audit srv-01 --ask-pass    # read-only, reports deviations (no changes)
castellan apply srv-01 --ask-pass    # apply hardening (anti-lockout ordered)
```

`--ask-pass` prompts for the initial password when needed; it is never stored.
The first apply creates the admin user, verifies key + sudo access, then hardens
the host and runs a Lynis scan.

### Inspect, report, roll back

```bash
castellan list                       # configured hosts, their profile and measures
castellan report   srv-01            # path to the latest report (Lynis index)
castellan rollback srv-01            # restore the latest backup
```

### Profiles, targets and selective runs

```bash
# Pick a profile per run (or set it per host in the wizard / configure):
castellan apply srv-01 -e hardening_profile=paranoid

# Enable a measure / opt-in role for a single run:
castellan apply srv-01 -e enable_mfa=true

# Multiple targets: a comma-list, an inventory group, or all hosts:
castellan apply web1,web2,db1
castellan apply vps
castellan apply all --forks 10

# Run only specific roles (the bootstrap + verify safety net always runs first):
castellan apply srv-01 --only ssh,firewall
```

Any extra argument after the target is passed straight to `ansible-playbook`
(e.g. `--tags`, `--limit`, `-e`).

> **Tip:** `castellan help` prints the full command reference.

### Hardening profiles

| Profile | Roles run |
|---------|-----------|
| `minimal` | the lockout-critical spine + security updates + reporting |
| `standard` | `minimal` + all low-risk hardening roles (**default**) |
| `paranoid` | `standard` + the opt-in roles (confinement, integrity, boot) |

`mfa` is never enabled by a profile (it needs TOTP enrollment); turn it on with
`-e enable_mfa=true` or in the selector.

## Documentation

| Document | Contents |
|----------|----------|
| [`docs/install.md`](docs/install.md) | Install (apt, `.deb`, source), prerequisites, first run, updates, uninstall |
| [`docs/architecture.md`](docs/architecture.md) | How it is built: roles, the anti-lockout flow, audit/apply, install layouts |
| [`docs/config.md`](docs/config.md) | What you provide: fields, secret handling, the init wizard |
| [`docs/security-measures.md`](docs/security-measures.md) | The hardening catalogue: 18 categories with priorities |
| [`SECURITY.md`](SECURITY.md) | Supported versions and how to report a vulnerability |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history |

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for details.

Copyright (c) 2026 Lucas Fagioli.
