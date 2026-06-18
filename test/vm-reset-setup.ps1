<#
.SYNOPSIS
  Register the 'CastellanVMReset' scheduled task once (run elevated).

.DESCRIPTION
  The task reverts the disposable Castellan test VM to its 'clean-baseline'
  Hyper-V checkpoint and starts it. It runs with the highest privileges under
  the current user (S4U, no stored password), so WSL / `make test` can reset
  the target with `schtasks.exe /run /tn CastellanVMReset` and no UAC prompt.

.EXAMPLE
  # In an ELEVATED PowerShell, from the repo root (VM name from test/vm.env):
  powershell -ExecutionPolicy Bypass -File test\vm-reset-setup.ps1

.EXAMPLE
  # Or pass it explicitly (overrides test/vm.env):
  powershell -ExecutionPolicy Bypass -File test\vm-reset-setup.ps1 -VMName 'Ubuntu-Test'
#>
param(
  [string] $VMName,
  [string] $Checkpoint,
  [string] $TaskName
)

$ErrorActionPreference = 'Stop'

# Defaults come from the shared, editable test/vm.env (so the VM name lives in
# one place). An explicit -Parameter still wins. The file uses shell ':=' lines
# like:  : "${CASTELLAN_VM_NAME:=Ubuntu-Test}"
$envFile = Join-Path $PSScriptRoot 'vm.env'
function Get-EnvDefault([string] $Name, [string] $Fallback) {
  if (Test-Path $envFile) {
    $pattern = '\$\{' + $Name + ':=([^}]*)\}'
    $m = Select-String -Path $envFile -Pattern $pattern | Select-Object -First 1
    if ($m -and $m.Matches[0].Groups[1].Value) { return $m.Matches[0].Groups[1].Value }
  }
  return $Fallback
}

if (-not $VMName)     { $VMName     = Get-EnvDefault 'CASTELLAN_VM_NAME'       '' }
if (-not $Checkpoint) { $Checkpoint = Get-EnvDefault 'CASTELLAN_CHECKPOINT'    'clean-baseline' }
if (-not $TaskName)   { $TaskName   = Get-EnvDefault 'CASTELLAN_VM_RESET_TASK' 'CastellanVMReset' }

if (-not $VMName) {
  throw "VM name not set. Pass -VMName '<name>' or set CASTELLAN_VM_NAME in test/vm.env (Get-VM lists names)."
}

# Fail early with a clear message if the VM or checkpoint is missing / not elevated.
if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
  throw "VM '$VMName' not found (or PowerShell is not elevated). Run Get-VM to list names."
}
if (-not (Get-VMCheckpoint -VMName $VMName -Name $Checkpoint -ErrorAction SilentlyContinue)) {
  throw "Checkpoint '$Checkpoint' not found on VM '$VMName'."
}

# The command the task runs: restore the snapshot, then make sure the VM is up.
$inner = "Restore-VMCheckpoint -VMName '$VMName' -Name '$Checkpoint' -Confirm:`$false; " +
         "if ((Get-VM -Name '$VMName').State -ne 'Running') { Start-VM -Name '$VMName' }"

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`""
$principal = New-ScheduledTaskPrincipal `
               -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
               -LogonType S4U -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
  -Settings $settings -Force `
  -Description 'Revert the Castellan test VM to clean-baseline (triggered from WSL).' | Out-Null

Write-Host "Registered scheduled task '$TaskName' for VM '$VMName' (checkpoint '$Checkpoint')."
Write-Host "Trigger it from WSL with:  schtasks.exe /run /tn $TaskName"
