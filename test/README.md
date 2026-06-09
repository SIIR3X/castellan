# Local test harness (Approach A: podman + sshd)

Disposable target to test the **effectiveness** of Castellan without a VPS.
It runs a minimal Ubuntu container with only `sshd` on `127.0.0.1:2222`, root
reachable by a throwaway key. Enough for `accounts`, `ssh`, `backup_config`.
It has **no systemd**, so `firewall` (ufw) and `fail2ban` cannot be tested here
(see "systemd target" below).

Nothing here touches the tracked `inventory/hosts.yml`: `run.sh` overrides
`ANSIBLE_INVENTORY` with `test/inventory.yml`. The private key lives in
`test/secrets/` and is gitignored.

## Prerequisite (once)

Podman is not installed yet. Install it on the control machine:

```
sudo apt-get update && sudo apt-get install -y podman
```

## Cycle

```
./test/up.sh            # generate key, build image, start container, sanity-check
./test/run.sh audit     # read-only: should report the admin as absent
./test/run.sh apply     # create admin, deploy key, sudoers; verify-access must pass
./test/check.sh         # assert the result over SSH (login, sudo, groups, backups)
./test/down.sh          # remove the container
```

Re-running `./test/up.sh` resets the target to a clean state in ~1s.

## What each step proves

- `up.sh`   : a fresh, untouched Ubuntu sshd target exists.
- `audit`   : Play 2 downgrades gracefully (admin not created yet), no changes.
- `apply`   : Play 1 creates the admin; Play 2 reconnects as that admin and
              asserts sudo -> uid 0 (the anti-lockout safety net).
- `check.sh`: independent proof over a real SSH session as the new admin.

## Notes / limits

- SSH stays on port 22 inside the container (published mapping is 2222->22).
  When the `ssh` role starts changing the port, update the `-p` mapping in
  `up.sh` and `ssh_port` in `inventory.yml` together, or test the port change
  on the systemd target instead.
- The initial connection uses `connection_mode: root_key` with the disposable
  key. Testing the `root_password` path additionally needs `sshpass`
  (`sudo apt-get install -y sshpass`).

## systemd target (for ufw / fail2ban, later)

The plain sshd container cannot run services. When the MVP firewall lands, use
a systemd-capable target instead:

- `podman run --systemd=always` on a systemd-enabled image (may need
  `--cgroupns=host`), or
- a second throwaway WSL distro with `[boot] systemd=true` in `/etc/wsl.conf`
  (real systemd as PID 1; reset with `wsl --unregister`).
