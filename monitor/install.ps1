# Installs the oracle monitor as a scheduled task running every 5 minutes as SYSTEM,
# then fires a test alert so you can confirm notifications reach your phone.
# Run from an elevated PowerShell in this directory, AFTER editing config.json.

$here = $PSScriptRoot
if (-not (Test-Path "$here\config.json")) {
  Write-Error "No config.json found. Copy config.json.example to config.json and edit it first."
  exit 1
}

$action = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File `"$here\oracle-monitor.ps1`""
schtasks /create /tn "DigiByteOracleMonitor" /tr $action /sc minute /mo 5 /ru SYSTEM /rl HIGHEST /f
if ($LASTEXITCODE -ne 0) { Write-Error "schtasks failed."; exit 1 }

Write-Host "Scheduled task 'DigiByteOracleMonitor' created (every 5 min, SYSTEM)."
Write-Host "Sending test alert..."
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "$here\oracle-monitor.ps1" -TestAlert
Write-Host "If no notification arrived, check ntfy topic subscription on your phone and config.json."
