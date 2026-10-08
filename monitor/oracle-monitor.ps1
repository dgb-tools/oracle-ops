# DigiByte Oracle Monitor — a personal watchdog for YOUR DigiDollar oracle slot.
# Complements the digibyte.io oracle dashboard: that page shows the room; this pages YOU.
# Read-only: RPC status calls only; never touches keys, wallets, or passphrases.
# Alerts via ntfy (default) / Telegram / webhook — see config.json.
# Windows PowerShell 5.1+. Runs every 5 min via a scheduled task (see install.ps1).
param(
  [switch]$NetViewSelfTest,[switch]$TestAlert)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base      = $PSScriptRoot
$LogPath   = "$Base\monitor.log"
$StatePath = "$Base\state.json"
$Cfg       = $null
if ($NetViewSelfTest) { $Cfg = [pscustomobject]@{ oracle_id = 29; cli_exe = ""; datadir = ""; oracle_wallet = "oracle" } }
else { $Cfg = Get-Content "$Base\config.json" -Raw | ConvertFrom-Json }

$CliExe   = $Cfg.cli_exe
$DataDir  = $Cfg.datadir
$OracleId = [int]$Cfg.oracle_id
# Network view: a node we do not run, asked what it sees for our slot. Default is digibyte.io's node.
# Optional config key: network_view_url. Keep this at the monitor's cadence; the endpoint is unauthenticated.
$NetViewUrl = 'https://digibyte.io/api/getoracles'
$NetViewStaleSeconds = 3600   # last_update older than this, with a fresh heartbeat, is a miss (healthy slots read minutes)
$ForkGapBlocks = 100          # a peer "claims ahead" when its startingheight exceeds our headers by more than this (triage threshold)
$ForkMinPeers = 2             # this many peers must claim ahead at once; one erroneous peer cannot set the maximum
$ForkProgressBlocks = 100     # headers advancing by at least this per cycle is a catch-up, not a stall
if ($Cfg.PSObject.Properties['fork_gap_blocks'] -and $Cfg.fork_gap_blocks) { $ForkGapBlocks = [int]$Cfg.fork_gap_blocks }
if ($Cfg.PSObject.Properties['fork_min_peers'] -and $Cfg.fork_min_peers) { $ForkMinPeers = [int]$Cfg.fork_min_peers }
if ($Cfg.PSObject.Properties['fork_progress_blocks'] -and $Cfg.fork_progress_blocks) { $ForkProgressBlocks = [int]$Cfg.fork_progress_blocks }
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
# Fork detector, crew review 2026-10-07. Oct 2026 lesson: a testnet node sat on a dead branch for 17 days while
# "headers == blocks" looked synced. The check compares our HEADERS with what connected peers CLAIM.
# startingheight is a peer's claim at connect, not a lower bound on the valid chain, so one peer cannot set it:
# $ForkMinPeers peers must each claim more than $ForkGapBlocks above our headers. synced_headers is not used: per
# Core's help text it is "the last header we have in common with this peer", so it can never exceed ours.
function Get-ForkPeersAhead($Peers, [int64]$Ours, [int]$Gap) {
  $rows = @(); if ($null -ne $Peers) { $rows = @($Peers) }
  if ($rows.Count -eq 0) { return @{ ok = $false; peers = 0; ahead = 0; claim = [int64]0 } }
  $ahead = 0; $claim = [int64]0; $first = $true
  foreach ($p in $rows) {
    if ($null -eq $p -or $p -is [string] -or $p -is [array] -or -not ($p.PSObject.Properties['startingheight'])) { return @{ ok = $false; peers = 0; ahead = 0; claim = [int64]0 } }
    $v = $p.startingheight
    if (-not (($v -is [int]) -or ($v -is [long]) -or ($v -is [int16]) -or ($v -is [byte]) -or ($v -is [double]) -or ($v -is [decimal]))) { return @{ ok = $false; peers = 0; ahead = 0; claim = [int64]0 } }
    $sh = [int64]$v
    if ($first -or ($sh -gt $claim)) { $claim = $sh; $first = $false }
    if ($sh -gt ($Ours + $Gap)) { $ahead++ }
  }
  return @{ ok = $true; peers = $rows.Count; ahead = $ahead; claim = $claim }
}
# Update-ForkState (pure; no I/O). Outcomes:
#  unknown     = no peer data, or no persisted headers sample to measure progress against (the first read after a
#                cold start; the sample lives in the state file and survives restarts): pending reset, alert untouched.
#  ok          = fewer than MinPeers peers claim ahead AND our headers advanced since the previous cycle: the ONLY
#                outcome that clears an alert.
#  unconfirmed = fewer than MinPeers peers claim ahead but our headers did not move: the corroborating peers may
#                simply have disconnected, so this neither pages nor clears. Pending reset, alert untouched.
#  catchup     = enough peers claim ahead but our headers advanced >= ProgressBlocks since the previous cycle (a sync
#                from behind moves far faster; a chain at 15 s blocks adds ~20 per 5-minute cycle, so a branch that
#                merely keeps chain pace is not catching up): pending reset, alert untouched.
#  stuck       = enough peers claim ahead and our headers advanced less than ProgressBlocks (below the threshold,
#                not necessarily zero): pending evidence; the 3rd consecutive FIRES, i.e. the 4th read after a cold
#                start, 15 minutes after the first at the 5-minute cadence.
#  Any peer row without a numeric startingheight makes the whole read "no data" (same rule as the bash monitor).
#  class on fire: deadbranch when the node looks synced locally (ibd=false and headers-blocks < 10), the pattern of
#            the incident, urgent; stalledsync otherwise (still in IBD, or headers far ahead of blocks), normal
#            priority, no reconsiderblock advice. Neither is a diagnosis: both say "investigate why local headers
#            trail peer claims". Known limit, and the kit has NO backstop for it: peers all on the same dead branch
#            never trip this; peers all claiming wrong heights would mis-trip it. A second node, an explorer, or
#            getchaintips elsewhere is the backstop. The network-view check is not one: it reads the mainnet
#            observer's price receipts, not chain agreement.
function Update-ForkState([hashtable]$St, [string]$Key, [bool]$ReadOk, [int]$AheadN, $OurHeaders, [string]$Ibd, [int64]$Lag, [int]$MinPeers = 2, [int]$ProgressBlocks = 100) {
  $res = @{ outcome = 'unknown'; fire = $false; class = ''; streak = 0; progress = [int64]0 }
  $m = 0; if ($St.ContainsKey($Key)) { $m = [int]$St[$Key] }
  $prev = $null; if ($St.ContainsKey("$Key-hdr") -and $null -ne $St["$Key-hdr"]) { $prev = [int64]$St["$Key-hdr"] }
  if ($null -eq $OurHeaders) { $St[$Key] = 0; return $res }
  $ours = [int64]$OurHeaders; $St["$Key-hdr"] = $ours
  if (-not $ReadOk) { $St[$Key] = 0; return $res }
  if ($null -eq $prev) { $St[$Key] = 0; return $res }
  $res.progress = $ours - $prev
  if ($AheadN -lt $MinPeers) {
    if ($res.progress -ge 1) { $res.outcome = 'ok' } else { $res.outcome = 'unconfirmed' }
    $St[$Key] = 0; return $res
  }
  if ($res.progress -ge $ProgressBlocks) { $res.outcome = 'catchup'; $St[$Key] = 0; return $res }
  $res.outcome = 'stuck'; $m = $m + 1; $St[$Key] = $m; $res.streak = $m
  if ($m -ge 3) {
    $res.fire = $true
    if (($Ibd -eq 'false') -and ($Lag -lt 10)) { $res.class = 'deadbranch' } else { $res.class = 'stalledsync' }
  }
  return $res
}

# Roster validator (pure). Equivalent to the bash netview_validate: $true only when the parsed body is an array of
# exactly 35 objects whose oracle_id values are 35 unique integers, each with a string status, a string
# heartbeat_status, and an explicitly present integer last_update >= 0 (0 is the never-received sentinel; null or
# missing is a schema failure). Types are tested before any conversion; fractional or string ids are rejected.
function Test-NetViewRoster($Roster) {
  if ($null -eq $Roster) { return $false }
  $rows = @($Roster); if ($rows.Count -ne 35) { return $false }
  $isInt = { param($v) ($v -is [int]) -or ($v -is [long]) -or ($v -is [int16]) -or ($v -is [byte]) -or (($v -is [double] -or $v -is [decimal]) -and ($v -eq [math]::Floor($v))) }
  $ids = @()
  foreach ($e in $rows) {
    if ($null -eq $e -or $e -is [string] -or $e -is [array]) { return $false }
    foreach ($k in 'oracle_id','status','heartbeat_status','last_update') { if (-not $e.PSObject.Properties[$k]) { return $false } }
    if (-not (& $isInt $e.oracle_id)) { return $false }
    if (-not ($e.status -is [string]) -or -not ($e.heartbeat_status -is [string])) { return $false }
    if ($null -eq $e.last_update -or -not (& $isInt $e.last_update) -or ($e.last_update -lt 0)) { return $false }
    $ids += [int64]$e.oracle_id
  }
  if (@($ids | Sort-Object -Unique).Count -ne 35) { return $false }
  return $true
}

# Network-view state machine (pure; no I/O). Rules per crew review 2026-10-06/07 and option A, 2026-10-08. Outcomes:
#  miss       = read ok, heartbeat 'fresh', last_update > 0 and older than $StaleSeconds ("aged"): the observer
#               reports an old price timestamp. Pending evidence accrues. An observation, not proven silence; on
#               this observer it was seen on 0 of 35 slots in every read of 2026-10-08's samples.
#  hit        = read ok, heartbeat 'fresh', last_update > 0 and within $StaleSeconds: CONFIRMED recovery; clears
#               pending evidence; the only outcome allowed to clear an active alert.
#  zeroed     = read ok, heartbeat 'fresh', last_update is the explicit 0 (null/missing is a schema failure that
#               never reaches this machine). The observer zeroes a slot whenever no price message has arrived since
#               its last pending-message clear (every ~14 s) while slots send every 60-250 s: a healthy slot read 0
#               on 15-52% of reads on 2026-10-08, with runs of 9 minutes. Logged only. Pending evidence reset; alert
#               untouched. NEVER a miss, NEVER a hit.
#  outofscope = read ok but heartbeat not fresh (node down/restarting/loading): nothing known about the price
#               path. Pending evidence reset; alert untouched.
#  unknown    = read not ok, or last_update malformed or in the future (> now + 300 s). Pending evidence reset;
#               alert untouched. Never a miss, never a hit.
#  fire       = a miss that is the 3rd+ consecutive AND >= 900 s after the first of the streak.
function Update-NetViewState([hashtable]$St, [bool]$ReadOk, $Entry, [int64]$NowU, [int]$StaleSeconds) {
  $streak = 0; $since = $NowU
  if ($St.ContainsKey('net-miss')) { $streak = [int]$St['net-miss'] }
  if ($St.ContainsKey('net-miss-since')) { $since = [int64]$St['net-miss-since'] }
  $res = @{ outcome = 'unknown'; fire = $false; streak = 0; age = -1; minutes = 0 }
  if (-not $ReadOk) { $St['net-miss'] = 0; return $res }
  $age = -1; $lu = $Entry.last_update
  if ($null -eq $lu -or "$lu" -eq '') { $St['net-miss'] = 0; return $res }            # null/missing: schema failure upstream; unknown here
  if ("$lu" -ne '0') {
    $luN = 0L; if (-not [int64]::TryParse("$lu", [ref]$luN)) { $St['net-miss'] = 0; return $res }
    $age = $NowU - $luN; if ($age -lt -300) { $St['net-miss'] = 0; return $res }; if ($age -lt 0) { $age = 0 }
  }
  if ($Entry.heartbeat_status -ne 'fresh') { $St['net-miss'] = 0; $res.outcome = 'outofscope'; $res.age = $age; return $res }
  if ($age -lt 0) { $St['net-miss'] = 0; $res.outcome = 'zeroed'; $res.age = -1; return $res }
  $miss = ($age -gt $StaleSeconds)
  if ($miss) { if ($streak -eq 0) { $since = $NowU }; $streak = $streak + 1 } else { $streak = 0; $since = $NowU }
  $St['net-miss'] = $streak; $St['net-miss-since'] = $since; $St['net-last-ok-read'] = $NowU
  $res.outcome = $(if ($miss) { 'miss' } else { 'hit' }); $res.streak = $streak; $res.age = $age
  $res.minutes = [int][math]::Floor(($NowU - $since) / 60)
  $res.fire = $miss -and ($streak -ge 3) -and (($NowU - $since) -ge 900)
  return $res
}

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
  # FORK DETECTOR: local data only (getpeerinfo). See Update-ForkState for the outcomes and the known limit.
  $peers = Get-DgbJson $Net @('getpeerinfo')
  $pa = Get-ForkPeersAhead $peers ([int64]$bc.headers) $ForkGapBlocks
  $ibdStr = "$($bc.initialblockdownload)".ToLower()
  $fr = Update-ForkState $State "$Label-fork-miss" ([bool]$pa.ok) ([int]$pa.ahead) ([int64]$bc.headers) $ibdStr $lag $ForkMinPeers $ForkProgressBlocks
  switch ($fr.outcome) {
    'ok' { Report-Check "$Label-fork" $true "DGB oracle box: $Label headers trail peer claims" '' 'urgent' }
    'unconfirmed' { Log "fork: fewer than $ForkMinPeers peers claim ahead but headers=$($bc.headers) did not move this cycle; unconfirmed (corroborating peers may have disconnected); alert state untouched" }
    'stuck' {
      $summary += " $Label PEERS_AHEAD=$($pa.ahead)/$($pa.peers)"
      if (-not $fr.fire) {
        Log "fork: stuck $($fr.streak)/3 ($($pa.ahead) of $($pa.peers) peers claim more than $ForkGapBlocks above headers=$($bc.headers), highest claim $($pa.claim); headers +$($fr.progress) this cycle); alert state untouched"
      } elseif ($fr.class -eq 'deadbranch') {
        Report-Check "$Label-fork" $false "DGB oracle box: $Label headers trail peer claims while the node looks synced (dead-branch candidate)" `
          ("Our headers=$($bc.headers) advanced $($fr.progress) blocks since the previous check while $($pa.ahead) of $($pa.peers) connected peers claim a startingheight more than $ForkGapBlocks above them (highest claim $($pa.claim)), for $($fr.streak) consecutive checks (progress below the $ForkProgressBlocks-block threshold), and this node reports ibd=false with headers within 10 of blocks: locally it looks synced. " +
           "Local headers that trail peer claims and stay below the progress threshold are consistent with a dead branch (a stored invalid mark, for example after crossing an activation on old software) and also with stale or wrong peer claims. " +
           "Investigate why local headers trail peer claims before changing anything: digibyte-cli $($Net -join ' ') getchaintips; a tip with status=invalid above our height is the signal. " +
           "Confirm with a node you trust or an explorer that the invalid tip's hash is on the real chain, and that this node's software is at the version the active rules require (otherwise it rejects the block again). Only then: reconsiderblock <hash>. " +
           "On the oracle box on 2026-10-07 the reorg completed in about 90 s (one observation). Tip-age thresholds do not catch this.") 'urgent'
      } else {
        Report-Check "$Label-fork" $false "DGB oracle box: $Label headers trail peer claims and stay below the progress threshold (stalled sync)" `
          ("Our headers=$($bc.headers) advanced $($fr.progress) blocks since the previous check while $($pa.ahead) of $($pa.peers) connected peers claim a startingheight more than $ForkGapBlocks above them (highest claim $($pa.claim)), for $($fr.streak) consecutive checks (progress below the $ForkProgressBlocks-block threshold), and this node reports ibd=$ibdStr with headers-blocks=$($lag): it does not look synced locally. " +
           "This is a stalled sync, not a dead-branch finding. Investigate why local headers trail peer claims (peer connectivity, disk, a sync that stopped). Do not run reconsiderblock on this evidence.") 'high'
      }
    }
    'catchup' { Log "fork: $($pa.ahead) of $($pa.peers) peers claim more than $ForkGapBlocks above headers=$($bc.headers) but headers advanced +$($fr.progress) this cycle (catching up); pending evidence reset, alert state untouched" }
    default { Log "fork detector unknown (no peer data, or no progress baseline yet); pending evidence reset, alert state untouched" }
  }

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
    # The node's self-view cannot see a silent price broadcast (slot 29, Oct 2026). Ask a node we do not run.
    # The roster's `status` churns every 40-block round and is NOT the signal; a fresh heartbeat with a stale
    # `last_update` is. Transitions: Update-NetViewState (pure; -NetViewSelfTest). Report-Check is called ONLY
    # when firing (ok=false) and on a confirmed hit (ok=true); outofscope and unknown never touch the alert.
    if ($IsMainnet) {
      $nowU = [int64][double]::Parse((Get-Date -UFormat %s)); $nme = $null; $readOk = $false; $why = ''
      try {
        $raw = Invoke-WebRequest -Uri $NetViewUrl -UseBasicParsing -TimeoutSec 20 `
          -Headers @{ 'User-Agent' = "dgb-oracle-monitor (slot $OracleId)"; 'Accept' = 'application/json' }
        $netRoster = $null; try { $netRoster = $raw.Content | ConvertFrom-Json } catch {}
        if (-not (Test-NetViewRoster $netRoster)) { throw "roster failed schema/completeness check (array of 35 objects, 35 unique integer ids, typed fields, explicit integer last_update)" }
        $netRoster = @($netRoster)
        $nme = $netRoster | Where-Object { [int]$_.oracle_id -eq $OracleId } | Select-Object -First 1
        if (-not $nme) { throw "slot $OracleId absent; configuration or response completeness unconfirmed" }
        $readOk = $true
      } catch { $why = $_.Exception.Message }
      $r = Update-NetViewState $State $readOk $nme $nowU $NetViewStaleSeconds
      switch ($r.outcome) {
        'miss' {
          if ($r.fire) {
            $localStatus = 'missing'; if ($me) { $localStatus = $me.status }
            Report-Check "$Label-oracle$OracleId-networkview" $false "DGB ORACLE $OracleId`: NETWORK-VIEW OBSERVER REPORTS AN OLD PRICE TIMESTAMP" `
              ("The observer at $NetViewUrl holds a last price timestamp for slot $OracleId that is $($r.age) seconds old (older than $NetViewStaleSeconds s) with a fresh heartbeat " +
               "(status $($nme.status), price_source $($nme.price_source)) on $($r.streak) consecutive reads over $($r.minutes) minutes, while this node reports status=$localStatus. " +
               "This is an observation from one node we do not run, not proven silence; on this observer the condition was seen on no slot in the samples of 2026-10-08, so treat it as rare and corroborate: " +
               "your own listoracle, the oracle log for price messages, a second observer, and the signing-drought check. Cycling the oracle needs that corroboration, not this alert alone.") 'urgent'
          }
          $summary += " net-o$OracleId=miss/lu$($r.age)s"
        }
        'hit' { Report-Check "$Label-oracle$OracleId-networkview" $true "DGB ORACLE $OracleId`: NETWORK-VIEW OBSERVER REPORTS AN OLD PRICE TIMESTAMP" 'confirmed recovery' 'urgent'; $summary += " net-o$OracleId=hit/lu$($r.age)s" }
        'zeroed' { $summary += " net-o$OracleId=zeroed"; Log "netview: observer shows last_update 0 for slot $OracleId (not in its current scan; a healthy slot reads 0 on 15-52% of reads); logged only, pending evidence reset, alert state untouched" }
        'outofscope' { $summary += " net-o$OracleId=hb-$($nme.heartbeat_status)"; Log "netview: heartbeat $($nme.heartbeat_status) at the observer; price path not assessed, alert state untouched" }
        default { Log "netview check unknown (pending evidence reset, alert state untouched): $(if ($why) { $why } else { 'last_update malformed or in the future' })" }
      }
    }
  } else {
    $summary += "$Label-o$OracleId=staged(pre-activation)"
  }
  ,$summary
}


if ($NetViewSelfTest) {
  # steps: @(readOk, heartbeat, age|'none'|'future'|'bad', secondsFromStart, expectFire, expectAlertAfter)
  $cases = @(
    @{ name = 'healthy reads never fire'; steps = @(@($true,'fresh',70,0,$false,0), @($true,'fresh',120,300,$false,0), @($true,'fresh',40,600,$false,0)) },
    @{ name = 'three stale reads inside 10 min do NOT fire (elapsed gate)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0)) },
    @{ name = 'fourth stale read at 15 min fires'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1)) },
    @{ name = 'unknown ticks reset pending evidence and never fire (OEAE scenario)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($false,'',0,600,$false,0), @($false,'',0,900,$false,0), @($true,'fresh',5500,1500,$false,0), @($true,'fresh',5800,1800,$false,0), @($true,'fresh',6100,2100,$false,0), @($true,'fresh',6400,2400,$true,1)) },
    @{ name = 'stale heartbeat with stale last_update is out of scope, not a miss'; steps = @(@($true,'stale',9000,0,$false,0), @($true,'stale',9300,300,$false,0), @($true,'stale',9600,600,$false,0), @($true,'stale',9900,900,$false,0)) },
    @{ name = 'explicit 0 with a fresh heartbeat is zeroed: logged only, never fires'; steps = @(@($true,'fresh','zero',0,$false,0), @($true,'fresh','zero',300,$false,0), @($true,'fresh','zero',600,$false,0), @($true,'fresh','zero',900,$false,0), @($true,'fresh','zero',1200,$false,0), @($true,'fresh','zero',1500,$false,0)) },
    @{ name = 'zeroed resets pending aged evidence (the streak restarts after it)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh','zero',600,$false,0), @($true,'fresh',4900,900,$false,0), @($true,'fresh',5200,1200,$false,0), @($true,'fresh',5500,1500,$false,0), @($true,'fresh',5800,1800,$true,1)) },
    @{ name = 'an active aged alert survives zeroed reads (never clears)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($true,'fresh','zero',1200,$false,1), @($true,'fresh','zero',1500,$false,1), @($true,'fresh','zero',1800,$false,1)) },
    @{ name = 'null last_update reaching the state machine is unknown, never a miss'; steps = @(@($true,'fresh','none',0,$false,0), @($true,'fresh','none',300,$false,0), @($true,'fresh','none',600,$false,0), @($true,'fresh','none',900,$false,0)) },
    @{ name = 'a hit clears pending evidence'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',50,600,$false,0), @($true,'fresh',4000,900,$false,0), @($true,'fresh',4300,1200,$false,0), @($true,'fresh',4600,1500,$false,0)) },
    @{ name = 'active alert survives unknown reads (unconfirmed, not recovered)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($false,'',0,1200,$false,1), @($false,'',0,1500,$false,1)) },
    @{ name = 'active alert survives a stale heartbeat (restart does not count as recovery)'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($true,'stale',5200,1200,$false,1), @($true,'stale',5500,1500,$false,1)) },
    @{ name = 'malformed and future timestamps are unknown: never fire, never clear'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($true,'fresh','bad',1200,$false,1), @($true,'fresh','future',1500,$false,1)) },
    @{ name = 'last_update slightly in the future (<= 300 s) clamps to age 0 and is a hit, never a miss'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($true,'fresh','soon',1200,$false,0)) },
    @{ name = 'confirmed recovery clears the alert'; steps = @(@($true,'fresh',4000,0,$false,0), @($true,'fresh',4300,300,$false,0), @($true,'fresh',4600,600,$false,0), @($true,'fresh',4900,900,$true,1), @($true,'fresh',60,1200,$false,0)) }
  )
  $fails = 0; $t0 = 1800000000
  foreach ($c in $cases) {
    $st = @{}; $ok = $true; $trace = @(); $alert = 0
    foreach ($s in $c.steps) {
      $entry = $null
      if ($s[0]) {
        $lu = $null
        switch ("$($s[2])") { 'zero' { $lu = 0 } 'none' { $lu = $null } 'future' { $lu = $t0 + $s[3] + 3600 } 'soon' { $lu = $t0 + $s[3] + 120 } 'bad' { $lu = '12abc' } default { $lu = $t0 + $s[3] - [int]$s[2] } }
        $entry = [pscustomobject]@{ heartbeat_status = $s[1]; last_update = $lu }
      }
      $r = Update-NetViewState $st ([bool]$s[0]) $entry ([int64]($t0 + $s[3])) 3600
      if ($r.fire) { $alert = 1 } elseif ($r.outcome -eq 'hit') { $alert = 0 }   # caller wiring under test
      $trace += "t+$($s[3])s $($r.outcome) fire=$($r.fire) alert=$alert"
      if (($r.fire -ne [bool]$s[4]) -or ($alert -ne [int]$s[5])) { $ok = $false }
    }
    if ($ok) { Write-Output "PASS  $($c.name)" } else { $fails++; Write-Output "FAIL  $($c.name): $($trace -join ' | ')" }
  }
  # validator against the shared fixtures
  $total = $cases.Count
  $fxdir = Join-Path (Split-Path -Parent $PSScriptRoot) 'test\netview-fixtures'
  $expected = Get-Content (Join-Path $fxdir 'expected.json') -Raw | ConvertFrom-Json
  foreach ($f in Get-ChildItem $fxdir -Filter '*.json' | Where-Object { $_.Name -ne 'expected.json' }) {
    $total++; $exp = $expected.($f.Name); $parsed = $null; try { $parsed = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch {}
    $got = $(if (Test-NetViewRoster $parsed) { 'ok' } else { 'bad' })
    if ($got -eq $exp) { Write-Output "PASS  validator: $($f.Name) -> $got" } else { $fails++; Write-Output "FAIL  validator: $($f.Name) expected $exp got $got" }
  }
  # fork peer helper (pure): startingheight only, one peer cannot set the maximum
  $pcases = @(
    @{ name = 'fork peers: one peer far ahead, two at our height -> 1 of 3 ahead'; json = '[{"startingheight":1500},{"startingheight":1000},{"startingheight":1000}]'; exp = '1 3 1 1500' },
    @{ name = 'fork peers: two peers 50 ahead -> none ahead (gap 100)'; json = '[{"startingheight":1050},{"startingheight":1050}]'; exp = '1 2 0 1050' },
    @{ name = 'fork peers: two peers 500 ahead -> 2 of 3 ahead'; json = '[{"startingheight":1500},{"startingheight":1500},{"startingheight":900}]'; exp = '1 3 2 1500' },
    @{ name = 'fork peers: synced_headers is ignored'; json = '[{"startingheight":1000,"synced_headers":9999},{"startingheight":1000,"synced_headers":9999}]'; exp = '1 2 0 1000' },
    @{ name = 'fork peers: empty array is no data'; json = '[]'; exp = '0 0 0 0' },
    @{ name = 'fork peers: non-JSON is no data'; json = 'garbage'; exp = '0 0 0 0' },
    @{ name = 'fork peers: a row without startingheight makes the read no data'; json = '[{"startingheight":1500},{"addr":"x"}]'; exp = '0 0 0 0' },
    @{ name = 'fork peers: a non-numeric startingheight makes the read no data'; json = '[{"startingheight":"1500"},{"startingheight":1500}]'; exp = '0 0 0 0' }
  )
  foreach ($c in $pcases) {
    $total++; $parsed = $null; try { $parsed = $c.json | ConvertFrom-Json } catch { $parsed = $null }
    $pa = Get-ForkPeersAhead $parsed ([int64]1000) 100
    $got = "$(if ($pa.ok) { 1 } else { 0 }) $($pa.peers) $($pa.ahead) $($pa.claim)"
    if ($got -eq $c.exp) { Write-Output "PASS  $($c.name)" } else { $fails++; Write-Output "FAIL  $($c.name): expected [$($c.exp)] got [$got]" }
  }
  # fork detector transitions: steps (readok, ahead_n, ours, ibd, lag, expectOutcome, expectFire ('0'|'deadbranch'|'stalledsync'), expectAlertAfter)
  $fcases = @(
    @{ name = 'fork: first read is unknown (no baseline); stuck x3 fires deadbranch when the node looks synced'; steps = @(@($true,2,1000,'false',0,'unknown','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','deadbranch',1)) },
    @{ name = 'fork: one peer ahead is below the minimum: unknown without a baseline, then ok while headers advance'; steps = @(@($true,1,1000,'false',0,'unknown','0',0), @($true,1,1020,'false',0,'ok','0',0), @($true,1,1040,'false',0,'ok','0',0), @($true,1,1060,'false',0,'ok','0',0)) },
    @{ name = 'fork: ahead peers disconnect with no local progress: unconfirmed, alert retained; clears once headers advance'; steps = @(@($true,2,1000,'false',0,'unknown','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','deadbranch',1), @($true,0,1000,'false',0,'unconfirmed','0',1), @($true,1,1000,'false',0,'unconfirmed','0',1), @($true,0,1020,'false',0,'ok','0',0)) },
    @{ name = 'fork: advancing catch-up never fires'; steps = @(@($true,2,1000,'true',0,'unknown','0',0), @($true,2,5000,'true',3000,'catchup','0',0), @($true,2,9000,'true',2000,'catchup','0',0), @($true,2,13000,'true',1000,'catchup','0',0), @($true,2,17000,'false',5,'catchup','0',0)) },
    @{ name = 'fork: stuck in IBD fires stalledsync, not deadbranch'; steps = @(@($true,2,1000,'true',0,'unknown','0',0), @($true,2,1000,'true',0,'stuck','0',0), @($true,2,1000,'true',0,'stuck','0',0), @($true,2,1000,'true',0,'stuck','stalledsync',1)) },
    @{ name = 'fork: headers far ahead of blocks fires stalledsync'; steps = @(@($true,2,1000,'false',500,'unknown','0',0), @($true,2,1000,'false',500,'stuck','0',0), @($true,2,1000,'false',500,'stuck','0',0), @($true,2,1000,'false',500,'stuck','stalledsync',1)) },
    @{ name = 'fork: a catch-up read resets the streak; stuck counts again from 1'; steps = @(@($true,2,1000,'false',0,'unknown','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1450,'false',0,'catchup','0',0), @($true,2,1450,'false',0,'stuck','0',0), @($true,2,1450,'false',0,'stuck','0',0), @($true,2,1450,'false',0,'stuck','deadbranch',1)) },
    @{ name = 'fork: an active alert survives unknown and the following stuck read (no false recovery); only ok clears'; steps = @(@($true,2,1000,'false',0,'unknown','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','deadbranch',1), @($false,0,1000,'false',0,'unknown','0',1), @($true,2,1000,'false',0,'stuck','0',1), @($true,2,1000,'false',0,'stuck','0',1), @($true,2,1000,'false',0,'stuck','deadbranch',1), @($true,0,1020,'false',0,'ok','0',0)) },
    @{ name = 'fork: catch-up does not clear an active alert'; steps = @(@($true,2,1000,'false',0,'unknown','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','0',0), @($true,2,1000,'false',0,'stuck','deadbranch',1), @($true,2,1500,'false',0,'catchup','0',1), @($true,0,1520,'false',0,'ok','0',0)) }
  )
  foreach ($c in $fcases) {
    $st = @{}; $ok = $true; $trace = @(); $alert = 0; $total++
    foreach ($s in $c.steps) {
      $r = Update-ForkState $st 'x-fork-miss' ([bool]$s[0]) ([int]$s[1]) ([int64]$s[2]) ([string]$s[3]) ([int64]$s[4]) 2 100
      $fired = '0'; if ($r.fire) { $fired = $r.class }
      if ($r.fire) { $alert = 1 } elseif ($r.outcome -eq 'ok') { $alert = 0 }   # caller wiring under test: only ok clears
      $trace += "$($r.outcome)/$fired/a$alert"
      if (($r.outcome -ne $s[5]) -or ($fired -ne $s[6]) -or ($alert -ne [int]$s[7])) { $ok = $false }
    }
    if ($ok) { Write-Output "PASS  $($c.name)" } else { $fails++; Write-Output "FAIL  $($c.name): $($trace -join ' | ')" }
  }
  Write-Output "netview self-test: $($total - $fails)/$total passed"; exit $fails
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
