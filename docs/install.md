# Installation

How to install Castellan on your control machine, run it for the first time, keep
it up to date and remove it. Castellan is agentless: nothing is installed on the
servers you harden, so everything here concerns the machine you run it from.

Companion documents: [architecture.md](./architecture.md) (how it is built),
[config.md](./config.md) (what you provide), [security-measures.md](./security-measures.md)
(what it hardens).

## Requirements

Control machine (where you run Castellan):

| Requirement | Detail |
|-------------|--------|
| OS | Linux or macOS |
| Ansible | core 2.16 or newer (`ansible-core` or `ansible`) |
| Python | Python 3 |
| SSH client | OpenSSH, with your admin key loaded in `ssh-agent` |
| (none extra) | The init wizard is plain terminal prompts; no whiptail or other TUI dependency. |

Castellan never reads or copies your private keys: later connections go through
your `ssh-agent`.

Target server (the host being hardened):

| Requirement | Detail |
|-------------|--------|
| OS | Ubuntu 22.04 / 24.04 LTS, or Debian 11 / 12 |
| Access | Reachable over SSH with the initial credentials from your host (root + password, root + key, or an existing sudo user) |
| Python 3 | Already present on these distributions; nothing else is required |

## Install via apt (recommended)

This adds the signed Castellan apt repository and installs the package. apt then
pulls Ansible automatically as a dependency.

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://siir3x.github.io/castellan/castellan-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/castellan.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/castellan.gpg] https://siir3x.github.io/castellan ./" \
  | sudo tee /etc/apt/sources.list.d/castellan.list
sudo apt update && sudo apt install castellan
```

The installed command is `castellan` (a symlink to `/usr/share/castellan/harden`).
Program files live under `/usr/share/castellan` (read-only); your per-host config,
keys and reports live under `~/.config/castellan` and are created on first use.

## Install a .deb directly

If you prefer not to add the repository, download the `.deb` from the
[releases page](https://github.com/SIIR3X/castellan/releases) and install it. apt
resolves the dependencies (`python3`, `openssh-client`, `ansible-core | ansible`):

```bash
sudo apt install ./castellan_*_all.deb
```

You will not receive automatic updates this way; repeat the step for a new version.

## Install from source

A checkout needs no installation step on either side. From the repository the
command is `./harden` instead of `castellan`; the interface is identical.

```bash
git clone https://github.com/SIIR3X/castellan.git
cd castellan
sudo apt install ansible-core      # only if Ansible is not already present
ansible-playbook playbooks/site.yml --syntax-check
```

In a source checkout, per-host config lives in `inventory/host_vars/`, public keys
in `files/public_keys/` and reports in `reports/`, all inside the repository.

## Verify the installation

```bash
castellan help          # full command reference (./harden help from source)
ansible --version       # confirms Ansible core 2.16 or newer
man castellan           # the manual page (apt install only)
```

## First run

Set up a host, audit it read-only, then apply. The first apply creates the admin
user, verifies key plus sudo access on a fresh reconnection, then hardens the host
and runs a Lynis scan.

```bash
castellan init  srv-01               # interactive wizard, writes the host config
castellan audit srv-01 --ask-pass    # read-only, reports deviations (no changes)
castellan apply srv-01 --ask-pass    # apply hardening, anti-lockout ordered
```

`--ask-pass` prompts for the initial password when the host uses password auth;
it is never written to disk. See [config.md](./config.md) for every field the
wizard asks and where each value ends up.

## Update

Installed via apt and the repository:

```bash
sudo apt update && sudo apt upgrade
```

Installed from a downloaded `.deb`: download the newer `.deb` and install it the
same way (`sudo apt install ./castellan_*_all.deb`).

From source: `git pull` in the checkout.

## Uninstall

```bash
sudo apt remove castellan            # remove the package
sudo apt purge  castellan            # also remove package-managed config
```

The package only owns files under `/usr/share/castellan` and the man page. Your
per-host data under `~/.config/castellan` is left in place; delete it by hand if
you no longer need it. To also drop the repository:

```bash
sudo rm /etc/apt/sources.list.d/castellan.list /etc/apt/keyrings/castellan.gpg
```

## Build the package yourself (maintainers)

The repository ships the packaging scripts, so you can build a `.deb` without any
debhelper tooling and refresh the signed apt repository.

```bash
packaging/build-deb.sh [version] [output-dir]   # build dist/castellan_<version>_all.deb
packaging/publish-apt.sh <repo-dir> <deb>...     # add to a signed, flat apt repo
```

`build-deb.sh` defaults the version to `git describe` and writes to `dist/`. It
copies the program files to `/usr/share/castellan` and deliberately excludes the
developer's host configs, reports and test harness. `publish-apt.sh` regenerates
and GPG-signs the repository metadata (`GPG_KEY_ID` is required). See the headers
of both scripts for the full option list.
