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

# ---------- per-chain checks ----------
function Check-Chain([string]$Label, [string[]]$Net, [string]$ProcPattern, [bool]$IsMainnet) {
  $summary = @()

  $proc = Get-CimInstance Win32_Process -Filter "Name = 'digibyted.exe'" |
          Where-Object { $_.CommandLine -match $ProcPattern }
  Report-Check "$Label-daemon" ([bool]$proc) "DGB oracle box: $Label daemon DOWN" `
    "digibyted ($Label) is not running. If a scheduled task should restart it and this repeats, log in and investigate." 'urgent'
  if (-not $proc) { return ,@("${Label}: DAEMON DOWN") }

  $bc = Get-DgbJson $Net @('getblockchaininfo')
  Report-Check "$Label-rpc" ([bool]$bc) "DGB oracle box: $Label RPC unreachable" `
    "Daemon process exists but RPC is not answering (may be starting up / verifying blocks)." 'high'
  if (-not $bc) { return ,@("${Label}: RPC not answering") }

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

  # Version drift vs GitHub (checked every 12h)
  $lastVc = 0; if ($State.ContainsKey('ver-check-ts')) { $lastVc = [int64]$State['ver-check-ts'] }
  if (($Now - $lastVc) -gt 43200) {
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
          "Local $local < latest release $latest ($($rel.tag_name)). Plan an upgrade." 'default'
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
