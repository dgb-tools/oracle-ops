# Anchor-node keeper for the "rpc-accept-dead" class. Runs from a scheduled task every 5 min.
# Class (observed 2026-09-08/09, DigiByte Core v9.26.5, Windows): the digibyted process is
# alive and still processing blocks, the RPC port is bound (LISTENING), nothing is connected,
# yet every RPC connect times out - the HTTP accept loop is dead. debug.log keeps growing, so
# "log has not grown" must NOT be part of the detection (it would never fire). This is
# distinct from `process-hung` (height not advancing, log stall), which this script only
# records. Detection: 5 consecutive failed RPC probes (connect + authenticated getblockcount)
# spaced ProbeSeconds apart, against the SAME live PID. Remedy: kill that PID, wait for the
# port to free, run the boot task once, verify a new PID answers RPC; if not, run once more;
# then alert and stop. Restart budget prevents a kill loop.
param(
  [string]$Cli = 'C:\DigiByte-DD\daemon\digibyte-cli.exe',
  [string]$Datadir = 'C:\dgb-anchor',
  [int]$RpcPort = 14022,
  [string]$TaskName = 'DGB Anchor Node',
  [int]$Probes = 5, [int]$ProbeSeconds = 60, [int]$RpcTimeout = 10,
  [int]$MaxRestartsPerDay = 3,
  [string]$NtfyServer = 'https://ntfy.sh', [string]$NtfyTopic = '',
  [switch]$DryRun,
  [switch]$InduceFailure   # test mode: probe a port nothing listens on, so the whole path runs without a real wedge (DryRun implied)
)
$Log = Join-Path $Datadir 'anchor-keeper.log'; $Budget = Join-Path $Datadir 'anchor-keeper.restarts'; $Lock = Join-Path $Datadir 'anchor-keeper.lock'
function L([string]$m) { $line = "$(Get-Date -Format s) $m"; Add-Content -Path $Log -Value $line; Write-Output $line }
function Notify([string]$t, [string]$b) { if (-not $NtfyTopic) { return }; try { Invoke-RestMethod -Method Post -Uri "$NtfyServer/$NtfyTopic" -Body $b -Headers @{ Title = $t; Priority = 'high' } -TimeoutSec 15 | Out-Null } catch { L "NOTIFY-FAIL $($_.Exception.Message)" } }
function Get-Daemon { Get-CimInstance Win32_Process -Filter "name='digibyted.exe'" | Where-Object { $_.CommandLine -like "*-datadir=$Datadir*" } | Select-Object -First 1 }
function Port-Listening { (netstat -ano | Select-String ":$RpcPort\s+\S+\s+LISTENING") -ne $null }
function Rpc-Probe { if ($InduceFailure) { return @{ ok = $false; err = 'induced' } }
  try { $o = (& $Cli "-datadir=$Datadir" "-rpcclienttimeout=$RpcTimeout" getblockcount 2>&1 | Out-String).Trim()
    if ($o -match '^\d+$') { return @{ ok = $true; height = [int]$o } }
    if ($o -match 'error code: -28') { return @{ ok = $true; loading = $true } }   # RPC answers; node is loading - healthy for this class
    return @{ ok = $false; err = $o.Substring(0, [Math]::Min(160, $o.Length)) } } catch { return @{ ok = $false; err = $_.Exception.Message } } }
function Log-Height { try { $l = Get-Content (Join-Path $Datadir 'debug.log') -Tail 400 | Select-String 'UpdateTip: new best=\S+ height=(\d+)' | Select-Object -Last 1; if ($l) { [int]$l.Matches[0].Groups[1].Value } else { -1 } } catch { -1 } }
function Restarts-Today { if (Test-Path $Budget) { (Get-Content $Budget | Where-Object { $_ -like "$(Get-Date -Format yyyy-MM-dd)*" }).Count } else { 0 } }

# singleton
if (Test-Path $Lock) { $age = ((Get-Date) - (Get-Item $Lock).LastWriteTime).TotalMinutes; if ($age -lt 20) { exit 0 } }
Set-Content -Path $Lock -Value $PID
try {
  $d0 = Get-Daemon
  if (-not $d0) { L "no daemon for $Datadir; this keeper handles the alive-but-RPC-dead class only; boot task owns cold starts"; exit 0 }
  $h0 = Log-Height; $fails = 0; $evidence = @()
  for ($i = 1; $i -le $Probes; $i++) {
    $d = Get-Daemon; if (-not $d -or $d.ProcessId -ne $d0.ProcessId) { L "PID changed during probing ($($d0.ProcessId) -> $($d.ProcessId)); standing down"; exit 0 }
    $p = Rpc-Probe
    if ($p.ok) { if ($fails -gt 0) { L "RPC recovered after $fails failure(s)" }; exit 0 }
    $fails++; $ev = "probe $i/$Probes pid=$($d.ProcessId) port_listening=$(Port-Listening) log_height=$(Log-Height) err=$($p.err)"; $evidence += $ev; L $ev
    if ($i -lt $Probes) { Start-Sleep -Seconds $ProbeSeconds }
  }
  $h1 = Log-Height; $class = if ($h1 -gt $h0) { 'rpc-accept-dead' } else { 'process-hung' }
  L "CLASS $class (log height $h0 -> $h1) after $Probes consecutive failures on pid $($d0.ProcessId), started $($d0.CreationDate)"
  if ($class -eq 'process-hung') { Notify 'DGB anchor: process-hung' "Height not advancing ($h0 -> $h1) and RPC dead on pid $($d0.ProcessId). Not auto-restarted by this keeper (different class). Investigate."; L "process-hung: recorded, not restarted"; exit 0 }
  if ((Restarts-Today) -ge $MaxRestartsPerDay) { Notify 'DGB anchor: restart budget exhausted' "rpc-accept-dead again on pid $($d0.ProcessId) but $MaxRestartsPerDay restarts already today. Manual attention."; L "budget exhausted; not restarting"; exit 0 }
  if ($DryRun -or $InduceFailure) { L "DRYRUN: would kill pid $($d0.ProcessId), wait for port $RpcPort to free, run task '$TaskName' once, verify RPC, retry once, alert"; exit 0 }
  Add-Content -Path $Budget -Value "$(Get-Date -Format s) pid=$($d0.ProcessId) class=$class"
  Stop-Process -Id $d0.ProcessId -Force; L "killed pid $($d0.ProcessId)"
  $t = 0; while ((Port-Listening) -and $t -lt 60) { Start-Sleep -Seconds 2; $t += 2 }; L "port free after ${t}s"
  schtasks /Run /TN "$TaskName" | Out-Null; Start-Sleep -Seconds 60
  $n = Get-Daemon; $p = Rpc-Probe
  if (-not $n -or -not $p.ok) { L "first boot-task run: daemon=$([bool]$n) rpc=$($p.ok); running the task once more"; schtasks /Run /TN "$TaskName" | Out-Null; Start-Sleep -Seconds 60; $n = Get-Daemon; $p = Rpc-Probe }
  if ($n -and $p.ok) { L "RESTARTED: new pid $($n.ProcessId), rpc ok (loading=$($p.loading))"; Notify 'DGB anchor: restarted (rpc-accept-dead)' ("Evidence:`n" + ($evidence -join "`n") + "`nKilled $($d0.ProcessId); new pid $($n.ProcessId). Restarts today: $(Restarts-Today)/$MaxRestartsPerDay.") }
  else { L "RESTART FAILED: daemon=$([bool]$n) rpc=$($p.ok)"; Notify 'DGB anchor: RESTART FAILED' ("Evidence:`n" + ($evidence -join "`n") + "`nKilled $($d0.ProcessId); after two boot-task runs daemon=$([bool]$n) rpc=$($p.ok). Manual start needed.") }
} finally { Remove-Item -Path $Lock -ErrorAction SilentlyContinue }
