# Référentiel de durcissement — Serveur Linux (Ubuntu / Debian)

> Document de référence listant **toutes les mesures de sécurité** à appliquer sur un VPS
> Ubuntu/Debian fraîchement provisionné. Sert de cahier des charges pour l'outil d'audit
> + correction automatisé.
>
> **Cibles** : Ubuntu 22.04/24.04 LTS, Debian 11/12.
> **Sources de référence** : CIS Benchmarks, ANSSI (guide hardening Linux), STIG DISA,
> `devsec.hardening`, Lynis.

## Légende des priorités

| Niveau | Sens |
|--------|------|
| 🔴 **CRITIQUE** | Indispensable. Une faille ici = compromission directe. |
| 🟠 **IMPORTANT** | Fortement recommandé. Réduit nettement la surface d'attaque. |
| 🟡 **RECOMMANDÉ** | Bonne pratique. Défense en profondeur. |
| 🔵 **OPTIONNEL** | Selon usage. Peut gêner certains workloads. |

## ⚠️ Règles d'or anti-lockout (à respecter par l'outil)

Avant toute application, l'outil **DOIT** garantir cet ordre, sinon risque de se verrouiller hors du serveur :

1. Créer l'utilisateur admin non-root **et** déployer sa clé SSH.
2. Vérifier que `sudo` fonctionne pour ce user.
3. **Tester une vraie reconnexion** via le nouvel user + clé (et nouveau port) **avant** de couper l'accès root / mot de passe.
4. Ouvrir le **nouveau port SSH dans le firewall AVANT** d'activer le firewall ou de changer le port.
5. Ne redémarrer `sshd` qu'**en fin de séquence**, jamais au milieu.
6. Conserver un backup horodaté de **chaque** fichier modifié + un mode `rollback`.
7. Toujours proposer un mode `--check` (audit à blanc, lecture seule) avant `apply`.

---

## Table des matières

1. [Comptes & authentification](#1-comptes--authentification)
2. [SSH](#2-ssh)
3. [Authentification forte (MFA / 2FA)](#3-authentification-forte-mfa--2fa)
4. [Firewall (ufw)](#4-firewall-ufw)
5. [Prévention d'intrusion (Fail2ban)](#5-prévention-dintrusion-fail2ban)
6. [Mises à jour & gestion des correctifs](#6-mises-à-jour--gestion-des-correctifs)
7. [Durcissement noyau (sysctl)](#7-durcissement-noyau-sysctl)
8. [Confinement & isolation](#8-confinement--isolation)
9. [Système de fichiers & montages](#9-système-de-fichiers--montages)
10. [Minimisation des services & paquets](#10-minimisation-des-services--paquets)
11. [Audit & journalisation](#11-audit--journalisation)
12. [Intégrité fichiers & anti-malware](#12-intégrité-fichiers--anti-malware)
13. [Politique de mots de passe & PAM](#13-politique-de-mots-de-passe--pam)
14. [Réseau](#14-réseau)
15. [Démarrage & GRUB](#15-démarrage--grub)
16. [Cron & tâches planifiées](#16-cron--tâches-planifiées)
17. [Sauvegardes](#17-sauvegardes)
18. [Conformité & supervision continue](#18-conformité--supervision-continue)

---

## 1. Comptes & authentification

| # | Mesure | Prio | Détail / valeur cible |
|---|--------|------|------------------------|
| 1.1 | Créer un utilisateur admin non-root | 🔴 | Avec groupe `sudo`. Toute administration passe par lui. |
| 1.2 | Désactiver la connexion directe `root` | 🔴 | Verrouiller le compte (`passwd -l root`) une fois l'admin validé. |
| 1.3 | `sudo` au lieu de root permanent | 🔴 | Pas de session root persistante. |
| 1.4 | Exiger un mot de passe pour `sudo` | 🟠 | Éviter `NOPASSWD` sauf comptes automation dédiés. |
| 1.5 | Journaliser toutes les commandes sudo | 🟠 | `Defaults logfile=/var/log/sudo.log` + I/O logging. |
| 1.6 | Aucun compte (hors root) avec UID 0 | 🔴 | Vérifier `/etc/passwd` : un seul UID 0. |
| 1.7 | Aucun compte sans mot de passe | 🔴 | Vérifier champ vide dans `/etc/shadow`. |
| 1.8 | Verrouiller les comptes système / shell `nologin` | 🟠 | Comptes de service → `/usr/sbin/nologin`. |
| 1.9 | Expiration / rotation des mots de passe | 🟡 | `PASS_MAX_DAYS 90`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 7`. |
| 1.10 | `umask` par défaut restrictif | 🟡 | `027` (ou `077`) dans `/etc/login.defs` & profils shell. |
| 1.11 | Timeout d'inactivité des sessions shell | 🟡 | `TMOUT=900` (déconnexion auto après 15 min). |
| 1.12 | Restreindre `su` au groupe `wheel`/`sudo` | 🟡 | Via `pam_wheel.so` dans `/etc/pam.d/su`. |
| 1.13 | Supprimer comptes/groupes inutilisés | 🟡 | `games`, `news`, etc. selon usage. |
| 1.14 | Limiter le nombre de sessions concurrentes | 🔵 | `limits.conf` `maxlogins`. |

---

## 2. SSH

> Fichier : `/etc/ssh/sshd_config` (+ `/etc/ssh/sshd_config.d/*.conf`).
> **Tester `sshd -t` avant tout reload.**

| # | Mesure | Prio | Valeur cible |
|---|--------|------|--------------|
| 2.1 | Authentification par clé uniquement | 🔴 | `PasswordAuthentication no`, `PubkeyAuthentication yes` |
| 2.2 | Interdire le login root | 🔴 | `PermitRootLogin no` |
| 2.3 | Désactiver l'auth par mot de passe vide | 🔴 | `PermitEmptyPasswords no` |
| 2.4 | Désactiver l'auth par clavier/challenge | 🟠 | `KbdInteractiveAuthentication no`, `ChallengeResponseAuthentication no` |
| 2.5 | Restreindre les utilisateurs/groupes autorisés | 🟠 | `AllowUsers` / `AllowGroups ssh-users` |
| 2.6 | Changer le port (réduit le bruit, pas une vraie sécu) | 🔵 | `Port 2222` (ouvrir dans ufw AVANT !) |
| 2.7 | Limiter les tentatives & sessions | 🟠 | `MaxAuthTries 3`, `MaxSessions 4`, `LoginGraceTime 30` |
| 2.8 | Désactiver le X11 forwarding | 🟡 | `X11Forwarding no` |
| 2.9 | Désactiver l'agent/TCP forwarding si inutile | 🟡 | `AllowAgentForwarding no`, `AllowTcpForwarding no` |
| 2.10 | Désactiver `.rhosts` & host-based auth | 🟠 | `IgnoreRhosts yes`, `HostbasedAuthentication no` |
| 2.11 | Crypto forte uniquement | 🟠 | KEX, ciphers (`chacha20-poly1305`, `aes256-gcm`), MACs ETM, désactiver algos faibles |
| 2.12 | Désactiver les algos de clé d'hôte faibles | 🟠 | Pas de DSA/clés < 2048 bits ; privilégier Ed25519 |
| 2.13 | Keepalive / déconnexion des sessions mortes | 🟡 | `ClientAliveInterval 300`, `ClientAliveCountMax 2` |
| 2.14 | Bannière légale d'avertissement | 🔵 | `Banner /etc/issue.net` |
| 2.15 | Désactiver `PermitUserEnvironment` | 🟡 | `PermitUserEnvironment no` |
| 2.16 | Mode strict des permissions | 🟡 | `StrictModes yes` |
| 2.17 | Limiter le SSH à IPv4/écoute spécifique | 🔵 | `AddressFamily inet`, `ListenAddress` si pertinent |
| 2.18 | Régénérer / durcir les clés d'hôte | 🟡 | Ed25519 + RSA 4096 ; supprimer clés faibles |
| 2.19 | Permissions strictes sur clés & config | 🔴 | `sshd_config` 600 root, `~/.ssh` 700, `authorized_keys` 600 |
| 2.20 | Désactiver DNS reverse lookup (perf) | 🔵 | `UseDNS no` |

---

## 3. Authentification forte (MFA / 2FA)

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 3.1 | 2FA TOTP sur SSH | 🟡 | `libpam-google-authenticator` + PAM, en complément de la clé. |
| 3.2 | Clés matérielles FIDO2/U2F | 🔵 | `sk-ed25519` (YubiKey) pour comptes sensibles. |
| 3.3 | Passphrase obligatoire sur les clés privées | 🟡 | Côté client (politique). |
| 3.4 | Forcer clé **+** 2FA | 🔵 | `AuthenticationMethods publickey,keyboard-interactive`. |

---

## 4. Firewall (ufw)

> Choix retenu : **ufw**. Politique par défaut « tout bloquer en entrée ».

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 4.1 | Politique par défaut : deny incoming | 🔴 | `ufw default deny incoming` |
| 4.2 | Politique par défaut : allow outgoing | 🟠 | `ufw default allow outgoing` (durcir si besoin de filtrage sortant) |
| 4.3 | Autoriser le port SSH **avant** d'activer | 🔴 | `ufw allow <port>/tcp` AVANT `ufw enable` |
| 4.4 | Limiter le débit sur SSH (anti-bruteforce) | 🟠 | `ufw limit <port>/tcp` |
| 4.5 | N'ouvrir QUE les ports réellement utilisés | 🔴 | 80/443 si web, etc. Principe du moindre privilège. |
| 4.6 | Activer la journalisation du firewall | 🟡 | `ufw logging on` (`low`/`medium`) |
| 4.7 | Bloquer les paquets invalides / spoofés | 🟡 | Règles `before.rules`, anti-spoofing |
| 4.8 | Filtrage IPv6 cohérent avec IPv4 | 🟠 | `IPV6=yes` dans `/etc/default/ufw` |
| 4.9 | Limiter ICMP si non nécessaire | 🔵 | Réduire les réponses echo/timestamp |
| 4.10 | Restreindre l'accès admin par IP source | 🟡 | `ufw allow from <IP> to any port <ssh>` (si IP fixe) |

---

## 5. Prévention d'intrusion (Fail2ban)

> Config dans `/etc/fail2ban/jail.local` (jamais éditer `jail.conf`).

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 5.1 | Installer + activer Fail2ban | 🟠 | Service `enabled` + `started` |
| 5.2 | Jail SSH actif | 🟠 | `[sshd] enabled = true` (sur le bon port) |
| 5.3 | Seuil de bannissement | 🟠 | `maxretry = 3`, `findtime = 10m` |
| 5.4 | Durée de ban progressive | 🟡 | `bantime = 1h`, `bantime.increment = true` |
| 5.5 | Backend systemd/journald | 🟡 | `backend = systemd` |
| 5.6 | Liste blanche IP de confiance | 🟠 | `ignoreip` (IP perso, LAN) — éviter de se bannir soi-même |
| 5.7 | Action via le firewall | 🟡 | `banaction = ufw` (cohérent avec le choix ufw) |
| 5.8 | Jails additionnels selon services | 🔵 | `recidive`, nginx/apache auth, etc. |
| 5.9 | Notification des bans | 🔵 | E-mail / webhook (optionnel) |

---

## 6. Mises à jour & gestion des correctifs

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 6.1 | Appliquer toutes les MAJ à l'arrivée | 🔴 | `apt update && apt full-upgrade` |
| 6.2 | Mises à jour de sécurité automatiques | 🔴 | `unattended-upgrades` activé |
| 6.3 | Configurer les origines (sécurité only) | 🟠 | `50unattended-upgrades` : security pocket |
| 6.4 | Redémarrage auto si requis (kernel) | 🟡 | `Automatic-Reboot` + fenêtre horaire (`02:00`) |
| 6.5 | Nettoyage auto des paquets obsolètes | 🟡 | `Remove-Unused-Dependencies "true"` |
| 6.6 | Vérifier l'authenticité des paquets | 🟠 | GPG des dépôts ; pas de dépôt non signé |
| 6.7 | Supprimer les dépôts tiers non maîtrisés | 🟡 | Auditer `/etc/apt/sources.list.d/` |
| 6.8 | Alerte sur MAJ en attente | 🔵 | `apticron` / monitoring |

---

## 7. Durcissement noyau (sysctl)

> Fichier : `/etc/sysctl.d/99-hardening.conf`. `sysctl --system` pour appliquer.

| # | Domaine | Prio | Paramètres cibles |
|---|---------|------|-------------------|
| 7.1 | Anti-spoofing / reverse path | 🟠 | `net.ipv4.conf.all.rp_filter=1` |
| 7.2 | Ignorer les redirections ICMP | 🟠 | `accept_redirects=0`, `send_redirects=0` |
| 7.3 | Ignorer le source routing | 🟠 | `accept_source_route=0` |
| 7.4 | Protection SYN flood | 🟠 | `tcp_syncookies=1` |
| 7.5 | Ignorer broadcast ICMP | 🟡 | `icmp_echo_ignore_broadcasts=1` |
| 7.6 | Logger les paquets martiens | 🟡 | `log_martians=1` |
| 7.7 | Désactiver IP forwarding (si pas routeur) | 🟠 | `net.ipv4.ip_forward=0` |
| 7.8 | Durcir IPv6 (RA, redirections) | 🟡 | `accept_ra=0`, `accept_redirects=0` |
| 7.9 | ASLR au maximum | 🟠 | `kernel.randomize_va_space=2` |
| 7.10 | Restreindre `dmesg` | 🟡 | `kernel.dmesg_restrict=1` |
| 7.11 | Restreindre les pointeurs kernel | 🟡 | `kernel.kptr_restrict=2` |
| 7.12 | Restreindre ptrace | 🟡 | `kernel.yama.ptrace_scope=1` (ou 2) |
| 7.13 | Restreindre BPF non privilégié | 🟡 | `kernel.unprivileged_bpf_disabled=1` |
| 7.14 | Restreindre `perf_event` | 🔵 | `kernel.perf_event_paranoid=3` |
| 7.15 | Désactiver les core dumps SUID | 🟡 | `fs.suid_dumpable=0` |
| 7.16 | Protection liens durs/symboliques | 🟡 | `fs.protected_hardlinks=1`, `fs.protected_symlinks=1` |
| 7.17 | Protection fifos/regular en /tmp | 🟡 | `fs.protected_fifos=2`, `fs.protected_regular=2` |
| 7.18 | Restreindre le chargement de modules | 🔵 | `kernel.modules_disabled=1` (en dernier, irréversible à chaud) |

---

## 8. Confinement & isolation

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 8.1 | AppArmor activé & en mode enforce | 🟠 | `aa-status` ; profils en `enforce` plutôt que `complain` |
| 8.2 | Charger les profils AppArmor au boot | 🟠 | Service `apparmor` activé |
| 8.3 | Durcir les unités systemd des services | 🟡 | `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `NoNewPrivileges=true`, `ProtectKernelModules=true`, `RestrictSUIDSGID=true`, `SystemCallFilter` |
| 8.4 | Isoler les services réseau exposés | 🟡 | `PrivateDevices`, `RestrictAddressFamilies`, `IPAddressDeny` |
| 8.5 | Désactiver les namespaces user non privilégiés | 🔵 | `kernel.unprivileged_userns_clone=0` (attention si conteneurs rootless) |
| 8.6 | Conteneurisation des apps exposées | 🔵 | Docker/Podman avec profils seccomp + user namespaces |
| 8.7 | seccomp pour les services critiques | 🔵 | Filtrage des appels système |
| 8.8 | Désactiver le chargement de modules de FS rares | 🟡 | `cramfs`, `freevxfs`, `jffs2`, `hfs`, `udf`… via `modprobe` blacklist |
| 8.9 | SELinux (alternative à AppArmor) | 🔵 | Sur certains setups Debian ; sinon AppArmor par défaut |

---

## 9. Système de fichiers & montages

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 9.1 | `/tmp` séparé avec `noexec,nosuid,nodev` | 🟡 | Via `tmpfs` ou partition dédiée |
| 9.2 | `/var/tmp`, `/dev/shm` durcis | 🟡 | `noexec,nosuid,nodev` |
| 9.3 | `/home` en `nosuid,nodev` | 🔵 | Selon partitionnement |
| 9.4 | Auditer les binaires SUID/SGID | 🟠 | Lister, retirer le bit sur les non nécessaires |
| 9.5 | Aucun fichier world-writable sans sticky bit | 🟠 | Recherche `find / -perm -0002` |
| 9.6 | Aucun fichier sans propriétaire | 🟡 | `find / -nouser -o -nogroup` |
| 9.7 | Permissions strictes fichiers sensibles | 🔴 | `/etc/shadow` 640/600, `/etc/passwd` 644, `/etc/gshadow`, clés |
| 9.8 | Chiffrement du disque/volumes | 🔵 | LUKS si données sensibles (souvent fait à l'install) |
| 9.9 | Désactiver l'automontage USB | 🔵 | Si console physique exposée |
| 9.10 | Quotas disque | 🔵 | Anti-DoS par saturation |

---

## 10. Minimisation des services & paquets

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 10.1 | Désinstaller les services réseau inutiles | 🟠 | `telnet`, `rsh`, `ftp`, `nis`, `talk`, serveurs X inutiles |
| 10.2 | Désactiver les services non utilisés | 🟠 | `systemctl disable` (CUPS, avahi, bluetooth…) |
| 10.3 | Auditer les ports en écoute | 🟠 | `ss -tulpn` : tout port ouvert doit être justifié |
| 10.4 | Pas de serveur mail en écoute publique | 🟡 | Postfix/exim en `loopback-only` si MTA local |
| 10.5 | Retirer compilateurs/outils dev en prod | 🔵 | Réduit les outils d'un attaquant |
| 10.6 | Désactiver IPv6 si non utilisé | 🔵 | Sinon le durcir (cf. §7) |
| 10.7 | Nettoyer paquets orphelins | 🟡 | `apt autoremove --purge` |

---

## 11. Audit & journalisation

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 11.1 | Installer & activer `auditd` | 🟠 | Traçabilité des événements système |
| 11.2 | Règles d'audit (CIS) | 🟡 | Accès `/etc/passwd`, `/etc/shadow`, sudoers, modules, time-change, logins |
| 11.3 | Rendre les règles immuables | 🔵 | `-e 2` (jusqu'au reboot) |
| 11.4 | Persistance des logs journald | 🟠 | `Storage=persistent`, `/var/log/journal` |
| 11.5 | Limiter la taille / rotation des logs | 🟡 | `SystemMaxUse`, `logrotate` configuré |
| 11.6 | Centraliser les logs (syslog distant) | 🔵 | rsyslog/journald → SIEM, si dispo |
| 11.7 | Permissions strictes sur `/var/log` | 🟡 | Pas de logs world-readable sensibles |
| 11.8 | Journaliser les connexions (wtmp/btmp/lastlog) | 🟡 | Vérifier l'activation |
| 11.9 | Horodatage fiable (cf. NTP) | 🟠 | Logs inutiles si l'heure dérive |
| 11.10 | Surveillance des fichiers de log clés | 🔵 | Alerting sur `auth.log`, `fail2ban.log` |

---

## 12. Intégrité fichiers & anti-malware

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 12.1 | AIDE (intégrité fichiers) | 🟡 | Base de référence + vérif planifiée |
| 12.2 | Initialiser la base AIDE après hardening | 🟡 | Snapshot de l'état « sain » |
| 12.3 | `rkhunter` / `chkrootkit` | 🔵 | Détection rootkits, scan périodique |
| 12.4 | ClamAV | 🔵 | Si le serveur reçoit/traite des fichiers externes |
| 12.5 | Vérification des paquets installés | 🟡 | `debsums` : détecter des binaires modifiés |
| 12.6 | Alerte sur changement de fichiers critiques | 🔵 | `/etc`, binaires SUID, clés SSH |

---

## 13. Politique de mots de passe & PAM

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 13.1 | Complexité des mots de passe | 🟠 | `pam_pwquality` : `minlen=14`, `dcredit`, `ucredit`, `ocredit`, `lcredit` |
| 13.2 | Algo de hash fort | 🟠 | `yescrypt` ou `sha512` + rounds élevés |
| 13.3 | Historique des mots de passe | 🟡 | `pam_pwhistory remember=5` |
| 13.4 | Verrouillage après échecs | 🟠 | `pam_faillock` : `deny=5`, `unlock_time=900` |
| 13.5 | Délai entre tentatives | 🟡 | `pam_faildelay` |
| 13.6 | Interdire la réutilisation immédiate | 🟡 | Cf. pwhistory |
| 13.7 | Cohérence avec `/etc/login.defs` | 🟡 | Âge mini/maxi, warn age |

---

## 14. Réseau

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 14.1 | DNS de confiance | 🟡 | Résolveurs maîtrisés ; DNSSEC si possible |
| 14.2 | Synchronisation horaire (NTP) | 🟠 | `systemd-timesyncd` ou `chrony` actif & sain |
| 14.3 | Désactiver les protocoles réseau rares | 🟡 | `dccp`, `sctp`, `rds`, `tipc` via modprobe blacklist |
| 14.4 | Désactiver le wireless si présent | 🔵 | `rfkill` / nmcli (rare sur VPS) |
| 14.5 | TCP wrappers / hosts.allow-deny | 🔵 | Filtrage applicatif complémentaire |
| 14.6 | Bannière réseau pré-login | 🔵 | `/etc/issue.net` |
| 14.7 | Filtrage sortant (egress) | 🔵 | Limiter les connexions sortantes des services |
| 14.8 | Protection contre IP spoofing | 🟡 | Cf. sysctl rp_filter |

---

## 15. Démarrage & GRUB

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 15.1 | Mot de passe GRUB | 🔵 | Empêche l'édition des paramètres de boot (utile si console exposée) |
| 15.2 | Permissions strictes `grub.cfg` | 🟡 | 600 root |
| 15.3 | Désactiver le boot sur média externe | 🔵 | BIOS/console — selon accès physique |
| 15.4 | Paramètres kernel de sécurité | 🔵 | `slab_nomerge`, `init_on_alloc=1`, `mitigations` selon CPU |
| 15.5 | Désactiver Ctrl-Alt-Suppr (reboot) | 🔵 | `systemctl mask ctrl-alt-del.target` |

> Sur un VPS, l'accès console étant géré par l'hébergeur, ces points sont souvent 🔵.

---

## 16. Cron & tâches planifiées

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 16.1 | Restreindre l'accès à cron/at | 🟡 | `cron.allow` / `at.allow` (whitelist root + admin) |
| 16.2 | Permissions sur crontabs | 🟡 | `/etc/crontab`, `/etc/cron.*` en 600/700 root |
| 16.3 | Auditer les tâches planifiées existantes | 🟠 | Détecter une persistance malveillante |
| 16.4 | Désactiver les timers systemd inutiles | 🔵 | `systemctl list-timers` |

---

## 17. Sauvegardes

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 17.1 | Sauvegarde de la config avant hardening | 🔴 | **L'outil DOIT** backuper chaque fichier modifié (rollback). |
| 17.2 | Stratégie de backup des données | 🟠 | Hors site, chiffrée, testée (3-2-1) |
| 17.3 | Chiffrement des sauvegardes | 🟠 | GPG / outil de backup chiffré |
| 17.4 | Test de restauration | 🟡 | Un backup non testé = pas de backup |
| 17.5 | Snapshot VPS avant exécution | 🟡 | Si l'hébergeur le permet (filet de sécurité) |

---

## 18. Conformité & supervision continue

| # | Mesure | Prio | Détail |
|---|--------|------|--------|
| 18.1 | Scan Lynis post-hardening | 🟠 | Mesurer le « hardening index », viser > 85 |
| 18.2 | Re-audit périodique | 🟡 | Détecter les dérives de configuration |
| 18.3 | Rapport d'audit horodaté | 🟠 | Avant/après, diff des changements |
| 18.4 | Surveillance des services critiques | 🟡 | sshd, fail2ban, ufw, auditd toujours actifs |
| 18.5 | Alerting sur événements de sécu | 🔵 | Logins root, nouveaux users, ports ouverts |
| 18.6 | Documentation de l'état appliqué | 🟡 | Versionner la config de durcissement |

---

## Récapitulatif des catégories pour l'outil

| Module | Catégorie | Phase audit | Phase apply | Risque lockout |
|--------|-----------|:-----------:|:-----------:|:--------------:|
| `accounts` | Comptes & auth | ✅ | ✅ | ⚠️ moyen |
| `ssh` | SSH | ✅ | ✅ | 🔴 élevé |
| `mfa` | MFA / 2FA | ✅ | ✅ | ⚠️ moyen |
| `firewall` | ufw | ✅ | ✅ | 🔴 élevé |
| `fail2ban` | Anti-bruteforce | ✅ | ✅ | ⚠️ moyen (self-ban) |
| `updates` | Patch management | ✅ | ✅ | — |
| `sysctl` | Noyau | ✅ | ✅ | faible |
| `confinement` | AppArmor/systemd | ✅ | ✅ | faible |
| `filesystem` | FS & montages | ✅ | ✅ | faible |
| `services` | Minimisation | ✅ | ✅ | ⚠️ moyen |
| `audit` | auditd/logs | ✅ | ✅ | — |
| `integrity` | AIDE/rkhunter | ✅ | ✅ | — |
| `pam` | Mots de passe | ✅ | ✅ | ⚠️ moyen |
| `network` | Réseau/NTP | ✅ | ✅ | faible |
| `boot` | GRUB | ✅ | ✅ | faible |
| `cron` | Tâches planifiées | ✅ | ✅ | — |
| `backup` | Sauvegardes | ✅ | ✅ | — |
| `compliance` | Lynis/reporting | ✅ | — | — |

---

## Note importante sur le « 100 % sécurisé »

La sécurité **absolue n'existe pas** : ce référentiel vise à **réduire au maximum la surface
d'attaque** et à appliquer l'état de l'art (CIS / ANSSI). Quelques principes à garder en tête :

- **Défense en profondeur** : aucune mesure n'est suffisante seule ; c'est l'empilement qui protège.
- **Moindre privilège** : n'ouvrir/activer que le strict nécessaire.
- **Réversibilité** : tout changement doit être backupé et annulable.
- **Idempotence** : ré-exécuter l'outil doit être sans danger.
- **Contexte** : certaines mesures (🔵) dépendent de l'usage du serveur (web, BDD, conteneurs…).
- **Maintien dans le temps** : un serveur durci une fois dérive ; le re-audit est essentiel.
