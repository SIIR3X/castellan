# Architecture — Outil de durcissement VPS (Ansible)

> Document de conception. Décrit la structure du projet, le découpage en rôles, le flux
> d'exécution anti-lockout et l'expérience d'utilisation. **Aucun code ici** : c'est le
> plan qui guidera l'implémentation. Référence fonctionnelle : [`SECURITY-MEASURES.md`](./SECURITY-MEASURES.md).

---

## 1. Principes directeurs

| Principe | Conséquence sur l'architecture |
|----------|-------------------------------|
| **Agentless** | Aucune installation sur le VPS. Tout passe par SSH depuis la machine de contrôle. Seul Python (déjà présent) est requis sur la cible. |
| **Deux phases séparées** | `audit` (lecture seule, `--check`) puis `apply` (modifie). Jamais d'`apply` sans audit préalable possible. |
| **Anti-lockout** | Ordre d'exécution strict ; vérification de reconnexion avant de couper les accès. |
| **Idempotence** | Rejouer le playbook 1 ou 50 fois = même résultat, sans danger. |
| **Réversibilité** | Backup horodaté de chaque fichier modifié + procédure de rollback. |
| **Modularité** | 1 catégorie de sécurité = 1 rôle = activable/désactivable indépendamment. |
| **Connexion variable** | Supporte root+password, root+clé, ou user+sudo selon l'hébergeur. |

---

## 2. Arborescence du projet

```
vps-hardening/
├── harden                          # Wrapper CLI (script) : ./harden audit|apply|rollback <hôte>
├── ansible.cfg                     # Config Ansible (SSH, pipelining, retry, callback)
├── README.md
│
├── inventory/
│   ├── hosts.yml                   # Liste des VPS (groupes, IP)
│   └── host_vars/
│       └── <ip>.yml                # Paramètres spécifiques par VPS (port, user…)
│
├── group_vars/
│   ├── all.yml                     # Config globale (valeurs par défaut du durcissement)
│   └── vault.yml                   # Secrets chiffrés (Ansible Vault) : mots de passe init
│
├── playbooks/
│   ├── site.yml                    # Playbook maître (orchestration des plays)
│   ├── 00-bootstrap.yml            # Play 1 : connexion initiale, création admin + clé
│   ├── 01-verify-access.yml        # Play 2 : test reconnexion via nouvel accès (garde-fou)
│   ├── 10-harden.yml               # Play 3 : applique tous les rôles de durcissement
│   └── 99-report.yml               # Play 4 : audit Lynis + rapport final
│
├── roles/
│   ├── accounts/                   # §1  Comptes & sudo
│   ├── ssh/                        # §2  Durcissement sshd
│   ├── mfa/                        # §3  2FA TOTP (optionnel)
│   ├── firewall/                   # §4  ufw
│   ├── fail2ban/                   # §5  Anti-bruteforce
│   ├── updates/                    # §6  unattended-upgrades
│   ├── sysctl/                     # §7  Durcissement noyau
│   ├── confinement/                # §8  AppArmor + sandboxing systemd
│   ├── filesystem/                 # §9  Montages, SUID, permissions
│   ├── services/                   # §10 Minimisation services/paquets
│   ├── audit_logging/              # §11 auditd + journald
│   ├── integrity/                  # §12 AIDE / rkhunter
│   ├── pam/                        # §13 Politique mots de passe
│   ├── network/                    # §14 NTP, protocoles, DNS
│   ├── boot/                       # §15 GRUB
│   ├── cron/                       # §16 Restriction tâches planifiées
│   ├── backup_config/              # §17 Backup pré-changement (transverse)
│   └── compliance/                 # §18 Lynis + reporting
│
├── reports/                        # Rapports générés (audit/diff/Lynis), horodatés
│   └── <ip>_<date>/
│
└── files/
    └── public_keys/                # Clés publiques à déployer
```

### Anatomie d'un rôle (modèle commun)

```
roles/ssh/
├── defaults/main.yml      # Variables par défaut (port, options, valeurs cibles)
├── tasks/
│   ├── main.yml           # Aiguille vers audit.yml ou apply.yml
│   ├── audit.yml          # Contrôles lecture seule → collecte des écarts
│   └── apply.yml          # Correctifs (avec backup préalable)
├── handlers/main.yml      # ex. "reload sshd" (déclenché en fin de play)
├── templates/
│   └── sshd_hardening.conf.j2
└── meta/main.yml          # Dépendances éventuelles (ex. backup_config)
```

Ce gabarit est **identique pour les 18 rôles** : c'est ce qui rend l'ensemble cohérent et maintenable.

---

## 3. Flux d'exécution (orchestration anti-lockout)

`site.yml` enchaîne 4 plays. Le séquencement est le cœur de la sûreté.

```
┌─────────────────────────────────────────────────────────────────┐
│  PLAY 1 — BOOTSTRAP      (connexion : credentials INITIAUX)        │
│  rôles : accounts, backup_config                                  │
│   • Met à jour le cache apt                                       │
│   • Crée l'utilisateur admin + groupe sudo                        │
│   • Déploie la clé publique SSH                                   │
│   • Configure sudo                                                │
│   • NE TOUCHE PAS ENCORE à sshd                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  PLAY 2 — VERIFY ACCESS  (connexion : NOUVEL admin + clé)          │
│   • Tente une connexion réelle avec le nouvel utilisateur          │
│   • Vérifie que sudo fonctionne                                    │
│   • ÉCHEC ICI  →  ARRÊT, accès root toujours intact (pas de lock)  │
│   • SUCCÈS     →  feu vert pour durcir                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  PLAY 3 — HARDEN         (connexion : NOUVEL admin + sudo)         │
│  Ordre IMPÉRATIF des rôles :                                      │
│   1. firewall   → ouvrir le port SSH AVANT enable ufw             │
│   2. fail2ban   → ignoreip = ton IP (pas d'auto-ban)              │
│   3. ssh        → désactive root/password, change port            │
│      (handler "reload sshd" différé en fin de play)               │
│   4. sysctl, pam, confinement, filesystem, services,             │
│      audit_logging, integrity, network, cron, boot, updates       │
│   5. FLUSH des handlers → reload sshd UNE SEULE FOIS, à la fin     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  PLAY 4 — REPORT                                                  │
│   • Lance Lynis, récupère le hardening index                      │
│   • Génère le rapport (avant/après, diff, écarts restants)        │
│   • Rapatrie dans reports/<ip>_<date>/                            │
└─────────────────────────────────────────────────────────────────┘
```

### Pourquoi cet ordre

- **Firewall avant SSH** : le nouveau port doit être ouvert avant qu'on l'active dans sshd, sinon lockout.
- **Fail2ban avant SSH** : `ignoreip` configuré avant que les bans ne puissent te toucher.
- **SSH (reload) en dernier** : via un *handler* déclenché par `meta: flush_handlers` à la toute fin, jamais au milieu.
- **Play 2 = garde-fou** : si la nouvelle connexion ne marche pas, on s'arrête **avant** d'avoir rien cassé.

---

## 4. Mode AUDIT vs mode APPLY

Un seul code, deux comportements, pilotés par une variable `mode`.

| Aspect | `audit` | `apply` |
|--------|---------|---------|
| Invocation | `./harden audit <hôte>` | `./harden apply <hôte>` |
| Sous le capot | `ansible-playbook ... --check --diff` + `mode=audit` | exécution réelle, `mode=apply` |
| Effet sur le VPS | **Aucun** (lecture seule) | Modifie la config |
| Sortie | Liste des écarts par mesure (conforme / non conforme) | Liste des changements appliqués + diff |
| Rôles exécutés | `tasks/audit.yml` de chaque rôle | `tasks/apply.yml` (backup → modif) |

Chaque rôle expose donc **deux chemins** (`audit.yml` / `apply.yml`) sélectionnés par `mode`.
Le mode audit alimente un **rapport de conformité** mappé sur les identifiants de
`SECURITY-MEASURES.md` (ex. `2.1 ✅`, `7.9 ❌ attendu=2 trouvé=0`).

---

## 5. Configuration centralisée (`group_vars/all.yml`)

Toute la personnalisation se fait **ici**, sans toucher au code des rôles. Forme attendue :

| Bloc | Variables clés (exemples) |
|------|---------------------------|
| Accès | `admin_user`, `admin_pubkey_file`, `sudo_nopasswd` |
| SSH | `ssh_port`, `ssh_permit_root`, `ssh_password_auth`, `ssh_allow_groups` |
| Firewall | `ufw_default_incoming`, `ufw_allowed_ports[]`, `ufw_rate_limit_ssh` |
| Fail2ban | `f2b_maxretry`, `f2b_bantime`, `f2b_ignoreip[]` |
| Updates | `auto_reboot`, `auto_reboot_time` |
| Activation des modules | `enable_<role>: true/false` pour chaque rôle |
| Profil | `hardening_profile: minimal \| standard \| paranoid` |

### Profils prédéfinis

Pour éviter de tout configurer à la main, 3 profils déterminent quelles mesures
(par priorité 🔴🟠🟡🔵) sont activées :

| Profil | Inclut | Usage |
|--------|--------|-------|
| `minimal` | 🔴 + 🟠 essentiels | Durcissement rapide, faible risque de casse |
| `standard` | 🔴 🟠 🟡 | **Défaut recommandé.** Bon équilibre. |
| `paranoid` | tout, y compris 🔵 | Serveurs sensibles, après validation usage |

---

## 6. Gestion de la connexion variable selon l'hébergeur

Réponse au cas « ça varie selon l'hébergeur ». La connexion **initiale** (Play 1) est
paramétrée par VPS dans `host_vars/<ip>.yml` :

| Cas hébergeur | Variables | Détail |
|---------------|-----------|--------|
| root + mot de passe | `initial_user: root` + `--ask-pass` (ou vault) | OVH, Contabo, Hetzner classique |
| root + clé | `initial_user: root`, clé déjà en place | DigitalOcean, Hetzner Cloud |
| user + sudo | `initial_user: <user>`, `become: true` | Hébergeurs avec user pré-créé |

Les plays 2 à 4 utilisent **toujours** le nouvel `admin_user` + clé + (nouveau) port.
Le wrapper `harden` détecte/demande le mode de connexion au premier contact.

---

## 7. Stratégie de backup & rollback

| Élément | Mécanisme |
|---------|-----------|
| Backup fichier | Avant chaque modif, copie horodatée (`*.bak.<timestamp>`) côté VPS + option de rapatriement local |
| Rôle transverse | `backup_config` (en dépendance `meta` des rôles qui modifient des fichiers) |
| Rollback | `./harden rollback <hôte>` restaure les `.bak` les plus récents et recharge les services |
| Filet supplémentaire | Recommandation : snapshot VPS côté hébergeur avant `apply` |

> Note : un rollback SSH/firewall reste délicat (risque de lockout inverse). Le wrapper
> conserve **toujours** une session de secours et n'agit qu'après confirmation de reconnexion.

---

## 8. Exécution sélective (tags)

Chaque rôle est taggé (`ssh`, `firewall`, `sysctl`…) pour permettre :

```
./harden apply <hôte> --only ssh,firewall      # n'applique que ces modules
./harden audit <hôte> --skip boot,integrity    # audit en excluant certains modules
```

Sous le capot : `--tags` / `--skip-tags` d'Ansible.

---

## 9. Expérience utilisateur (le wrapper `harden`)

Surcouche fine au-dessus d'`ansible-playbook` pour rendre l'usage trivial :

| Commande | Action |
|----------|--------|
| `./harden init <ip>` | Ajoute le VPS à l'inventaire, demande le mode de connexion |
| `./harden audit <ip>` | Audit lecture seule → rapport de conformité |
| `./harden apply <ip>` | Durcissement complet (avec garde-fous) |
| `./harden rollback <ip>` | Restaure la dernière sauvegarde |
| `./harden report <ip>` | Affiche/relit le dernier rapport |
| `./harden apply <ip> --profile paranoid` | Choix du profil |

Objectif final : **un nouveau VPS = `./harden init <ip>` puis `./harden apply <ip>`.**

---

## 10. Dépendances & prérequis

| Côté | Prérequis |
|------|-----------|
| Machine de contrôle | Ansible, `sshpass` (si auth par mot de passe initial), accès SSH au VPS |
| VPS cible | Python 3 (présent par défaut sur Ubuntu/Debian), accès initial fourni par l'hébergeur |
| Collections Ansible | `ansible.posix`, `community.general` (modules ufw, sysctl, etc.) |
| Optionnel | `devsec.hardening` (réutilisable pour ssh/os/sysctl si on veut s'appuyer sur du CIS prêt à l'emploi) |

---

## 11. Décisions d'architecture à trancher (avant implémentation)

Points ouverts qui orienteront le code :

1. **Rôles maison vs `devsec.hardening`** : tout réécrire (contrôle total, pédagogique) ou
   s'appuyer sur les rôles CIS existants pour ssh/os/sysctl (moins de maintenance) ?
2. **Périmètre du MVP** : commencer par `accounts + ssh + firewall + fail2ban + updates`,
   puis étendre ? (recommandé)
3. **Rapport** : format du rapport d'audit (Markdown lisible, JSON machine, ou les deux) ?
4. **Secrets** : Ansible Vault pour les mots de passe initiaux, ou saisie interactive `--ask-pass` ?
5. **Multi-VPS** : viser l'exécution sur un parc (plusieurs hôtes en parallèle) dès le départ ?
6. **Rollback SSH** : jusqu'où automatiser le rollback des modules à risque de lockout ?

---

## 12. Correspondance rôles ↔ référentiel

| Rôle | Section `SECURITY-MEASURES.md` | Risque lockout | Profil mini |
|------|:------------------------------:|:--------------:|:-----------:|
| `accounts` | §1 | ⚠️ moyen | ✅ |
| `ssh` | §2 | 🔴 élevé | ✅ |
| `mfa` | §3 | ⚠️ moyen | — |
| `firewall` | §4 | 🔴 élevé | ✅ |
| `fail2ban` | §5 | ⚠️ moyen | ✅ |
| `updates` | §6 | — | ✅ |
| `sysctl` | §7 | faible | ✅ |
| `confinement` | §8 | faible | — |
| `filesystem` | §9 | faible | partiel |
| `services` | §10 | ⚠️ moyen | partiel |
| `audit_logging` | §11 | — | — |
| `integrity` | §12 | — | — |
| `pam` | §13 | ⚠️ moyen | partiel |
| `network` | §14 | faible | ✅ |
| `boot` | §15 | faible | — |
| `cron` | §16 | — | — |
| `backup_config` | §17 (transverse) | — | ✅ |
| `compliance` | §18 | — | ✅ |
