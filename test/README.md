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

## Full end-to-end cycle (`make test`)

`test/e2e.sh` runs the whole pipeline against the Hyper-V VM and asserts every
step; `make test` is the shortcut. It reverts the `clean-baseline` checkpoint
before step 1 and after step 7, so the run starts and ends on a pristine target.

| Step | Assertion |
|------|-----------|
| 1. cold audit        | degrades gracefully (`failed=0`) |
| 2. apply             | `failed=0`, no lockout (Play 4 reached) |
| 3. post-apply audit  | 0 `FAIL` in the dashboard |
| 4. re-apply          | idempotent (`changed=0`) |
| 5. `check.sh`        | all green |
| 6. fresh admin login | new SSH session: login + sudo OK |
| 7. rollback          | restores without lockout |

```
make test                 # full cycle, reset before and after
SKIP_RESET=1 make test    # assume the VM is already clean (no checkpoint revert)
KEEP_VM=1   make test     # reset before, but leave the VM as-is at the end
```

### Config: `test/vm.env`

All the target settings (IP, ports, admin / initial user, reset timeout,
scheduled-task name, VM name + checkpoint) live in one editable file,
[`test/vm.env`](vm.env). The shell scripts source it and the setup `.ps1` reads
it, so you change a value in a single place. Anything exported in the
environment still overrides it ad-hoc (`CASTELLAN_HOST=10.0.0.5 make test`).
It holds no secrets; the SSH key stays in `test/secrets/`.

### One-time setup: unattended VM reset

Hyper-V cmdlets need an elevated PowerShell, which WSL is not. So the reset is
done by a pre-authorized Windows scheduled task that WSL triggers without a UAC
prompt. Set `CASTELLAN_VM_NAME` in `test/vm.env`, then register the task
**once**, from an **elevated** PowerShell at the repo root:

```
powershell -ExecutionPolicy Bypass -File test\vm-reset-setup.ps1
```

(or pass `-VMName '<your-vm-name>'` to override `vm.env`; `Get-VM` lists the
names, the checkpoint defaults to `clean-baseline`.) After
that, `test/vm-reset.sh` (and `make test`) revert the VM unattended via
`schtasks.exe /run /tn CastellanVMReset`. Without the task, the reset steps fail
with a reminder; use `SKIP_RESET=1` to run the cycle on an already-clean VM.

## systemd target (for ufw / fail2ban, later)

The plain sshd container cannot run services. When the MVP firewall lands, use
a systemd-capable target instead:

- `podman run --systemd=always` on a systemd-enabled image (may need
  `--cgroupns=host`), or
- a second throwaway WSL distro with `[boot] systemd=true` in `/etc/wsl.conf`
  (real systemd as PID 1; reset with `wsl --unregister`).
