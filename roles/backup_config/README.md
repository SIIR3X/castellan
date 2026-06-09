# Role: backup_config

Cross-cutting helper. Backs up remote files before any other role modifies
them, so that `./harden rollback` can later restore them.

## What it does

- `tasks/main.yml` (setup): creates a single timestamped backup directory for
  the run, under `castellan_backup_dir` (default `/var/backups/castellan`).
- `tasks/file.yml` (per file): copies one remote file into that directory,
  flattening its path (e.g. `/etc/ssh/sshd_config` becomes
  `etc_ssh_sshd_config`). Missing files are skipped.

## Usage from another role

```yaml
- name: Back up sshd_config before editing
  ansible.builtin.include_role:
    name: backup_config
    tasks_from: file
  vars:
    backup_config_file: /etc/ssh/sshd_config
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `castellan_backup_dir` | `/var/backups/castellan` | Base backup directory on the target. |
| `castellan_backup_stamp` | computed per run | Timestamp subfolder; set once per play by `tasks/main.yml`. |
| `backup_config_file` | (required by `file.yml`) | Absolute path of the file to back up. |
