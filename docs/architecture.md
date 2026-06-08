# Architecture - VPS Hardening Tool (Ansible)

> Design document. Describes the project structure, the breakdown into roles, the anti-lockout
> execution flow, and the usage experience. No code here: this is the plan that will guide
> implementation. Functional reference: [security-measures.md](./security-measures.md).

---

## 1. Guiding principles

| Principle | Architectural consequence |
|-----------|---------------------------|
| Agentless | Nothing installed on the VPS. Everything goes through SSH from the control machine. Only Python (already present) is required on the target. |
| Two separate phases | audit (read-only, --check) then apply (modifies). Never an apply without a prior audit being possible. |
| Anti-lockout | Strict execution order; reconnection check before cutting access. |
| Idempotence | Re-running the playbook 1 or 50 times = same result, safely. |
| Reversibility | Timestamped backup of every modified file + a rollback procedure. |
| Modularity | 1 security category = 1 role = independently enable/disable. |
| Variable connection | Supports root+password, root+key, or user+sudo depending on the host. |

---

## 2. Project tree

```
vps-hardening/
  harden                          # CLI wrapper (script): ./harden audit|apply|rollback <host>
  ansible.cfg                     # Ansible config (SSH, pipelining, retry, callback)
  README.md

  inventory/
    hosts.yml                     # VPS list (groups, IPs)
    host_vars/
      <ip>.yml                    # Per-VPS parameters (port, user)

  group_vars/
    all.yml                       # Global config (default hardening values)
    vault.yml                     # Encrypted secrets (Ansible Vault): initial passwords

  playbooks/
    site.yml                      # Master playbook (orchestrates the plays)
    00-bootstrap.yml              # Play 1: initial connection, create admin + key
    01-verify-access.yml          # Play 2: test reconnection via the new access (safety net)
    10-harden.yml                 # Play 3: apply all hardening roles
    99-report.yml                 # Play 4: Lynis audit + final report

  roles/
    accounts/                     # Sec 1  Accounts & sudo
    ssh/                          # Sec 2  sshd hardening
    mfa/                          # Sec 3  TOTP 2FA (optional)
    firewall/                     # Sec 4  ufw
    fail2ban/                     # Sec 5  Anti-bruteforce
    updates/                      # Sec 6  unattended-upgrades
    sysctl/                       # Sec 7  Kernel hardening
    confinement/                  # Sec 8  AppArmor + systemd sandboxing
    filesystem/                   # Sec 9  Mounts, SUID, permissions
    services/                     # Sec 10 Service/package minimization
    audit_logging/                # Sec 11 auditd + journald
    integrity/                    # Sec 12 AIDE / rkhunter
    pam/                          # Sec 13 Password policy
    network/                      # Sec 14 NTP, protocols, DNS
    boot/                         # Sec 15 GRUB
    cron/                         # Sec 16 Scheduled-task restrictions
    backup_config/                # Sec 17 Pre-change backup (cross-cutting)
    compliance/                   # Sec 18 Lynis + reporting

  reports/                        # Generated reports (audit/diff/Lynis), timestamped
    <ip>_<date>/

  files/
    public_keys/                  # Public keys to deploy
```

### Anatomy of a role (common template)

```
roles/ssh/
  defaults/main.yml      # Default variables (port, options, target values)
  tasks/
    main.yml             # Dispatches to audit.yml or apply.yml
    audit.yml            # Read-only checks -> collect deviations
    apply.yml            # Remediation (with prior backup)
  handlers/main.yml      # e.g. "reload sshd" (triggered at end of play)
  templates/
    sshd_hardening.conf.j2
  meta/main.yml          # Possible dependencies (e.g. backup_config)
```

This template is identical across the 18 roles: this is what makes the whole set consistent and maintainable.

---

## 3. Execution flow (anti-lockout orchestration)

site.yml chains 4 plays. The sequencing is the heart of the safety design.

```
+-----------------------------------------------------------------+
|  PLAY 1 - BOOTSTRAP      (connection: INITIAL credentials)       |
|  roles: accounts, backup_config                                 |
|   - Updates the apt cache                                       |
|   - Creates the admin user + sudo group                         |
|   - Deploys the SSH public key                                  |
|   - Configures sudo                                             |
|   - DOES NOT TOUCH sshd YET                                     |
+-----------------------------------------------------------------+
                              |
                              v
+-----------------------------------------------------------------+
|  PLAY 2 - VERIFY ACCESS  (connection: NEW admin + key)           |
|   - Attempts a real connection with the new user                |
|   - Verifies that sudo works                                    |
|   - FAILURE HERE  ->  STOP, root access still intact (no lock)  |
|   - SUCCESS       ->  green light to harden                     |
+-----------------------------------------------------------------+
                              |
                              v
+-----------------------------------------------------------------+
|  PLAY 3 - HARDEN         (connection: NEW admin + sudo)          |
|  IMPERATIVE order of roles:                                     |
|   1. firewall   -> open the SSH port BEFORE enabling ufw        |
|   2. fail2ban   -> ignoreip = your IP (no self-ban)             |
|   3. ssh        -> disable root/password, change port           |
|      ("reload sshd" handler deferred to end of play)            |
|   4. sysctl, pam, confinement, filesystem, services,           |
|      audit_logging, integrity, network, cron, boot, updates     |
|   5. FLUSH handlers -> reload sshd ONCE, at the very end        |
+-----------------------------------------------------------------+
                              |
                              v
+-----------------------------------------------------------------+
|  PLAY 4 - REPORT                                                |
|   - Runs Lynis, retrieves the hardening index                   |
|   - Generates the report (before/after, diff, remaining gaps)   |
|   - Fetches it into reports/<ip>_<date>/                        |
+-----------------------------------------------------------------+
```

### Why this order

- Firewall before SSH: the new port must be open before sshd enables it, otherwise lockout.
- Fail2ban before SSH: ignoreip configured before any ban can reach you.
- SSH (reload) last: via a handler triggered by "meta: flush_handlers" at the very end, never in the middle.
- Play 2 = safety net: if the new connection does not work, we stop before breaking anything.

---

## 4. AUDIT vs APPLY mode

A single codebase, two behaviors, driven by a "mode" variable.

| Aspect | audit | apply |
|--------|-------|-------|
| Invocation | ./harden audit <host> | ./harden apply <host> |
| Under the hood | ansible-playbook ... --check --diff + mode=audit | real execution, mode=apply |
| Effect on the VPS | None (read-only) | Modifies the config |
| Output | List of deviations per measure (compliant / non-compliant) | List of applied changes + diff |
| Roles executed | each role's tasks/audit.yml | tasks/apply.yml (backup -> modify) |

Each role therefore exposes two paths (audit.yml / apply.yml) selected by mode.
Audit mode feeds a compliance report mapped to the security-measures.md identifiers
(e.g. "2.1 ok", "7.9 fail expected=2 found=0").

---

## 5. Centralized configuration (group_vars/all.yml)

All customization happens here, without touching the role code. Expected shape:

| Block | Key variables (examples) |
|-------|--------------------------|
| Access | admin_user, admin_pubkey_file, sudo_nopasswd |
| SSH | ssh_port, ssh_permit_root, ssh_password_auth, ssh_allow_groups |
| Firewall | ufw_default_incoming, ufw_allowed_ports[], ufw_rate_limit_ssh |
| Fail2ban | f2b_maxretry, f2b_bantime, f2b_ignoreip[] |
| Updates | auto_reboot, auto_reboot_time |
| Module toggles | enable_<role>: true/false for each role |
| Profile | hardening_profile: minimal / standard / paranoid |

### Predefined profiles

To avoid configuring everything by hand, 3 profiles determine which measures
(by priority CRIT/IMP/REC/OPT) are enabled:

| Profile | Includes | Usage |
|---------|----------|-------|
| minimal | essential CRIT + IMP | Quick hardening, low risk of breakage |
| standard | CRIT IMP REC | Recommended default. Good balance. |
| paranoid | everything, including OPT | Sensitive servers, after validating usage |

---

## 6. Handling variable connection per host

Answer to the "it varies by host" case. The initial connection (Play 1) is
parameterized per VPS in host_vars/<ip>.yml:

| Host case | Variables | Detail |
|-----------|-----------|--------|
| root + password | initial_user: root + --ask-pass (or vault) | OVH, Contabo, classic Hetzner |
| root + key | initial_user: root, key already in place | DigitalOcean, Hetzner Cloud |
| user + sudo | initial_user: <user>, become: true | Hosts with a pre-created user |

Plays 2 to 4 always use the new admin_user + key + (new) port.
The harden wrapper detects/asks for the connection mode on first contact.

---

## 7. Backup & rollback strategy

| Element | Mechanism |
|---------|-----------|
| File backup | Before each modification, a timestamped copy (*.bak.<timestamp>) on the VPS + an option to fetch locally |
| Cross-cutting role | backup_config (as a meta dependency of roles that modify files) |
| Rollback | ./harden rollback <host> restores the most recent .bak files and reloads services |
| Extra safety net | Recommendation: VPS snapshot on the host side before apply |

> Note: an SSH/firewall rollback remains delicate (reverse lockout risk). The wrapper
> always keeps a backup session and only acts after confirming reconnection.

---

## 8. Selective execution (tags)

Each role is tagged (ssh, firewall, sysctl) to allow:

```
./harden apply <host> --only ssh,firewall      # apply only these modules
./harden audit <host> --skip boot,integrity    # audit excluding some modules
```

Under the hood: Ansible's --tags / --skip-tags.

---

## 9. User experience (the harden wrapper)

A thin layer over ansible-playbook to make usage trivial:

| Command | Action |
|---------|--------|
| ./harden init <ip> | Adds the VPS to the inventory, asks for the connection mode |
| ./harden audit <ip> | Read-only audit -> compliance report |
| ./harden apply <ip> | Full hardening (with safety nets) |
| ./harden rollback <ip> | Restores the latest backup |
| ./harden report <ip> | Displays/re-reads the latest report |
| ./harden apply <ip> --profile paranoid | Profile choice |

End goal: a new VPS = ./harden init <ip> then ./harden apply <ip>.

---

## 10. Dependencies & prerequisites

| Side | Prerequisites |
|------|---------------|
| Control machine | Ansible, sshpass (if initial password auth), SSH access to the VPS |
| Target VPS | Python 3 (present by default on Ubuntu/Debian), initial access provided by the host |
| Ansible collections | ansible.posix, community.general (ufw, sysctl modules, etc.) |
| Optional | devsec.hardening (reusable for ssh/os/sysctl if relying on ready-made CIS) |

---

## 11. Architectural decisions to settle (before implementation)

Open points that will shape the code:

1. Custom roles vs devsec.hardening: rewrite everything (full control, educational) or
   rely on existing CIS roles for ssh/os/sysctl (less maintenance)?
2. MVP scope: start with accounts + ssh + firewall + fail2ban + updates,
   then extend? (recommended)
3. Report: audit report format (readable Markdown, machine JSON, or both)?
4. Secrets: Ansible Vault for initial passwords, or interactive --ask-pass input?
5. Multi-VPS: target fleet execution (several hosts in parallel) from the start?
6. SSH rollback: how far to automate rollback of lockout-risky modules?

---

## 12. Role to reference mapping

| Role | security-measures.md section | Lockout risk | In minimal profile |
|------|:----------------------------:|:------------:|:------------------:|
| accounts | 1 | medium | yes |
| ssh | 2 | high | yes |
| mfa | 3 | medium | - |
| firewall | 4 | high | yes |
| fail2ban | 5 | medium | yes |
| updates | 6 | - | yes |
| sysctl | 7 | low | yes |
| confinement | 8 | low | - |
| filesystem | 9 | low | partial |
| services | 10 | medium | partial |
| audit_logging | 11 | - | - |
| integrity | 12 | - | - |
| pam | 13 | medium | partial |
| network | 14 | low | yes |
| boot | 15 | low | - |
| cron | 16 | - | - |
| backup_config | 17 (cross-cutting) | - | yes |
| compliance | 18 | - | yes |
