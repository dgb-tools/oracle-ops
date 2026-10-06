# DigiByte Oracle Monitor — a personal watchdog for YOUR DigiDollar oracle slot.
# Complements the digibyte.io oracle dashboard: that page shows the room; this pages YOU.
# Read-only: RPC status calls only; never touches keys, wallets, or passphrases.
# Alerts via ntfy (default) / Telegram / webhook — see config.json.
# Windows PowerShell 5.1+. Runs every 5 min via a scheduled task (see install.ps1).
param([switch]$TestAlert)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base      = $PSScriptRoot
$LogPath   = "$Base\monitor.log"
$StatePath = "$Base\state.json"
$Cfg       = Get-Content "$Base\config.json" -Raw | ConvertFrom-Json

$CliExe   = $Cfg.cli_exe
$DataDir  = $Cfg.datadir
$OracleId = [int]$Cfg.oracle_id
# Network view: a node we do not run, asked what it sees for our slot. Default is digibyte.io's node.
# Optional config key: network_view_url. Keep this at the monitor's cadence; the endpoint is unauthenticated.
$NetViewUrl = 'https://digibyte.io/api/getoracles'
$NetViewStaleSeconds = 3600   # last_update older than this, with a fresh heartbeat, is a miss (healthy slots read minutes)
if ($Cfg.PSObject.Properties['network_view_stale_seconds'] -and $Cfg.network_view_stale_seconds) { $NetViewStaleSeconds = [int]$Cfg.network_view_stale_seconds }
if ($Cfg.PSObject.Properties['network_view_url'] -and $Cfg.network_view_url) { $NetViewUrl = [string]$Cfg.network_view_url }
$TestArgs = @('-testnet')
$MainArgs = @('-testnet=0', '-chain=main')
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---------- infra ----------
function Log([string]$msg) {
  if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 5MB)) {
    Move-Item $LogPath "$LogPath.old" -Force
  }
  Add-Content $LogPath "$(Get-Date -Format s) $msg"
}

function Load-State {
  $h = @{}
  if (Test-Path $StatePath) {
    $o = Get-Content $StatePath -Raw | ConvertFrom-Json
    $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
  }
  $h
}
$State = Load-State
function Save-State { $State | ConvertTo-Json | Set-Content $StatePath -Encoding Ascii }

function Send-Notify([string]$Title, [string]$Body, [string]$Priority, [string]$Tags) {
  $sent = $false
  if ($Cfg.ntfy_topic) {
    try {
      Invoke-RestMethod -Method Post -Uri "$($Cfg.ntfy_server)/$($Cfg.ntfy_topic)" -Body $Body `
        -Headers @{ Title = $Title; Priority = $Priority; Tags = $Tags } -UseBasicParsing | Out-Null
      $sent = $true
    } catch { Log "NOTIFY-FAIL ntfy: $($_.Exception.Message)" }
  }
  if ($Cfg.telegram_bot_token -and $Cfg.telegram_chat_id) {
    try {
      Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($Cfg.telegram_bot_token)/sendMessage" `
        -Body @{ chat_id = $Cfg.telegram_chat_id; text = "$Title`n`n$Body" } -UseBasicParsing | Out-Null
      $sent = $true
    } catch { Log "NOTIFY-FAIL telegram: $($_.Exception.Message)" }
  }
  if ($Cfg.webhook_url) {
    try {
      Invoke-RestMethod -Method Post -Uri $Cfg.webhook_url -ContentType 'application/json' `
        -Body (@{ title = $Title; body = $Body; priority = $Priority } | ConvertTo-Json) -UseBasicParsing | Out-Null
      $sent = $true
    } catch { Log "NOTIFY-FAIL webhook: $($_.Exception.Message)" }
  }
  Log "NOTIFY sent=$sent [$Priority] $Title"
}

# Failure dedup + recovery. Key identifies the condition; alerts re-send every realert_hours.
function Report-Check([string]$Key, [bool]$Ok, [string]$Title, [string]$Body, [string]$Priority = 'high') {
  $downKey = "down:$Key"
  if (-not $Ok) {
    $last = 0; if ($State.ContainsKey($downKey)) { $last = [int64]$State[$downKey] }
    if (($Now - $last) -ge ([int]$Cfg.realert_hours * 3600)) {
      Send-Notify $Title $Body $Priority 'rotating_light'
      $State[$downKey] = $Now
    }
    Log "CHECK FAIL $Key"
  } elseif ($State.ContainsKey($downKey)) {
    $State.Remove($downKey)
    Send-Notify "RECOVERED: $Key" "Condition cleared at $(Get-Date -Format s) (box time)." 'default' 'white_check_mark'
    Log "CHECK RECOVERED $Key"
  }
}

# ---------- digibyte-cli ----------
# NOTE: do not name a function `Cli` — `cli` is a built-in PowerShell alias for
# Clear-Item, and aliases outrank functions, so every call would silently invoke
# Clear-Item instead. Verb-Noun names sidestep the entire alias table.
function Invoke-DgbCli([string[]]$Net, [string[]]$CmdArgs) {
  & $CliExe "-datadir=$DataDir" @Net @CmdArgs 2>$null
}
function Get-DgbJson ([string[]]$Net, [string[]]$CmdArgs) {
  try { $raw = (Invoke-DgbCli $Net $CmdArgs) -join "`n"; if ($raw) { $raw | ConvertFrom-Json } else { Log "CLIJSON-EMPTY net=[$($Net -join ',')] cmd=[$($CmdArgs -join ',')]"; $null } }
  catch { Log "CLIJSON-ERR net=[$($Net -join ',')] cmd=[$($CmdArgs -join ',')]: $($_.Exception.Message)"; $null }
}

# Known crash classes, matched on the last 400 lines of debug.log so a dead
# daemon's alert says WHAT killed it, not just that it's down. Same table as
# start-node.ps1 (each script stays standalone on purpose).
$CrashSignatures = @(
  @{ Pattern = 'length_error|vector::reserve'; Label = 'oversized-message crash (class seen network-wide in the Aug 2026 incident) - restart is safe; make sure you are on the latest release' },
  @{ Pattern = 'bad_alloc';                    Label = 'out-of-memory - check RAM/dbcache before it repeats' },
  @{ Pattern = 'Assertion failed';             Label = 'assertion failure - capture debug.log before it rotates and report to DigiByte Core' },
  @{ Pattern = 'Corrupted block database';     Label = 'block database corruption - the node will likely need -reindex; see runbook' },
  @{ Pattern = 'Disk space is too low';        Label = 'disk full' }
)
function Get-CrashClass([string]$ChainLabel) {
  $logFile = Join-Path $DataDir 'debug.log'
  if ($ChainLabel -eq 'testnet') { $logFile = Join-Path $DataDir 'testnet26\debug.log' }
  if (-not (Test-Path $logFile)) { return 'no debug.log found' }
  try {
    $tail = (Get-Content $logFile -Tail 400) -join "`n"
    foreach ($sig in $CrashSignatures) { if ($tail -match $sig.Pattern) { return $sig.Label } }
    return 'no known crash signature in recent log (clean stop, kill, or a new class)'
  } catch { return "could not read debug.log: $($_.Exception.Message)" }
}

# ---------- per-chain checks ----------
function Check-Chain([string]$Label, [string[]]$Net, [string]$ProcPattern, [bool]$IsMainnet) {
  $summary = @()

  # Liveness is judged by the RPC first, not by process-cmdline sniffing: a
  # mainnet daemon started with plain flags (just -datadir) carries nothing to
  # pattern-match and would false-alarm as DOWN. RPC answering = chain is up.
  # (Found live: the first kit test false-alarmed on exactly such a node.)
  $bc = Get-DgbJson $Net @('getblockchaininfo')
  if (-not $bc) {
    $proc = Get-CimInstance Win32_Process -Filter "Name = 'digibyted.exe'"
    if ($proc) {
      Report-Check "$Label-daemon" $true "DGB oracle box: $Label daemon DOWN" '' 'urgent'
      Report-Check "$Label-rpc" $false "DGB oracle box: $Label RPC unreachable" `
        "A digibyted process exists but $Label RPC is not answering (starting up, verifying blocks, or running with different chain flags)." 'high'
      return ,@("${Label}: RPC not answering")
    }
    $body = "digibyted ($Label) is not running.`nCrash-class read: $(Get-CrashClass $Label)"
    if ($Cfg.PSObject.Properties['auto_restart'] -and $Cfg.auto_restart -and (Test-Path "$Base\start-node.ps1")) {
      $body += "`nAuto-restart: attempting now (the 'DigiByteOracleNode' task also covers this within 5 minutes)."
      try {
        Start-Process powershell -WindowStyle Hidden -ArgumentList `
          '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$Base\start-node.ps1`"", '-Chain', $Label
      } catch { Log "AUTORESTART-SPAWN-FAIL ${Label}: $($_.Exception.Message)" }
    } else {
      $body += "`nAuto-restart is off. Install it (install-node-task.ps1) or log in and start the daemon."
    }
    Report-Check "$Label-daemon" $false "DGB oracle box: $Label daemon DOWN" $body 'urgent'
    return ,@("${Label}: DAEMON DOWN")
  }
  Report-Check "$Label-daemon" $true "DGB oracle box: $Label daemon DOWN" '' 'urgent'
  Report-Check "$Label-rpc" $true "DGB oracle box: $Label RPC unreachable" '' 'high'

  $lag = [int64]$bc.headers - [int64]$bc.blocks
  $tipTime = 0; if ($bc.PSObject.Properties['time']) { $tipTime = [int64]$bc.time } else { $tipTime = [int64]$bc.mediantime }
  $tipAge = $Now - $tipTime
  $synced = (-not $bc.initialblockdownload) -and ($lag -lt 10) -and ($tipAge -lt 1800)
  Report-Check "$Label-sync" $synced "DGB oracle box: $Label node NOT SYNCED" `
    "blocks=$($bc.blocks) headers=$($bc.headers) ibd=$($bc.initialblockdownload) tip_age_sec=$tipAge" 'high'
  $summary += "$Label h=$($bc.blocks)"

  $wallets = Get-DgbJson $Net @('listwallets')
  $wLoaded = $wallets -contains $Cfg.oracle_wallet
  Report-Check "$Label-wallet" $wLoaded "DGB oracle box: $Label wallet '$($Cfg.oracle_wallet)' NOT LOADED" `
    "listwallets does not include '$($Cfg.oracle_wallet)'. Check settings.json autoload; loadwallet to fix." 'urgent'

  # Oracle checks (mainnet: only once DigiDollar is active)
  $ddActive = $true
  if ($IsMainnet) {
    $dep = Get-DgbJson $Net @('getdigidollardeploymentinfo')
    if ($dep) {
      $ddActive = ($dep.status -eq 'active')
      $prev = ''; if ($State.ContainsKey('mainnet-dd-status')) { $prev = $State['mainnet-dd-status'] }
      if ($prev -and ($prev -ne $dep.status)) {
        if ($dep.status -eq 'active') {
          Send-Notify 'DigiDollar is ACTIVE on mainnet!' `
            ("Time to start your oracle. On the box:`n" +
             "digibyte-cli -testnet=0 -chain=main -rpcwallet=$($Cfg.oracle_wallet) walletpassphrase `"<passphrase>`" <seconds>`n" +
             "digibyte-cli -testnet=0 -chain=main -rpcwallet=$($Cfg.oracle_wallet) startoracle $OracleId`n" +
             "then verify: getoracles false -> slot $OracleId status=reporting") 'urgent' 'tada'
        } else {
          Send-Notify "DigiDollar mainnet: $prev -> $($dep.status)" "Deployment state changed." 'default' 'information_source'
        }
      }
      $State['mainnet-dd-status'] = $dep.status
      $summary += "DD=$($dep.status)"
    }
  }

  if ($ddActive) {
    $roster = Get-DgbJson $Net @('getoracles', 'false')
    $me = $null
    if ($roster) { $me = $roster | Where-Object { $_.oracle_id -eq $OracleId } }
    $reporting = $me -and ($me.status -eq 'reporting') -and $me.is_running_locally -and
                 ($me.heartbeat_status -eq 'fresh') -and $me.heartbeat_signature_valid
    $detail = "slot $OracleId absent from getoracles output"
    if ($me) { $detail = "status=$($me.status) local=$($me.is_running_locally) hb=$($me.heartbeat_status) hb_age=$($me.heartbeat_age_seconds)s sig_ok=$($me.heartbeat_signature_valid)" }

    $body = "$Label oracle $OracleId is not signing. $detail"
    if ($wLoaded) {
      $wi = Get-DgbJson ($Net + "-rpcwallet=$($Cfg.oracle_wallet)") @('getwalletinfo')
      if ($wi -and ($wi.PSObject.Properties['unlocked_until']) -and ($wi.unlocked_until -eq 0) -and $IsMainnet) {
        $body += ("`nWallet is LOCKED (likely after a reboot). Fix:`n" +
                  "digibyte-cli -testnet=0 -chain=main -rpcwallet=$($Cfg.oracle_wallet) walletpassphrase `"<passphrase>`" <seconds>`n" +
                  "digibyte-cli -testnet=0 -chain=main -rpcwallet=$($Cfg.oracle_wallet) startoracle $OracleId`n" +
                  "See runbook.md: after a hard reboot, startoracle may error until your local tip re-crosses the activation height.")
      }
    }
    Report-Check "$Label-oracle$OracleId" $reporting "DGB ORACLE $OracleId ($Label) NOT REPORTING" $body 'urgent'
    if ($me) { $summary += "$Label-o$OracleId=$($me.status)/$($me.heartbeat_status)" }
    else     { $summary += "$Label-o$OracleId=missing" }
    # NETWORK-VIEW check (mainnet only). Never name a local '$net' in this function: PowerShell variable names
    # are case-insensitive and it would be the [string[]]$Net parameter, stringifying the roster.
    # The node's self-view cannot see a silent price broadcast (slot 29, Oct 2026: the oracle auto-started
    # after an upgrade, reported healthy locally, and published no price for about five days). Ask a node
    # we do not run what it sees for our slot. Predicate, per review: the roster's `status` churns every
    # 40-block round (reads of 13/35, 10/35 and 35/35 "reporting" within one hour are all normal), so status
    # is NOT the signal. The signal is a fresh heartbeat with a stale `last_update` (the last price the
    # observer received from us): healthy slots read under ~12 minutes; a silent slot reads hours or days.
    # A miss = successful read AND heartbeat fresh AND last_update older than NetViewStaleSeconds.
    # Alert after 3 consecutive misses spanning at least 15 minutes. A fetch failure, non-JSON body or an
    # incomplete roster (not 35 unique ids) is "unknown": logged, streak reset, never a miss.
    if ($IsMainnet) {
      try {
        $raw = Invoke-WebRequest -Uri $NetViewUrl -UseBasicParsing -TimeoutSec 20 `
          -Headers @{ 'User-Agent' = "dgb-oracle-monitor (slot $OracleId)"; 'Accept' = 'application/json' }
        $netRoster = $null; try { $netRoster = $raw.Content | ConvertFrom-Json } catch {}
        $ids = @(); if ($netRoster) { $ids = @($netRoster | ForEach-Object { $_.oracle_id } | Sort-Object -Unique) }
        if ($ids.Count -ne 35) { throw "roster incomplete or malformed: $($ids.Count) unique ids, http=$($raw.StatusCode)" }
        $nme = $netRoster | Where-Object { $_.oracle_id -eq $OracleId }
        $nowU = [int64][double]::Parse((Get-Date -UFormat %s))
        $luAge = -1; if ($nme -and $nme.last_update) { $luAge = $nowU - [int64]$nme.last_update }
        $hbFresh = [bool]($nme -and ($nme.heartbeat_status -eq 'fresh'))
        $miss = [bool]((-not $nme) -or ($hbFresh -and ($luAge -lt 0 -or $luAge -gt $NetViewStaleSeconds)))
        $streak = 0; $since = $nowU
        if ($State.ContainsKey('net-miss')) { $streak = [int]$State['net-miss'] }
        if ($State.ContainsKey('net-miss-since')) { $since = [int64]$State['net-miss-since'] }
        if ($miss) { if ($streak -eq 0) { $since = $nowU }; $streak = $streak + 1 } else { $streak = 0; $since = $nowU }
        $State['net-miss'] = $streak; $State['net-miss-since'] = $since
        $netFail = ($streak -ge 3) -and (($nowU - $since) -ge 900)
        $nstat = 'absent'; $nsrc = 'n/a'; $nhb = 'n/a'
        if ($nme) { $nstat = $nme.status; $nsrc = $nme.price_source; $nhb = $nme.heartbeat_status }
        $localStatus = 'missing'; if ($me) { $localStatus = $me.status }
        Report-Check "$Label-oracle$OracleId-networkview" (-not $netFail) "DGB ORACLE $OracleId NOT OBSERVED BY THE NETWORK-VIEW NODE" `
          ("The observer at $NetViewUrl has not received a price from slot $OracleId for $luAge seconds " +
           "(heartbeat $nhb, status $nstat, price_source $nsrc) across $streak consecutive reads over $([int](($nowU - $since)/60)) minutes, " +
           "while this node reports status=$localStatus. This is one observer's view, not network proof. Corroborate first: " +
           "read the same URL again in 15 minutes and check your own listoracle. If last_update stays stale with a fresh heartbeat, " +
           "the price broadcast is likely silent; the runbook's 'after any restart or upgrade' section gives the stop/start fix.") 'urgent'
        $summary += " net-o$OracleId=$nstat/lu${luAge}s"
      } catch { $State['net-miss'] = 0; Log "netview check unknown (streak reset, not a miss): $($_.Exception.Message)" }
    }
  } else {
    $summary += "$Label-o$OracleId=staged(pre-activation)"
  }
  ,$summary
}

# ---------- run ----------
try {
  if ($TestAlert) {
    Send-Notify 'DGB oracle monitor: test alert' "Monitor is installed and can reach you. Box time: $(Get-Date -Format s)" 'default' 'wave'
    Save-State
    exit 0
  }

  $parts = @()
  if ($Cfg.monitor_testnet) { $parts += Check-Chain 'testnet' $TestArgs '-testnet\b' $false }
  if ($Cfg.monitor_mainnet) { $parts += Check-Chain 'mainnet' $MainArgs 'chain=main' $true }

  # Disk space
  $minGb = [int]$Cfg.min_free_disk_gb
  $free = (Get-PSDrive C).Free
  Report-Check 'disk' ($free -gt ($minGb * 1GB)) 'DGB oracle box: LOW DISK' `
    ("C: has {0:N1} GB free (threshold {1} GB)." -f ($free / 1GB), $minGb) 'high'

  # Version drift vs GitHub (checked hourly). /releases/latest excludes prereleases, so release
  # candidates never page. Hourly because a mandatory release can ship with a deadline: with the
  # old 12-hour cadence v9.26.6 (2026-10-01) would have gone unreported for up to 12 hours.
  # One unauthenticated GitHub API call per hour is far inside the 60/hour limit.
  $lastVc = 0; if ($State.ContainsKey('ver-check-ts')) { $lastVc = [int64]$State['ver-check-ts'] }
  if (($Now - $lastVc) -gt 3600) {
    $State['ver-check-ts'] = $Now
    try {
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/DigiByte-Core/digibyte/releases/latest' `
        -Headers @{ 'User-Agent' = 'dgb-oracle-monitor' } -UseBasicParsing
      $netArgs = $MainArgs; if (-not $Cfg.monitor_mainnet) { $netArgs = $TestArgs }
      $ni = Get-DgbJson $netArgs @('getnetworkinfo')
      if ($rel.tag_name -match '(\d+\.\d+\.\d+)') { $latest = [version]$Matches[1] } else { $latest = $null }
      $local = $null
      if ($ni -and $ni.subversion -match '(\d+\.\d+\.\d+)') { $local = [version]$Matches[1] }
      if ($latest -and $local) {
        Report-Check 'version' ($local -ge $latest) 'DGB oracle box: version drift' `
          "Local $local < latest release $latest ($($rel.tag_name)). Read the release notes for an upgrade deadline, then plan the upgrade (runbook: clean-stop procedure)." 'default'
      }
    } catch { Log "ver-check failed: $($_.Exception.Message)" }
  }

  # Daily heartbeat
  $today = Get-Date -Format yyyy-MM-dd
  $hbDone = ''; if ($State.ContainsKey('hb-date')) { $hbDone = $State['hb-date'] }
  if ($Cfg.heartbeat_enabled -and ($hbDone -ne $today) -and ((Get-Date).Hour -ge [int]$Cfg.heartbeat_hour)) {
    $State['hb-date'] = $today
    $downs = ($State.Keys | Where-Object { $_ -like 'down:*' }) -join ', '
    $status = 'all checks passing'; if ($downs) { $status = "OPEN ISSUES: $downs" }
    Send-Notify 'DGB oracle daily heartbeat' "$status`n$($parts -join ' | ')" 'min' 'satellite'
  }

  Save-State
  Log "PASS $($parts -join ' | ')"
} catch {
  Log "MONITOR-ERROR $($_.Exception.Message)"
  try { Send-Notify 'DGB oracle monitor: internal error' $_.Exception.Message 'high' 'warning' } catch {}
  Save-State
  exit 1
}
