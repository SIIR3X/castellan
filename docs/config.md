# Configuration & handling of user input

> Design document. Defines everything the user must provide to use the tool, the
> secret / non-secret classification, where each piece of data lives, and the flow of the
> init wizard. No code. Companions: [architecture.md](./architecture.md),
> [security-measures.md](./security-measures.md).

---

## 1. Founding principle

> The more secret a piece of data is, the less it should persist.

Every user input falls into one of these 4 classes, handled differently:

| Class | Persistence | Storage | Versionable (git) |
|-------|-------------|---------|:-----------------:|
| A. Public config | Permanent | Plaintext YAML | yes |
| B. SSH public key | Permanent | .pub file / path | yes (it is public) |
| C. Ephemeral secret | None (memory only) | On-the-fly prompt | no (never written) |
| D. Persistent secret | Permanent but encrypted | Ansible Vault | yes (unreadable without passphrase) |
| E. SSH private key | - | Stays on the control machine | no (never leaves your machine) |

---

## 2. Exhaustive list of fields to provide

### 2.1 Initial connection (first contact with the VPS)

| Field | Class | Required | Description | Example |
|-------|:-----:|:--------:|-------------|---------|
| target_ip | A | yes | VPS IP or FQDN | 203.0.113.42 |
| connection_mode | A | yes | root_password / root_key / user_sudo | root_password |
| initial_user | A | yes | First-connection account | root |
| initial_password | C | mode-dependent | Password provided by the host. Single use, never stored. | (prompt) |
| initial_key | E | mode-dependent | Private key already accepted by the host (if root_key) | ~/.ssh/hoster_key |
| initial_port | A | yes (default 22) | SSH port at first contact | 22 |

> Depending on connection_mode, either initial_password (ephemeral prompt) or initial_key
> (local path) is used. Never both.

### 2.2 Admin identity to create

| Field | Class | Required | Description | Default |
|-------|:-----:|:--------:|-------------|---------|
| admin_user | A | yes | Name of the non-root user to create | - |
| admin_pubkey_file | B | yes | Path to the public key to deploy | ~/.ssh/id_ed25519.pub |
| sudo_mode | A | yes | nopasswd (key only) / password (2nd factor) | nopasswd |
| admin_password | D | if sudo_mode=password | Sudo password. Randomly generated or entered. Only the hash is stored (Vault). | (generated) |

> The private key matching admin_pubkey_file is never requested nor handled by
> the tool: subsequent connections use your ssh-agent.

### 2.3 SSH hardening parameters

| Field | Class | Description | Default (standard) |
|-------|:-----:|-------------|--------------------|
| ssh_port | A | New SSH port | 22 (or your choice) |
| ssh_allow_groups | A | Groups allowed to connect | [ssh-users] |
| ssh_permit_root | A | Root login allowed? | no |
| ssh_password_auth | A | Password auth allowed? | no |

### 2.4 Firewall parameters (ufw)

| Field | Class | Description | Default |
|-------|:-----:|-------------|---------|
| ufw_allowed_ports | A | List of ports to open (besides SSH, handled automatically) | [] |
| ufw_rate_limit_ssh | A | Rate-limit SSH | true |
| ufw_admin_source_ip | A | Restrict admin to one source IP (optional) | (empty) |

### 2.5 Fail2ban parameters

| Field | Class | Description | Default |
|-------|:-----:|-------------|---------|
| f2b_ignoreip | A | Trusted IPs to never ban (your IP!) | [your IP] |
| f2b_maxretry | A | Attempts before ban | 3 |
| f2b_bantime | A | Ban duration | 1h |

### 2.6 Global parameters

| Field | Class | Description | Default |
|-------|:-----:|-------------|---------|
| hardening_profile | A | minimal / standard / paranoid | standard |
| enable_<role> | A | Enable/disable each module (ssh, sysctl) | per profile |
| auto_reboot | A | Auto-reboot if a kernel update requires it | false |
| notify_email | A | Email for alerts (optional) | (empty) |

---

## 3. Where each thing is stored

```
vps-hardening/
  group_vars/
    all.yml          <- Class A: global default values (PLAINTEXT)
    vault.yml        <- Class D: persistent secrets (ENCRYPTED Ansible Vault)
  inventory/
    host_vars/
      203.0.113.42.yml   <- Class A: per-VPS config (PLAINTEXT)
  files/
    public_keys/
      id_ed25519.pub     <- Class B: public key (PLAINTEXT, it is public)

  (Class C) initial_password ... NEVER written: in-memory prompt at runtime
  (Class E) private key       ... stays in ~/.ssh + ssh-agent, outside the project
```

### Example host_vars/203.0.113.42.yml (plaintext, versionable)

> Illustrative shape - no secret inside:

```
target_ip:        203.0.113.42
connection_mode:  root_password
initial_user:     root
admin_user:       lucas
admin_pubkey_file: files/public_keys/id_ed25519.pub
sudo_mode:        nopasswd
ssh_port:         2222
ufw_allowed_ports: [80, 443]
f2b_ignoreip:     ["198.51.100.10"]
hardening_profile: standard
```

This file can go into git with no risk: it contains only configuration.

---

## 4. Secret handling - strict rules

| Secret | Rule |
|--------|------|
| Initial password (host) | Prompt at runtime (--ask-pass). Never on disk, never in git, never in logs. Cleared from memory after use. |
| Admin sudo password (if password) | Randomly generated (>= 20 chars) or entered. Shown once to the user. Only the hash is stored, in Vault. |
| SSH private key | Never read, never copied by the tool. Connection via ssh-agent or local path. |
| Vault passphrase | Known only to the user. Prompted at runtime if Vault is used. |
| Logs | Tasks handling secrets are marked "no_log" -> nothing leaks into the output. |

### Why the initial password does not need to be stored

It is used only once (Play 1: create the admin + deploy the key). Right after, hardening
disables password auth -> this secret becomes useless. Storing it would be a risk with no
benefit.

---

## 5. Flow of the ./harden init <ip> wizard

The user writes no YAML: the wizard asks the questions and generates the file.

```
$ ./harden init 203.0.113.42

  [ Initial connection ]
  ? Connection mode           > root + password
  ? Initial user              > root
  ? Current SSH port          > 22

  [ Admin user to create ]
  ? Admin name                > lucas
  ? Public key to deploy      > ~/.ssh/id_ed25519.pub   [detected]
  ? Passwordless sudo?        > yes   (recommended, key only)

  [ Hardening ]
  ? Profile                   > standard
  ? New SSH port              > 2222
  ? Ports to open (firewall)  > 80, 443
  ? Your IP (never banned)    > 198.51.100.10   [detected]

  OK Config written: inventory/host_vars/203.0.113.42.yml
  OK No secret written to disk.
  i  The initial password will be requested when running "apply".

$ ./harden apply 203.0.113.42
  ? Initial password (root@203.0.113.42) > ********   [not stored]
  -> hardening in progress...
```

### Auto-detected fields (convenience)

| Field | Proposed detection |
|-------|--------------------|
| admin_pubkey_file | Scan ~/.ssh/*.pub, propose the key found |
| f2b_ignoreip | Detect the public IP of the control machine |
| admin_user | Propose the local username by default |

---

## 6. Input validation (before execution)

The tool must verify before acting, to avoid errors and lockout:

| Check | Why |
|-------|-----|
| The public key exists and is valid | Otherwise admin created without access -> lockout |
| f2b_ignoreip does contain your IP | Otherwise self-ban is possible |
| The target SSH port is in the allowed ufw ports | Anti-lockout consistency |
| Valid IP / port format | Avoids failures mid-execution |
| connection_mode consistent with provided secrets | password vs key |
| Initial connectivity tested | Network failure detected early |

---

## 7. Summary: who fills in what, and where it ends up

| The user provides... | How | Becomes... |
|----------------------|-----|------------|
| IP, admin user, ports, profile | init wizard | host_vars/<ip>.yml (plaintext, git-safe) |
| Their public key | Path (auto-detected) | Copied into files/public_keys/ |
| The initial password | Prompt at apply | Nothing (memory, then forgotten) |
| Sudo password (if chosen) | Generated / prompt | Hash in vault.yml (encrypted) |
| Their private key | - | Stays on their machine (ssh-agent) |

Result: the user fills in their info once, without editing any file by hand,
and no plaintext secret ends up on disk or in git.

---

## 8. Open points (to settle before implementation)

1. Interactive wizard vs example file: full wizard, or ship a host_vars.example.yml to copy? (the wizard is safer for beginners)
2. Prompt format: TUI tool (styled questions) or plain shell read? (depends on the wrapper's language)
3. Vault always created, or only if sudo_mode=password? (avoid a useless passphrase in the key-only case)
4. Multi-VPS: one host_vars per machine (already planned) or a "fleet" mode with shared config?
5. Config reuse: allow shared defaults for all VPS in group_vars/all.yml to avoid re-entering everything?
