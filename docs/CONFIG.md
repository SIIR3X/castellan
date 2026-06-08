# Configuration & gestion des entrées utilisateur

> Document de conception. Définit **tout ce que l'utilisateur doit fournir** pour utiliser
> l'outil, la **classification secret / non-secret**, où chaque donnée vit, et le déroulé de
> l'assistant `init`. **Aucun code.** Compléments : [`ARCHITECTURE.md`](./ARCHITECTURE.md),
> [`SECURITY-MEASURES.md`](./SECURITY-MEASURES.md).

---

## 1. Principe fondateur

> **Plus une donnée est secrète, moins elle doit persister.**

Toute entrée utilisateur est rangée dans l'une de ces 4 classes, traitée différemment :

| Classe | Persistance | Stockage | Versionnable (git) |
|--------|-------------|----------|:------------------:|
| **A. Config publique** | Permanente | YAML en clair | ✅ Oui |
| **B. Clé SSH publique** | Permanente | Fichier `.pub` / chemin | ✅ Oui (c'est public) |
| **C. Secret éphémère** | Aucune (mémoire seule) | Prompt à la volée | ❌ Jamais écrit |
| **D. Secret persistant** | Permanente mais chiffrée | Ansible Vault | ✅ Oui (illisible sans passphrase) |
| **E. Clé SSH privée** | — | Reste sur la machine de contrôle | ❌ Ne quitte jamais ta machine |

---

## 2. Liste exhaustive des champs à fournir

### 2.1 Connexion initiale (premier contact avec le VPS)

| Champ | Classe | Obligatoire | Description | Exemple |
|-------|:------:|:-----------:|-------------|---------|
| `target_ip` | A | ✅ | IP ou FQDN du VPS | `203.0.113.42` |
| `connection_mode` | A | ✅ | `root_password` \| `root_key` \| `user_sudo` | `root_password` |
| `initial_user` | A | ✅ | Compte de première connexion | `root` |
| `initial_password` | **C** | selon mode | Mot de passe fourni par l'hébergeur. **Usage unique, jamais stocké.** | *(prompt)* |
| `initial_key` | E | selon mode | Clé privée déjà acceptée par l'hébergeur (si `root_key`) | `~/.ssh/hoster_key` |
| `initial_port` | A | ✅ (défaut 22) | Port SSH au premier contact | `22` |

> Selon `connection_mode`, soit `initial_password` (prompt éphémère), soit `initial_key`
> (chemin local) est utilisé. Jamais les deux.

### 2.2 Identité admin à créer

| Champ | Classe | Obligatoire | Description | Défaut |
|-------|:------:|:-----------:|-------------|--------|
| `admin_user` | A | ✅ | Nom de l'utilisateur non-root à créer | — |
| `admin_pubkey_file` | B | ✅ | Chemin de la **clé publique** à déployer | `~/.ssh/id_ed25519.pub` |
| `sudo_mode` | A | ✅ | `nopasswd` (clé only) \| `password` (2e facteur) | `nopasswd` |
| `admin_password` | **D** | si `sudo_mode=password` | Mot de passe sudo. Généré aléatoirement ou saisi. **Seul le hash est stocké (Vault).** | *(généré)* |

> ⚠️ La **clé privée** correspondant à `admin_pubkey_file` n'est **jamais** demandée ni
> manipulée par l'outil : la connexion ultérieure se fait via ton `ssh-agent`.

### 2.3 Paramètres de durcissement SSH

| Champ | Classe | Description | Défaut (`standard`) |
|-------|:------:|-------------|---------------------|
| `ssh_port` | A | Nouveau port SSH | `22` (ou au choix) |
| `ssh_allow_groups` | A | Groupes autorisés à se connecter | `[ssh-users]` |
| `ssh_permit_root` | A | Login root autorisé ? | `no` |
| `ssh_password_auth` | A | Auth par mot de passe ? | `no` |

### 2.4 Paramètres firewall (ufw)

| Champ | Classe | Description | Défaut |
|-------|:------:|-------------|--------|
| `ufw_allowed_ports` | A | Liste des ports à ouvrir (hors SSH, géré auto) | `[]` |
| `ufw_rate_limit_ssh` | A | Limiter le débit sur SSH | `true` |
| `ufw_admin_source_ip` | A | Restreindre l'admin à une IP source (optionnel) | *(vide)* |

### 2.5 Paramètres Fail2ban

| Champ | Classe | Description | Défaut |
|-------|:------:|-------------|--------|
| `f2b_ignoreip` | A | IP de confiance à ne jamais bannir (**ton IP !**) | `[ton IP]` |
| `f2b_maxretry` | A | Tentatives avant ban | `3` |
| `f2b_bantime` | A | Durée du ban | `1h` |

### 2.6 Paramètres globaux

| Champ | Classe | Description | Défaut |
|-------|:------:|-------------|--------|
| `hardening_profile` | A | `minimal` \| `standard` \| `paranoid` | `standard` |
| `enable_<role>` | A | Activer/désactiver chaque module (ssh, sysctl…) | selon profil |
| `auto_reboot` | A | Redémarrage auto si MAJ kernel le requiert | `false` |
| `notify_email` | A | E-mail pour alertes (optionnel) | *(vide)* |

---

## 3. Où chaque chose est stockée

```
vps-hardening/
├── group_vars/
│   ├── all.yml          ← Classe A : valeurs par défaut globales (EN CLAIR)
│   └── vault.yml        ← Classe D : secrets persistants (CHIFFRÉ Ansible Vault)
├── inventory/
│   └── host_vars/
│       └── 203.0.113.42.yml   ← Classe A : config propre à ce VPS (EN CLAIR)
├── files/
│   └── public_keys/
│       └── id_ed25519.pub     ← Classe B : clé publique (EN CLAIR, c'est public)
│
└── (Classe C) initial_password ─── JAMAIS écrit : prompt en mémoire à l'exécution
    (Classe E) clé privée        ─── reste dans ~/.ssh + ssh-agent, hors du projet
```

### Exemple de `host_vars/203.0.113.42.yml` (en clair, versionnable)

> Forme illustrative — **aucun secret dedans** :

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

Ce fichier peut partir dans git sans aucun risque : il ne contient **que du paramétrage**.

---

## 4. Traitement des secrets — règles strictes

| Secret | Règle |
|--------|-------|
| Mot de passe initial (hébergeur) | **Prompt à l'exécution** (`--ask-pass`). Jamais sur disque, jamais dans git, jamais dans les logs. Effacé de la mémoire après usage. |
| Mot de passe sudo de l'admin (si `password`) | **Généré aléatoirement** (≥ 20 car.) **ou** saisi. Affiché **une seule fois** à l'utilisateur. Seul le **hash** est stocké, dans **Vault**. |
| Clé privée SSH | **Jamais lue, jamais copiée** par l'outil. Connexion via `ssh-agent` ou chemin local. |
| Passphrase Vault | Connue de l'utilisateur uniquement. Demandée à l'exécution si Vault est utilisé. |
| Logs | Les tâches manipulant des secrets sont marquées « no_log » → rien ne fuit dans la sortie. |

### Pourquoi le mot de passe initial n'a pas besoin d'être stocké

Il ne sert qu'**une fois** (Play 1 : créer l'admin + déployer la clé). Juste après, le
durcissement désactive l'auth par mot de passe → ce secret devient **inutile**. Le stocker
serait un risque sans bénéfice.

---

## 5. Déroulé de l'assistant `./harden init <ip>`

L'utilisateur ne rédige **aucun YAML** : l'assistant pose les questions et génère le fichier.

```
$ ./harden init 203.0.113.42

  ┌─ Connexion initiale ──────────────────────────────────────┐
  ? Mode de connexion         › root + mot de passe
  ? Utilisateur initial       › root
  ? Port SSH actuel           › 22
  └───────────────────────────────────────────────────────────┘

  ┌─ Utilisateur admin à créer ───────────────────────────────┐
  ? Nom de l'admin            › lucas
  ? Clé publique à déployer   › ~/.ssh/id_ed25519.pub   [détectée ✔]
  ? sudo sans mot de passe ?  › oui   (recommandé, clé only)
  └───────────────────────────────────────────────────────────┘

  ┌─ Durcissement ────────────────────────────────────────────┐
  ? Profil                    › standard
  ? Nouveau port SSH          › 2222
  ? Ports à ouvrir (firewall) › 80, 443
  ? Ton IP (jamais bannie)    › 198.51.100.10   [détectée ✔]
  └───────────────────────────────────────────────────────────┘

  ✔ Config écrite : inventory/host_vars/203.0.113.42.yml
  ✔ Aucun secret écrit sur disque.
  ℹ Le mot de passe initial sera demandé au lancement de « apply ».

$ ./harden apply 203.0.113.42
  ? Mot de passe initial (root@203.0.113.42) › ********   [non stocké]
  → durcissement en cours…
```

### Champs à détection automatique (confort)

| Champ | Détection proposée |
|-------|--------------------|
| `admin_pubkey_file` | Scan de `~/.ssh/*.pub`, propose la clé trouvée |
| `f2b_ignoreip` | Détection de l'IP publique de la machine de contrôle |
| `admin_user` | Propose le nom d'utilisateur local par défaut |

---

## 6. Validation des entrées (avant exécution)

L'outil **doit vérifier** avant d'agir, pour éviter les erreurs et le lockout :

| Vérification | Pourquoi |
|--------------|----------|
| La clé publique existe et est valide | Sinon admin créé sans accès → lockout |
| `f2b_ignoreip` contient bien ton IP | Sinon auto-ban possible |
| Le port SSH cible est dans les ports ufw autorisés | Cohérence anti-lockout |
| Format IP / port valides | Évite les échecs en cours d'exécution |
| `connection_mode` cohérent avec les secrets fournis | password vs key |
| Connectivité initiale testée | Échec réseau détecté tôt |

---

## 7. Récapitulatif : qui remplit quoi, et où ça finit

| L'utilisateur fournit… | Comment | Devient… |
|------------------------|---------|----------|
| IP, user admin, ports, profil | Assistant `init` | `host_vars/<ip>.yml` (clair, git-safe) |
| Sa clé **publique** | Chemin (auto-détecté) | Copiée dans `files/public_keys/` |
| Mot de passe **initial** | Prompt à `apply` | Rien (mémoire, puis oublié) |
| Mot de passe sudo (si choisi) | Généré / prompt | Hash dans `vault.yml` (chiffré) |
| Sa clé **privée** | — | Reste sur sa machine (ssh-agent) |

➡️ Résultat : l'utilisateur remplit ses infos **une fois**, sans éditer de fichier à la main,
et **aucun secret en clair** ne se retrouve sur disque ni dans git.

---

## 8. Points ouverts (à trancher avant implémentation)

1. **Assistant interactif vs fichier d'exemple** : full wizard, ou fournir un `host_vars.example.yml` à copier ? (le wizard est plus sûr pour les débutants)
2. **Format du prompt** : outil TUI (questions stylées) ou simple `read` shell ? (dépend du langage du wrapper)
3. **Vault toujours créé, ou seulement si `sudo_mode=password`** ? (éviter une passphrase inutile dans le cas clé-only)
4. **Multi-VPS** : un `host_vars` par machine (déjà prévu) ou un mode « parc » avec config partagée ?
5. **Réutilisation de config** : permettre un `defaults` commun à tous les VPS dans `group_vars/all.yml` pour ne pas tout re-saisir ?
