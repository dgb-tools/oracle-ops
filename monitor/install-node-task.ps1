# Registers the scheduled task "DigiByteOracleNode": keeps digibyted running
# without a human. Two triggers, both essential:
#
#   1. At system startup    - the daemon comes up with the box
#   2. Every 5 minutes      - the daemon comes BACK when it crashes
#
# Trigger 2 is the one most setups are missing. A startup-only task launches
# the daemon once per boot; after the first crash the box sits dark until
# someone logs in. In the August 2026 incident most oracle slots went dark for
# up to a day for exactly this reason. The keeper script is a no-op when the
# daemon is already running, so the 5-minute repetition costs nothing.
#
# Also sets, on the task itself:
#   ExecutionTimeLimit = 0        (Windows default silently KILLS tasks after
#                                  72h - fatal for a daemon)
#   MultipleInstances  = IgnoreNew (repetitions never stack)
#
# Run from an elevated PowerShell in this directory, AFTER editing config.json
# (daemon_exe and datadir must be set).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

if (-not (Test-Path "$here\config.json")) {
  Write-Error "No config.json found. Copy config.json.example to config.json and edit it first."
  exit 1
}
$cfg = Get-Content "$here\config.json" -Raw | ConvertFrom-Json
if (-not $cfg.daemon_exe -or -not (Test-Path $cfg.daemon_exe)) {
  Write-Error "config.json daemon_exe is not set or does not exist: '$($cfg.daemon_exe)'"
  exit 1
}
if (-not (Test-Path $cfg.datadir)) {
  Write-Error "config.json datadir does not exist: '$($cfg.datadir)'"
  exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy RemoteSigned -File `"$here\start-node.ps1`""

$trigBoot   = New-ScheduledTaskTrigger -AtStartup
$trigRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName 'DigiByteOracleNode' `
  -Action $action -Trigger $trigBoot, $trigRepeat -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Scheduled task 'DigiByteOracleNode' registered:"
Write-Host "  - starts your daemon(s) at boot"
Write-Host "  - re-starts them within 5 minutes of any crash"
Write-Host "  - no 72-hour execution-time kill, repetitions never stack"
Write-Host ""
Write-Host "Running the keeper once now (it is a no-op if the daemon is already up)..."
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "$here\start-node.ps1"
Write-Host "Done. Check keeper.log for what it found."
Write-Host ""
Write-Host "NOTE for encrypted oracle wallets: after an automatic restart the NODE"
Write-Host "returns on its own, but your ORACLE stays stopped until you unlock the"
Write-Host "wallet (walletpassphrase, then startoracle). The monitor pages you for"
Write-Host "exactly that state. Unencrypted oracle wallets resume automatically."
