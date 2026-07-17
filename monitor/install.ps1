# Installs the oracle monitor as a scheduled task running every 5 minutes as SYSTEM,
# then fires a test alert so you can confirm notifications reach your phone.
# Run from an elevated PowerShell in this directory, AFTER editing config.json.

$here = $PSScriptRoot
if (-not (Test-Path "$here\config.json")) {
  Write-Error "No config.json found. Copy config.json.example to config.json and edit it first."
  exit 1
}

# The ntfy topic is effectively a password: anyone who knows it can read your alert
# stream and spoof alerts to you. Refuse to install with the placeholder still set.
$cfg = Get-Content "$here\config.json" -Raw | ConvertFrom-Json
if (-not $cfg.ntfy_topic -or $cfg.ntfy_topic -eq 'PICK-A-LONG-RANDOM-TOPIC-NAME') {
  $suggested = "dgb-oracle$($cfg.oracle_id)-" + ((1..24 | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) }) -join '')
  Write-Error "Set a private ntfy_topic in config.json first. Suggested random topic:`n  $suggested`nSubscribe to it in the ntfy app, then re-run install."
  exit 1
}
if ($cfg.oracle_id -eq 0) {
  Write-Error "Set your oracle_id in config.json (slot 0 is not a valid slot)."
  exit 1
}

$action = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File `"$here\oracle-monitor.ps1`""
schtasks /create /tn "DigiByteOracleMonitor" /tr $action /sc minute /mo 5 /ru SYSTEM /rl HIGHEST /f
if ($LASTEXITCODE -ne 0) { Write-Error "schtasks failed."; exit 1 }

Write-Host "Scheduled task 'DigiByteOracleMonitor' created (every 5 min, SYSTEM)."
Write-Host "Sending test alert..."
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "$here\oracle-monitor.ps1" -TestAlert
Write-Host "If no notification arrived, check ntfy topic subscription on your phone and config.json."
