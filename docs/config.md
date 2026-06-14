# Configuration and user input

Everything the user provides to Castellan: the fields, the secret versus
non-secret classification, where each value is stored, and the flow of the init
wizard.

Companion documents: [install.md](./install.md) (set up the control machine),
[architecture.md](./architecture.md) (how it is built),
[security-measures.md](./security-measures.md) (the hardening catalogue).

## 1. Founding principle

The more secret a piece of data is, the less it should persist. Every input falls
into one of five classes, each handled differently.

| Class | Persistence | Storage | Versionable in git |
|-------|-------------|---------|--------------------|
| A. Public config | Permanent | Plaintext YAML | yes |
| B. SSH public key | Permanent | `.pub` file or path | yes (it is public) |
| C. Ephemeral secret | None (memory only) | Runtime prompt | no (never written) |
| D. Persistent secret | Permanent but encrypted | Ansible Vault | yes (unreadable without the passphrase) |
| E. SSH private key | - | Stays on the control machine | no (never leaves your machine) |

## 2. Fields to provide

The wizard (`castellan init <host>`) collects all of these; you never edit YAML by
hand. The tables mirror `inventory/host_vars.example.yml`.

### 2.1 Initial connection (first contact)

| Field | Class | Required | Description | Example |
|-------|-------|----------|-------------|---------|
| `target_ip` | A | yes | Server IP or FQDN | 203.0.113.42 |
| `connection_mode` | A | yes | root_password / root_key / user_sudo | root_password |
| `initial_user` | A | yes | Account used for the first connection | root |
| `initial_password` | C | mode-dependent | Provided by the host, used once, never stored | (prompt) |
| `initial_key` | E | mode-dependent | Private key already accepted by the host (root_key) | ~/.ssh/hoster_key |
| `initial_port` | A | yes (default 22) | SSH port at first contact | 22 |

Depending on `connection_mode`, either `initial_password` (an ephemeral prompt) or
`initial_key` (a local path) is used, never both.

### 2.2 Admin identity to create

| Field | Class | Required | Description | Default |
|-------|-------|----------|-------------|---------|
| `admin_user` | A | yes | Name of the non-root user to create | - |
| `admin_pubkey_file` | B | yes | Path to the public key to deploy | ~/.ssh/id_ed25519.pub |
| `sudo_mode` | A | yes | nopasswd (key only) / password (second factor) | nopasswd |
| `admin_password` | D | if `sudo_mode=password` | Sudo password; only the hash is stored, in Vault | (generated) |

The private key matching `admin_pubkey_file` is never requested nor handled by the
tool; later connections use your `ssh-agent`.

### 2.3 SSH hardening

| Field | Class | Description | Default |
|-------|-------|-------------|---------|
| `ssh_port` | A | New SSH port (open it in ufw first) | 22 |
| `ssh_allow_groups` | A | Groups allowed to connect | [ssh-users] |
| `ssh_permit_root` | A | Allow root login | "no" |
| `ssh_password_auth` | A | Allow password auth | "no" |

### 2.4 Firewall (ufw)

| Field | Class | Description | Default |
|-------|-------|-------------|---------|
| `ufw_allowed_ports` | A | Extra ports to open besides SSH | [] |
| `ufw_rate_limit_ssh` | A | Rate-limit SSH | true |
| `ufw_admin_source_ip` | A | Restrict admin access to one source IP (optional) | (empty) |

### 2.5 Fail2ban

| Field | Class | Description | Default |
|-------|-------|-------------|---------|
| `f2b_ignoreip` | A | Trusted IPs never banned (add your own) | [] |
| `f2b_maxretry` | A | Attempts before a ban | 3 |
| `f2b_bantime` | A | Ban duration | 1h |

### 2.6 Global

| Field | Class | Description | Default |
|-------|-------|-------------|---------|
| `hardening_profile` | A | minimal / standard / paranoid | standard |
| `enable_<role>` | A | Force a role on or off regardless of the profile | per profile |
| `auto_reboot` | A | Auto-reboot when a kernel update requires it | false |
| `notify_email` | A | Email for alerts (optional) | (empty) |

## 3. Where each value is stored

```
castellan/
  inventory/
    group_vars/
      all.yml              Class A: global defaults (PLAINTEXT)
      vault.yml            Class D: persistent secrets (ENCRYPTED, Ansible Vault)
    host_vars/
      203.0.113.42.yml     Class A: per-host config (PLAINTEXT)
  files/
    public_keys/
      id_ed25519.pub       Class B: public key (PLAINTEXT, it is public)

  Class C  initial_password   never written; in-memory prompt at runtime
  Class E  private key        stays in ~/.ssh and ssh-agent, outside the project
```

Installed via apt, the per-host config, keys and vault live under
`~/.config/castellan/` instead of inside the repository; the storage classes are
unchanged.

Example `host_vars/203.0.113.42.yml`, plaintext and git-safe (no secret inside):

```
target_ip:         203.0.113.42
connection_mode:   root_password
initial_user:      root
admin_user:        lucas
admin_pubkey_file: files/public_keys/id_ed25519.pub
sudo_mode:         nopasswd
ssh_port:          2222
ufw_allowed_ports: [80, 443]
f2b_ignoreip:      ["198.51.100.10"]
hardening_profile: standard
```

## 4. Secret handling rules

| Secret | Rule |
|--------|------|
| Initial host password | Prompted at runtime (`--ask-pass`). Never on disk, in git or in logs. Used once, then dropped. |
| Admin sudo password (if `sudo_mode=password`) | Generated (20+ chars) or entered, shown once; only the hash is stored, in Vault. |
| SSH private key | Never read or copied. Connections use `ssh-agent` or a local path. |
| Vault passphrase | Known only to the user, prompted at runtime when Vault is used. |
| Logs | Tasks that touch secrets are marked `no_log`, so nothing leaks into the output. |

Why the initial password need not be stored: it is used only once, in Play 1, to
create the admin and deploy its key. Right after, hardening disables password auth,
so the secret becomes useless. Storing it would add risk with no benefit.

## 5. The init wizard

The user writes no YAML: the wizard asks the questions and generates the file.
Where `whiptail` is present the menus are graphical; otherwise a plain text prompt
is used.

```
$ castellan init 203.0.113.42

  [ Initial connection ]
  Connection mode           root + password
  Initial user              root
  Current SSH port          22

  [ Admin user to create ]
  Admin name                lucas
  Public key to deploy      ~/.ssh/id_ed25519.pub   (detected)
  Passwordless sudo         yes (recommended, key only)

  [ Hardening ]
  Profile                   standard
  New SSH port              2222
  Ports to open (firewall)  80, 443
  Your IP (never banned)    198.51.100.10   (detected)

  Config written: inventory/host_vars/203.0.113.42.yml
  No secret written to disk.
  The initial password will be requested when running apply.

$ castellan apply 203.0.113.42 --ask-pass
  Initial password (root@203.0.113.42): ********   (not stored)
  hardening in progress...
```

Fields the wizard can auto-detect for convenience:

| Field | Detection |
|-------|-----------|
| `admin_pubkey_file` | Scans `~/.ssh/*.pub` and proposes the key found |
| `f2b_ignoreip` | Detects the control machine's public IP |
| `admin_user` | Proposes the local username |

After `init`, refine the selection at any time with `castellan configure <host>`,
which lists every role and lets you tick individual measures or a whole role.

## 6. Input validation

Castellan checks the configuration before acting, to avoid errors and lockout.

| Check | Why |
|-------|-----|
| The public key exists and is valid | Otherwise the admin is created with no access (lockout) |
| `f2b_ignoreip` contains your IP | Otherwise a self-ban is possible |
| The target SSH port is among the allowed ufw ports | Anti-lockout consistency |
| Valid IP and port format | Avoids failures mid-run |
| `connection_mode` matches the provided secrets | password versus key |
| Initial connectivity tested | Network failure caught early |

## 7. Summary: who provides what

| The user provides | How | It becomes |
|-------------------|-----|------------|
| IP, admin user, ports, profile | init wizard | `host_vars/<host>.yml` (plaintext, git-safe) |
| Their public key | path (auto-detected) | deployed from `files/public_keys/` |
| The initial password | prompt at apply | nothing (memory, then forgotten) |
| Sudo password (if chosen) | generated or prompt | hash in `vault.yml` (encrypted) |
| Their private key | - | stays on their machine (ssh-agent) |

The user fills in their details once, edits no file by hand, and no plaintext
secret ever lands on disk or in git.
