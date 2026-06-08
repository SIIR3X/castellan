# Hardening Reference - Linux Server (Ubuntu / Debian)

> Reference document listing all security measures to apply on a freshly provisioned
> Ubuntu/Debian VPS. Serves as the specification for the automated audit + remediation tool.
>
> Targets: Ubuntu 22.04/24.04 LTS, Debian 11/12.
> Reference sources: CIS Benchmarks, ANSSI (Linux hardening guide), DISA STIG,
> devsec.hardening, Lynis.

## Priority legend

| Code | Level | Meaning |
|------|-------|---------|
| CRIT | CRITICAL | Mandatory. A gap here = direct compromise. |
| IMP | IMPORTANT | Strongly recommended. Clearly reduces the attack surface. |
| REC | RECOMMENDED | Good practice. Defense in depth. |
| OPT | OPTIONAL | Depends on usage. May interfere with some workloads. |

## Anti-lockout golden rules (the tool must enforce)

Before applying anything, the tool MUST guarantee this order, otherwise it risks locking itself out of the server:

1. Create the non-root admin user and deploy its SSH key.
2. Verify that sudo works for that user.
3. Test a real reconnection via the new user + key (and new port) before cutting root / password access.
4. Open the new SSH port in the firewall BEFORE enabling the firewall or changing the port.
5. Only reload sshd at the end of the sequence, never in the middle.
6. Keep a timestamped backup of every modified file + a rollback mode.
7. Always offer a --check mode (dry-run audit, read-only) before apply.

---

## Table of contents

1. Accounts & authentication
2. SSH
3. Strong authentication (MFA / 2FA)
4. Firewall (ufw)
5. Intrusion prevention (Fail2ban)
6. Updates & patch management
7. Kernel hardening (sysctl)
8. Confinement & isolation
9. Filesystem & mounts
10. Service & package minimization
11. Audit & logging
12. File integrity & anti-malware
13. Password policy & PAM
14. Network
15. Boot & GRUB
16. Cron & scheduled tasks
17. Backups
18. Compliance & continuous monitoring

---

## 1. Accounts & authentication

| # | Measure | Prio | Detail / target value |
|---|---------|------|------------------------|
| 1.1 | Create a non-root admin user | CRIT | With sudo group. All administration goes through it. |
| 1.2 | Disable direct root login | CRIT | Lock the account (passwd -l root) once the admin is validated. |
| 1.3 | sudo instead of persistent root | CRIT | No persistent root session. |
| 1.4 | Require a password for sudo | IMP | Avoid NOPASSWD except dedicated automation accounts. |
| 1.5 | Log all sudo commands | IMP | Defaults logfile=/var/log/sudo.log + I/O logging. |
| 1.6 | No account (besides root) with UID 0 | CRIT | Check /etc/passwd: a single UID 0. |
| 1.7 | No account without a password | CRIT | Check for empty field in /etc/shadow. |
| 1.8 | Lock system/service accounts with nologin shell | IMP | Service accounts -> /usr/sbin/nologin. |
| 1.9 | Password expiry / rotation | REC | PASS_MAX_DAYS 90, PASS_MIN_DAYS 1, PASS_WARN_AGE 7. |
| 1.10 | Restrictive default umask | REC | 027 (or 077) in /etc/login.defs & shell profiles. |
| 1.11 | Shell session idle timeout | REC | TMOUT=900 (auto logout after 15 min). |
| 1.12 | Restrict su to the wheel/sudo group | REC | Via pam_wheel.so in /etc/pam.d/su. |
| 1.13 | Remove unused accounts/groups | REC | games, news, etc. depending on usage. |
| 1.14 | Limit concurrent sessions | OPT | limits.conf maxlogins. |

---

## 2. SSH

> File: /etc/ssh/sshd_config (+ /etc/ssh/sshd_config.d/*.conf).
> Run sshd -t before any reload.

| # | Measure | Prio | Target value |
|---|---------|------|--------------|
| 2.1 | Key-based authentication only | CRIT | PasswordAuthentication no, PubkeyAuthentication yes |
| 2.2 | Disable root login | CRIT | PermitRootLogin no |
| 2.3 | Disable empty-password auth | CRIT | PermitEmptyPasswords no |
| 2.4 | Disable keyboard/challenge auth | IMP | KbdInteractiveAuthentication no, ChallengeResponseAuthentication no |
| 2.5 | Restrict allowed users/groups | IMP | AllowUsers / AllowGroups ssh-users |
| 2.6 | Change the port (reduces noise, not real security) | OPT | Port 2222 (open in ufw FIRST!) |
| 2.7 | Limit attempts & sessions | IMP | MaxAuthTries 3, MaxSessions 4, LoginGraceTime 30 |
| 2.8 | Disable X11 forwarding | REC | X11Forwarding no |
| 2.9 | Disable agent/TCP forwarding if unused | REC | AllowAgentForwarding no, AllowTcpForwarding no |
| 2.10 | Disable .rhosts & host-based auth | IMP | IgnoreRhosts yes, HostbasedAuthentication no |
| 2.11 | Strong crypto only | IMP | KEX, ciphers (chacha20-poly1305, aes256-gcm), ETM MACs, disable weak algorithms |
| 2.12 | Disable weak host-key algorithms | IMP | No DSA/keys < 2048 bits; prefer Ed25519 |
| 2.13 | Keepalive / disconnect dead sessions | REC | ClientAliveInterval 300, ClientAliveCountMax 2 |
| 2.14 | Legal warning banner | OPT | Banner /etc/issue.net |
| 2.15 | Disable PermitUserEnvironment | REC | PermitUserEnvironment no |
| 2.16 | Strict permission mode | REC | StrictModes yes |
| 2.17 | Limit SSH to IPv4/specific listen | OPT | AddressFamily inet, ListenAddress if relevant |
| 2.18 | Regenerate / harden host keys | REC | Ed25519 + RSA 4096; remove weak keys |
| 2.19 | Strict permissions on keys & config | CRIT | sshd_config 600 root, ~/.ssh 700, authorized_keys 600 |
| 2.20 | Disable reverse DNS lookup (perf) | OPT | UseDNS no |

---

## 3. Strong authentication (MFA / 2FA)

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 3.1 | TOTP 2FA on SSH | REC | libpam-google-authenticator + PAM, on top of the key. |
| 3.2 | FIDO2/U2F hardware keys | OPT | sk-ed25519 (YubiKey) for sensitive accounts. |
| 3.3 | Mandatory passphrase on private keys | REC | Client-side (policy). |
| 3.4 | Force key + 2FA | OPT | AuthenticationMethods publickey,keyboard-interactive. |

---

## 4. Firewall (ufw)

> Chosen tool: ufw. Default policy "deny all incoming".

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 4.1 | Default policy: deny incoming | CRIT | ufw default deny incoming |
| 4.2 | Default policy: allow outgoing | IMP | ufw default allow outgoing (tighten if egress filtering is needed) |
| 4.3 | Allow the SSH port before enabling | CRIT | ufw allow <port>/tcp BEFORE ufw enable |
| 4.4 | Rate-limit SSH (anti-bruteforce) | IMP | ufw limit <port>/tcp |
| 4.5 | Open ONLY the ports actually used | CRIT | 80/443 if web, etc. Least-privilege principle. |
| 4.6 | Enable firewall logging | REC | ufw logging on (low/medium) |
| 4.7 | Block invalid / spoofed packets | REC | before.rules, anti-spoofing |
| 4.8 | Consistent IPv6 filtering with IPv4 | IMP | IPV6=yes in /etc/default/ufw |
| 4.9 | Limit ICMP if unnecessary | OPT | Reduce echo/timestamp responses |
| 4.10 | Restrict admin access by source IP | REC | ufw allow from <IP> to any port <ssh> (if fixed IP) |

---

## 5. Intrusion prevention (Fail2ban)

> Config in /etc/fail2ban/jail.local (never edit jail.conf).

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 5.1 | Install + enable Fail2ban | IMP | Service enabled + started |
| 5.2 | Active SSH jail | IMP | [sshd] enabled = true (on the correct port) |
| 5.3 | Ban threshold | IMP | maxretry = 3, findtime = 10m |
| 5.4 | Progressive ban duration | REC | bantime = 1h, bantime.increment = true |
| 5.5 | systemd/journald backend | REC | backend = systemd |
| 5.6 | Allowlist of trusted IPs | IMP | ignoreip (personal IP, LAN) - avoid banning yourself |
| 5.7 | Firewall-based action | REC | banaction = ufw (consistent with the ufw choice) |
| 5.8 | Additional jails per service | OPT | recidive, nginx/apache auth, etc. |
| 5.9 | Ban notifications | OPT | Email / webhook (optional) |

---

## 6. Updates & patch management

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 6.1 | Apply all updates on arrival | CRIT | apt update && apt full-upgrade |
| 6.2 | Automatic security updates | CRIT | unattended-upgrades enabled |
| 6.3 | Configure origins (security only) | IMP | 50unattended-upgrades: security pocket |
| 6.4 | Auto-reboot if required (kernel) | REC | Automatic-Reboot + time window (02:00) |
| 6.5 | Auto-cleanup of obsolete packages | REC | Remove-Unused-Dependencies "true" |
| 6.6 | Verify package authenticity | IMP | Repository GPG; no unsigned repos |
| 6.7 | Remove unmanaged third-party repos | REC | Audit /etc/apt/sources.list.d/ |
| 6.8 | Alert on pending updates | OPT | apticron / monitoring |

---

## 7. Kernel hardening (sysctl)

> File: /etc/sysctl.d/99-hardening.conf. sysctl --system to apply.

| # | Domain | Prio | Target parameters |
|---|--------|------|-------------------|
| 7.1 | Anti-spoofing / reverse path | IMP | net.ipv4.conf.all.rp_filter=1 |
| 7.2 | Ignore ICMP redirects | IMP | accept_redirects=0, send_redirects=0 |
| 7.3 | Ignore source routing | IMP | accept_source_route=0 |
| 7.4 | SYN flood protection | IMP | tcp_syncookies=1 |
| 7.5 | Ignore ICMP broadcast | REC | icmp_echo_ignore_broadcasts=1 |
| 7.6 | Log martian packets | REC | log_martians=1 |
| 7.7 | Disable IP forwarding (if not a router) | IMP | net.ipv4.ip_forward=0 |
| 7.8 | Harden IPv6 (RA, redirects) | REC | accept_ra=0, accept_redirects=0 |
| 7.9 | Maximum ASLR | IMP | kernel.randomize_va_space=2 |
| 7.10 | Restrict dmesg | REC | kernel.dmesg_restrict=1 |
| 7.11 | Restrict kernel pointers | REC | kernel.kptr_restrict=2 |
| 7.12 | Restrict ptrace | REC | kernel.yama.ptrace_scope=1 (or 2) |
| 7.13 | Restrict unprivileged BPF | REC | kernel.unprivileged_bpf_disabled=1 |
| 7.14 | Restrict perf_event | OPT | kernel.perf_event_paranoid=3 |
| 7.15 | Disable SUID core dumps | REC | fs.suid_dumpable=0 |
| 7.16 | Hard/symbolic link protection | REC | fs.protected_hardlinks=1, fs.protected_symlinks=1 |
| 7.17 | Protect fifos/regular in /tmp | REC | fs.protected_fifos=2, fs.protected_regular=2 |
| 7.18 | Restrict module loading | OPT | kernel.modules_disabled=1 (last, irreversible at runtime) |

---

## 8. Confinement & isolation

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 8.1 | AppArmor enabled & in enforce mode | IMP | aa-status; profiles in enforce rather than complain |
| 8.2 | Load AppArmor profiles at boot | IMP | apparmor service enabled |
| 8.3 | Harden systemd units of services | REC | ProtectSystem=strict, ProtectHome=true, PrivateTmp=true, NoNewPrivileges=true, ProtectKernelModules=true, RestrictSUIDSGID=true, SystemCallFilter |
| 8.4 | Isolate exposed network services | REC | PrivateDevices, RestrictAddressFamilies, IPAddressDeny |
| 8.5 | Disable unprivileged user namespaces | OPT | kernel.unprivileged_userns_clone=0 (caution with rootless containers) |
| 8.6 | Containerize exposed apps | OPT | Docker/Podman with seccomp profiles + user namespaces |
| 8.7 | seccomp for critical services | OPT | System-call filtering |
| 8.8 | Disable loading of rare FS modules | REC | cramfs, freevxfs, jffs2, hfs, udf via modprobe blacklist |
| 8.9 | SELinux (alternative to AppArmor) | OPT | On some Debian setups; otherwise AppArmor by default |

---

## 9. Filesystem & mounts

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 9.1 | Separate /tmp with noexec,nosuid,nodev | REC | Via tmpfs or dedicated partition |
| 9.2 | Harden /var/tmp, /dev/shm | REC | noexec,nosuid,nodev |
| 9.3 | /home with nosuid,nodev | OPT | Depending on partitioning |
| 9.4 | Audit SUID/SGID binaries | IMP | List, remove the bit on unnecessary ones |
| 9.5 | No world-writable file without sticky bit | IMP | Search find / -perm -0002 |
| 9.6 | No file without an owner | REC | find / -nouser -o -nogroup |
| 9.7 | Strict permissions on sensitive files | CRIT | /etc/shadow 640/600, /etc/passwd 644, /etc/gshadow, keys |
| 9.8 | Disk/volume encryption | OPT | LUKS for sensitive data (often done at install) |
| 9.9 | Disable USB automount | OPT | If physical console is exposed |
| 9.10 | Disk quotas | OPT | Anti-DoS against saturation |

---

## 10. Service & package minimization

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 10.1 | Uninstall unnecessary network services | IMP | telnet, rsh, ftp, nis, talk, unneeded X servers |
| 10.2 | Disable unused services | IMP | systemctl disable (CUPS, avahi, bluetooth) |
| 10.3 | Audit listening ports | IMP | ss -tulpn: every open port must be justified |
| 10.4 | No mail server listening publicly | REC | Postfix/exim loopback-only if a local MTA |
| 10.5 | Remove compilers/dev tools in prod | OPT | Reduces an attacker's tooling |
| 10.6 | Disable IPv6 if unused | OPT | Otherwise harden it (see section 7) |
| 10.7 | Clean up orphaned packages | REC | apt autoremove --purge |

---

## 11. Audit & logging

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 11.1 | Install & enable auditd | IMP | Traceability of system events |
| 11.2 | Audit rules (CIS) | REC | Access to /etc/passwd, /etc/shadow, sudoers, modules, time-change, logins |
| 11.3 | Make rules immutable | OPT | -e 2 (until reboot) |
| 11.4 | Persistent journald logs | IMP | Storage=persistent, /var/log/journal |
| 11.5 | Limit log size / rotation | REC | SystemMaxUse, logrotate configured |
| 11.6 | Centralize logs (remote syslog) | OPT | rsyslog/journald -> SIEM, if available |
| 11.7 | Strict permissions on /var/log | REC | No world-readable sensitive logs |
| 11.8 | Log connections (wtmp/btmp/lastlog) | REC | Verify they are enabled |
| 11.9 | Reliable timestamps (see NTP) | IMP | Logs are useless if the clock drifts |
| 11.10 | Monitor key log files | OPT | Alerting on auth.log, fail2ban.log |

---

## 12. File integrity & anti-malware

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 12.1 | AIDE (file integrity) | REC | Reference baseline + scheduled check |
| 12.2 | Initialize AIDE database after hardening | REC | Snapshot of the "clean" state |
| 12.3 | rkhunter / chkrootkit | OPT | Rootkit detection, periodic scan |
| 12.4 | ClamAV | OPT | If the server receives/processes external files |
| 12.5 | Verify installed packages | REC | debsums: detect modified binaries |
| 12.6 | Alert on changes to critical files | OPT | /etc, SUID binaries, SSH keys |

---

## 13. Password policy & PAM

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 13.1 | Password complexity | IMP | pam_pwquality: minlen=14, dcredit, ucredit, ocredit, lcredit |
| 13.2 | Strong hashing algorithm | IMP | yescrypt or sha512 + high rounds |
| 13.3 | Password history | REC | pam_pwhistory remember=5 |
| 13.4 | Lockout after failures | IMP | pam_faillock: deny=5, unlock_time=900 |
| 13.5 | Delay between attempts | REC | pam_faildelay |
| 13.6 | Prevent immediate reuse | REC | See pwhistory |
| 13.7 | Consistency with /etc/login.defs | REC | Min/max age, warn age |

---

## 14. Network

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 14.1 | Trusted DNS | REC | Managed resolvers; DNSSEC if possible |
| 14.2 | Time synchronization (NTP) | IMP | systemd-timesyncd or chrony active & healthy |
| 14.3 | Disable rare network protocols | REC | dccp, sctp, rds, tipc via modprobe blacklist |
| 14.4 | Disable wireless if present | OPT | rfkill / nmcli (rare on a VPS) |
| 14.5 | TCP wrappers / hosts.allow-deny | OPT | Complementary application-level filtering |
| 14.6 | Pre-login network banner | OPT | /etc/issue.net |
| 14.7 | Egress filtering | OPT | Limit outbound connections of services |
| 14.8 | IP spoofing protection | REC | See sysctl rp_filter |

---

## 15. Boot & GRUB

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 15.1 | GRUB password | OPT | Prevents editing boot parameters (useful if console exposed) |
| 15.2 | Strict permissions on grub.cfg | REC | 600 root |
| 15.3 | Disable boot from external media | OPT | BIOS/console - depends on physical access |
| 15.4 | Kernel security parameters | OPT | slab_nomerge, init_on_alloc=1, mitigations per CPU |
| 15.5 | Disable Ctrl-Alt-Del (reboot) | OPT | systemctl mask ctrl-alt-del.target |

> On a VPS, console access being managed by the host, these points are often OPT.

---

## 16. Cron & scheduled tasks

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 16.1 | Restrict access to cron/at | REC | cron.allow / at.allow (whitelist root + admin) |
| 16.2 | Permissions on crontabs | REC | /etc/crontab, /etc/cron.* as 600/700 root |
| 16.3 | Audit existing scheduled tasks | IMP | Detect malicious persistence |
| 16.4 | Disable unnecessary systemd timers | OPT | systemctl list-timers |

---

## 17. Backups

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 17.1 | Back up config before hardening | CRIT | The tool MUST back up every modified file (rollback). |
| 17.2 | Data backup strategy | IMP | Off-site, encrypted, tested (3-2-1) |
| 17.3 | Backup encryption | IMP | GPG / encrypted backup tool |
| 17.4 | Restore test | REC | An untested backup = no backup |
| 17.5 | VPS snapshot before execution | REC | If the host allows it (safety net) |

---

## 18. Compliance & continuous monitoring

| # | Measure | Prio | Detail |
|---|---------|------|--------|
| 18.1 | Lynis scan post-hardening | IMP | Measure the "hardening index", aim for > 85 |
| 18.2 | Periodic re-audit | REC | Detect configuration drift |
| 18.3 | Timestamped audit report | IMP | Before/after, diff of changes |
| 18.4 | Monitor critical services | REC | sshd, fail2ban, ufw, auditd always active |
| 18.5 | Alerting on security events | OPT | Root logins, new users, open ports |
| 18.6 | Document the applied state | REC | Version the hardening config |

---

## Category summary for the tool

| Module | Category | Audit phase | Apply phase | Lockout risk |
|--------|----------|:-----------:|:-----------:|:------------:|
| accounts | Accounts & auth | yes | yes | medium |
| ssh | SSH | yes | yes | high |
| mfa | MFA / 2FA | yes | yes | medium |
| firewall | ufw | yes | yes | high |
| fail2ban | Anti-bruteforce | yes | yes | medium (self-ban) |
| updates | Patch management | yes | yes | - |
| sysctl | Kernel | yes | yes | low |
| confinement | AppArmor/systemd | yes | yes | low |
| filesystem | FS & mounts | yes | yes | low |
| services | Minimization | yes | yes | medium |
| audit | auditd/logs | yes | yes | - |
| integrity | AIDE/rkhunter | yes | yes | - |
| pam | Passwords | yes | yes | medium |
| network | Network/NTP | yes | yes | low |
| boot | GRUB | yes | yes | low |
| cron | Scheduled tasks | yes | yes | - |
| backup | Backups | yes | yes | - |
| compliance | Lynis/reporting | yes | - | - |

---

## Important note on "100% secure"

Absolute security does not exist: this reference aims to reduce the attack surface as much
as possible and apply the state of the art (CIS / ANSSI). A few principles to keep in mind:

- Defense in depth: no single measure is sufficient on its own; it is the layering that protects.
- Least privilege: only open/enable what is strictly necessary.
- Reversibility: every change must be backed up and undoable.
- Idempotence: re-running the tool must be safe.
- Context: some measures (OPT) depend on the server's usage (web, DB, containers).
- Maintenance over time: a server hardened once drifts; re-auditing is essential.
