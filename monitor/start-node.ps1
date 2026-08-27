# DigiByte node keeper — starts digibyted if (and only if) it is not running.
# This is the auto-restart half of oracle-ops: the monitor pages you, this one
# fixes the common case first. Safe to run every 5 minutes forever: if the
# daemon is already up it exits without touching anything.
#
# Installed as the scheduled task "DigiByteOracleNode" by install-node-task.ps1
# (at-startup trigger + 5-minute repetition). The repetition trigger is the
# part most setups get wrong: a plain at-startup task starts the daemon once
# and never again, so the first crash leaves the box dark until a human logs
# in. That is exactly what happened to most oracle slots in the August 2026
# incident.
#
# Reads monitor\config.json (same file as the monitor):
#   daemon_exe        full path to digibyted.exe
#   datadir           the node datadir
#   monitor_testnet   keep the testnet daemon alive
#   monitor_mainnet   keep the mainnet daemon alive
param(
  [ValidateSet('testnet', 'mainnet', 'all')] [string]$Chain = 'all',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base    = $PSScriptRoot
$LogPath = "$Base\keeper.log"
$Cfg     = Get-Content "$Base\config.json" -Raw | ConvertFrom-Json

function Log([string]$msg) {
  if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 5MB)) {
    Move-Item $LogPath "$LogPath.old" -Force
  }
  Add-Content $LogPath "$(Get-Date -Format s) $msg"
}

# Minimal ntfy notice so a restart is never silent, even without the monitor.
function Send-KeeperNotify([string]$Title, [string]$Body) {
  if (-not $Cfg.ntfy_topic) { return }
  try {
    Invoke-RestMethod -Method Post -Uri "$($Cfg.ntfy_server)/$($Cfg.ntfy_topic)" -Body $Body `
      -Headers @{ Title = $Title; Priority = 'high'; Tags = 'arrows_counterclockwise' } -UseBasicParsing | Out-Null
  } catch { Log "NOTIFY-FAIL ntfy: $($_.Exception.Message)" }
}

# Known crash classes, matched against the tail of debug.log after a death.
# The annotation tells the operator (and Core, if reported) WHAT killed the
# daemon instead of just "it was down". Signatures are matched on the last
# 400 lines only, so ancient history can't false-positive a fresh death.
$CrashSignatures = @(
  @{ Pattern = 'length_error|vector::reserve'; Label = 'oversized-message crash (class seen network-wide in the Aug 2026 incident) - restart is safe; make sure you are on the latest release' },
  @{ Pattern = 'bad_alloc';                    Label = 'out-of-memory - check RAM/dbcache before it repeats' },
  @{ Pattern = 'Assertion failed';             Label = 'assertion failure - capture debug.log before it rotates and report to DigiByte Core' },
  @{ Pattern = 'Corrupted block database';     Label = 'block database corruption - the node will likely need -reindex; see runbook' },
  @{ Pattern = 'Disk space is too low';        Label = 'disk full' }
)

function Get-CrashClass([string]$ChainLabel) {
  $logFile = Join-Path $Cfg.datadir 'debug.log'
  if ($ChainLabel -eq 'testnet') { $logFile = Join-Path $Cfg.datadir 'testnet26\debug.log' }
  if (-not (Test-Path $logFile)) { return 'no debug.log found' }
  try {
    $tail = (Get-Content $logFile -Tail 400) -join "`n"
    foreach ($sig in $CrashSignatures) {
      if ($tail -match $sig.Pattern) { return $sig.Label }
    }
    return 'no known crash signature in recent log (could be a clean stop, a kill, or a new class)'
  } catch { return "could not read debug.log: $($_.Exception.Message)" }
}

function Ensure-Chain([string]$Label, [string]$ProcPattern, [string[]]$StartArgs, [string[]]$NetArgs) {
  # RPC first: if the chain answers, it is up no matter what flags launched
  # it (a plain `digibyted -datadir=X` mainnet daemon matches no pattern).
  # This also makes a double-start against a hand-started daemon impossible.
  $alive = $null
  try { $alive = & $Cfg.cli_exe "-datadir=$($Cfg.datadir)" @NetArgs getblockcount 2>$null } catch {}
  if ($alive) { Log "OK $Label already running (RPC answering, height $alive)"; return }
  $proc = Get-CimInstance Win32_Process -Filter "Name = 'digibyted.exe'" |
          Where-Object { $_.CommandLine -match $ProcPattern }
  if ($proc) { Log "OK $Label process present (pid $($proc.ProcessId)); RPC not up yet (starting/verifying) - leaving it alone"; return }

  $crash = Get-CrashClass $Label
  if ($DryRun) { Log "DRYRUN would start $Label; last-death read: $crash"; return }

  Log "START $Label - daemon not running. Crash-class read: $crash"
  Start-Process -FilePath $Cfg.daemon_exe -ArgumentList (@("-datadir=$($Cfg.datadir)") + $StartArgs) -WindowStyle Hidden
  Start-Sleep -Seconds 10
  $proc = Get-CimInstance Win32_Process -Filter "Name = 'digibyted.exe'" |
          Where-Object { $_.CommandLine -match $ProcPattern }
  if ($proc) {
    Log "STARTED $Label (pid $($proc.ProcessId))"
    Send-KeeperNotify "DGB $Label daemon restarted automatically" `
      ("digibyted ($Label) was down and has been restarted.`nLikely cause: $crash`nIf your oracle wallet is encrypted, the oracle will NOT resume until you unlock it - see runbook.")
  } else {
    # Most common cause: a daemon started by hand with DIFFERENT launch flags
    # already owns the datadir (the lock refuses our second instance). Say so.
    $anyDgb = Get-CimInstance Win32_Process -Filter "Name = 'digibyted.exe'"
    if ($anyDgb) {
      Log "START-FAILED $Label - datadir likely locked by an existing digibyted with different flags (pid $($anyDgb[0].ProcessId))"
      Send-KeeperNotify "DGB $Label keeper: flag mismatch" `
        "A digibyted process is already running but with different launch flags than the keeper uses, so it can't be recognized or managed. Either stop it and let the keeper start it (recommended), or align your manual start flags with the keeper's (-testnet / -testnet=0 -chain=main)."
    } else {
      Log "START-FAILED $Label - process not alive 10s after launch"
      Send-KeeperNotify "DGB $Label daemon restart FAILED" `
        "digibyted ($Label) was started but died within 10 seconds. Likely cause of the original death: $crash`nLog in and investigate; see runbook post-crash triage."
    }
  }
}

try {
  if (($Chain -in 'all', 'testnet') -and $Cfg.monitor_testnet) {
    Ensure-Chain 'testnet' '-testnet\b' @('-testnet') @('-testnet')
  }
  if (($Chain -in 'all', 'mainnet') -and $Cfg.monitor_mainnet) {
    Ensure-Chain 'mainnet' 'chain=main' @('-testnet=0', '-chain=main') @('-testnet=0', '-chain=main')
  }
} catch {
  Log "KEEPER-ERROR $($_.Exception.Message)"
  exit 1
}
