#!/usr/bin/env bash
# DigiByte Oracle Monitor (Linux) — a personal watchdog for YOUR DigiDollar
# oracle slot. Bash port of the Windows monitor in ../monitor/.
#
# Read-only: status RPCs only; never touches keys, wallets, or passphrases.
# Auto-restart on Linux is systemd's job (Restart=always in digibyted.service,
# see ../linux/systemd/) — this script DETECTS restarts and tells you what
# crashed, so a recovered daemon is never a silent mystery.
#
# Requirements: bash, curl, jq. Runs every 5 minutes via the systemd timer
# installed by install.sh, or from cron: */5 * * * * /path/to/dgb-oracle-monitor.sh
#
# Usage: dgb-oracle-monitor.sh [--test]   (--test sends a test alert and exits)

set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
CONF="$BASE/config"
LOG="$BASE/monitor.log"
STATE="$BASE/state"

if [ "${1:-}" != "--netview-selftest" ]; then [ -f "$CONF" ] || { echo "No config found at $CONF. Copy config.example to config and edit it." >&2; exit 1; }; fi
command -v jq   >/dev/null || { echo "jq is required (apt install jq / dnf install jq)." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
# shellcheck source=/dev/null
if [ "${1:-}" != "--netview-selftest" ]; then . "$CONF"; fi
mkdir -p "$STATE"
NOW=$(date -u +%s)

log() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 5242880 ]; then mv -f "$LOG" "$LOG.old"; fi
  echo "$(date -u +%FT%TZ) $*" >> "$LOG"
}

notify() { # title body priority tags
  local title="$1" body="$2" prio="$3" tags="$4" sent=0
  if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -fsS -m 15 -X POST "$NTFY_SERVER/$NTFY_TOPIC" -d "$body" \
      -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" >/dev/null 2>&1 && sent=1 \
      || log "NOTIFY-FAIL ntfy"
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -m 15 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$title

$body" >/dev/null 2>&1 && sent=1 || log "NOTIFY-FAIL telegram"
  fi
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -fsS -m 15 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg t "$title" --arg b "$body" --arg p "$prio" '{title:$t, body:$b, priority:$p}')" \
      >/dev/null 2>&1 && sent=1 || log "NOTIFY-FAIL webhook"
  fi
  log "NOTIFY sent=$sent [$prio] $title"
}

# Failure dedup + recovery, mirroring the Windows monitor: alerts re-send
# every REALERT_HOURS; every failure gets a matching RECOVERED notice.
report_check() { # key ok(1|0) title body [priority]
  local key="$1" ok="$2" title="$3" body="$4" prio="${5:-high}"
  local f="$STATE/down_$key" last=0
  if [ "$ok" != "1" ]; then
    [ -f "$f" ] && last=$(cat "$f" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac   # empty/garbage state file -> re-alert, never crash
    if [ $((NOW - last)) -ge $((REALERT_HOURS * 3600)) ]; then
      notify "$title" "$body" "$prio" rotating_light
      echo "$NOW" > "$f"
    fi
    log "CHECK FAIL $key"
  elif [ -f "$f" ]; then
    rm -f "$f"
    notify "RECOVERED: $key" "Condition cleared at $(date -u +%FT%TZ)." default white_check_mark
    log "CHECK RECOVERED $key"
  fi
}

state_get() { [ -f "$STATE/$1" ] && cat "$STATE/$1" || echo "${2:-}"; }
state_set() { echo "$2" > "$STATE/$1"; }

cli_testnet() { "$CLI_EXE" -datadir="$DATADIR" -testnet "$@" 2>/dev/null; }
# Network view: a node we do not run, asked what it sees for our slot (default digibyte.io's node).
# Unauthenticated, no published rate limit: query it only at this monitor's cadence.
NETVIEW_URL="${NETVIEW_URL:-https://digibyte.io/api/getoracles}"
NETVIEW_STALE_SECONDS="${NETVIEW_STALE_SECONDS:-3600}"   # last_update older than this with a fresh heartbeat = miss
# Network-view state machine (pure except for the state files). Rules, per crew review 2026-10-06:
#  MISS  = successful read, heartbeat fresh, last_update older than $5 seconds (or unset).
#  FIRE  = a successful MISS that is the 3rd+ consecutive miss AND >= 900 s after the first of the streak.
#  UNKNOWN (read not ok) = never a miss, never a hit, never fires, never clears: pending streak reset,
#          alert state untouched (report_check is not called).
# args: readok(1|0) heartbeat_status last_update(unix|0) now stale_seconds -> NV_FIRE NV_MISS NV_STREAK NV_AGE NV_MINUTES
netview_update() {
  local readok="$1" hb="$2" lu="$3" now="$4" stale="$5" streak since miss=0
  streak=$(state_get net-miss 0); since=$(state_get net-miss-since "$now")
  NV_FIRE=0; NV_MISS=0; NV_STREAK=0; NV_AGE=-1; NV_MINUTES=0
  if [ "$readok" != "1" ]; then state_set net-miss 0; return 0; fi
  NV_AGE=-1; [ "$lu" -gt 0 ] 2>/dev/null && NV_AGE=$((now - lu))
  if [ "$hb" = "fresh" ] && { [ "$NV_AGE" -lt 0 ] || [ "$NV_AGE" -gt "$stale" ]; }; then miss=1; fi
  if [ "$miss" = "1" ]; then [ "$streak" = "0" ] && since=$now; streak=$((streak + 1)); else streak=0; since=$now; fi
  state_set net-miss "$streak"; state_set net-miss-since "$since"; state_set net-last-ok-read "$now"
  NV_MISS=$miss; NV_STREAK=$streak; NV_MINUTES=$(( (now - since) / 60 ))
  [ "$miss" = "1" ] && [ "$streak" -ge 3 ] && [ $((now - since)) -ge 900 ] && NV_FIRE=1
  return 0
}

cli_mainnet() { "$CLI_EXE" -datadir="$DATADIR" -testnet=0 -chain=main "$@" 2>/dev/null; }

# Known crash classes, matched against the daemon's recent journal (or
# debug.log when there is no systemd service). Tells you WHAT died, not just
# that it died.
crash_class() { # chain-label
  local src=""
  if [ -n "${DAEMON_SERVICE:-}" ]; then
    src=$(journalctl -u "$DAEMON_SERVICE" -n 400 --no-pager 2>/dev/null)
  fi
  if [ -z "$src" ]; then
    local lf="$DATADIR/debug.log"
    [ "$1" = "testnet" ] && lf="$DATADIR/testnet26/debug.log"
    [ -f "$lf" ] && src=$(tail -n 400 "$lf" 2>/dev/null)
  fi
  [ -z "$src" ] && { echo "no log source readable"; return; }
  if grep -qE 'length_error|vector::reserve' <<< "$src"; then
    echo "oversized-message crash (class seen network-wide in the Aug 2026 incident) - restart is safe; make sure you are on the latest release"
  elif grep -q 'bad_alloc' <<< "$src"; then
    echo "out-of-memory - check RAM/dbcache before it repeats"
  elif grep -q 'Assertion failed' <<< "$src"; then
    echo "assertion failure - capture the log before it rotates and report to DigiByte Core"
  elif grep -q 'Corrupted block database' <<< "$src"; then
    echo "block database corruption - the node will likely need -reindex; see runbook"
  elif grep -q 'Disk space is too low' <<< "$src"; then
    echo "disk full"
  else
    echo "no known crash signature in recent log (clean stop, kill, or a new class)"
  fi
}

check_chain() { # label clifn ismainnet(1|0)
  # Liveness is judged by the RPC, not by process-name sniffing: on Linux a
  # mainnet daemon is typically started with no chain flags at all, so there
  # is nothing reliable to pattern-match, and dual-chain boxes make it worse.
  # RPC answering = that chain is up. RPC dead + no digibyted process = down.
  local label="$1" clifn="$2" ismainnet="$3"
  local summary=""

  local bc; bc=$($clifn getblockchaininfo)
  if [ -z "$bc" ]; then
    if pgrep -x digibyted >/dev/null 2>&1; then
      report_check "$label-daemon" 1 "" ""
      report_check "$label-rpc" 0 "DGB oracle box: $label RPC unreachable" \
        "A digibyted process exists but $label RPC is not answering (starting up, verifying blocks, or running with different chain flags than the monitor expects)." high
      echo "$label: RPC not answering"
      return
    fi
    local body="digibyted ($label) is not running.
Crash-class read: $(crash_class "$label")"
    if [ -n "${DAEMON_SERVICE:-}" ]; then
      body="$body
systemd should restart it (Restart=always). If this alert repeats, systemd has given up - log in and check: systemctl status $DAEMON_SERVICE"
    else
      body="$body
No systemd service configured - log in and start the daemon, or install digibyted.service from the kit."
    fi
    report_check "$label-daemon" 0 "DGB oracle box: $label daemon DOWN" "$body" urgent
    echo "$label: DAEMON DOWN"
    return
  fi
  report_check "$label-daemon" 1 "" ""
  report_check "$label-rpc" 1 "" ""

  # Extract with `// empty` and verify numeric BEFORE any arithmetic: a
  # partial or malformed getblockchaininfo must degrade to an alert, never
  # crash this subshell (a crashed subshell would log a healthy-looking PASS
  # in the parent - found in crew review under a mocked CLI).
  local blocks headers ibd tiptime lag tipage synced=0
  blocks=$(jq -r '.blocks // empty' <<< "$bc"); headers=$(jq -r '.headers // empty' <<< "$bc")
  # NOTE: no `// empty` on the boolean - jq's // treats false as absent and
  # would swallow a legitimate ibd=false (found by the mock test). Plain
  # extraction is safe here: only the exact string "false" counts as synced,
  # so a missing field ("null") already fails closed, and it is never used
  # in arithmetic.
  ibd=$(jq -r '.initialblockdownload' <<< "$bc")
  tiptime=$(jq -r '.time // .mediantime // empty' <<< "$bc")
  case "$blocks"  in ''|*[!0-9]*) blocks=""  ;; esac
  case "$headers" in ''|*[!0-9]*) headers="" ;; esac
  case "$tiptime" in ''|*[!0-9]*) tiptime="" ;; esac
  if [ -z "$blocks" ] || [ -z "$headers" ] || [ -z "$tiptime" ]; then
    report_check "$label-rpcdata" 0 "DGB oracle box: $label RPC returned malformed data" \
      "getblockchaininfo answered but blocks/headers/time were missing or non-numeric. Node may be mid-startup or the RPC output is unexpected - treating as NOT healthy." high
    echo "$label: RPC data malformed"
    return
  fi
  report_check "$label-rpcdata" 1 "" ""
  lag=$((headers - blocks)); tipage=$((NOW - tiptime))
  [ "$ibd" = "false" ] && [ "$lag" -lt 10 ] && [ "$tipage" -lt 1800 ] && synced=1
  report_check "$label-sync" "$synced" "DGB oracle box: $label node NOT SYNCED" \
    "blocks=$blocks headers=$headers ibd=$ibd tip_age_sec=$tipage" high
  summary="$label h=$blocks"

  local wallets wloaded=0
  wallets=$($clifn listwallets)
  jq -e --arg w "$ORACLE_WALLET" 'index($w) != null' <<< "$wallets" >/dev/null 2>&1 && wloaded=1
  report_check "$label-wallet" "$wloaded" "DGB oracle box: $label wallet '$ORACLE_WALLET' NOT LOADED" \
    "listwallets does not include '$ORACLE_WALLET'. Check settings.json autoload; loadwallet to fix." urgent

  # Oracle slot check (mainnet: only once DigiDollar is active)
  local ddactive=1
  if [ "$ismainnet" = "1" ]; then
    local dep depstatus prev
    dep=$($clifn getdigidollardeploymentinfo)
    if [ -n "$dep" ]; then
      depstatus=$(jq -r .status <<< "$dep")
      [ "$depstatus" = "active" ] || ddactive=0
      prev=$(state_get mainnet-dd-status "")
      if [ -n "$prev" ] && [ "$prev" != "$depstatus" ]; then
        notify "DigiDollar mainnet: $prev -> $depstatus" "Deployment state changed." default information_source
      fi
      state_set mainnet-dd-status "$depstatus"
      summary="$summary DD=$depstatus"
    fi
  fi

  if [ "$ddactive" = "1" ]; then
    local roster me reporting=0 detail
    roster=$($clifn getoracles false)
    me=$(jq -c --argjson id "$ORACLE_ID" '[.[] | select(.oracle_id == $id)] | first // empty' <<< "$roster" 2>/dev/null)
    if [ -n "$me" ]; then
      local st loc hb hbage sig
      st=$(jq -r .status <<< "$me"); loc=$(jq -r .is_running_locally <<< "$me")
      hb=$(jq -r .heartbeat_status <<< "$me"); hbage=$(jq -r .heartbeat_age_seconds <<< "$me")
      sig=$(jq -r .heartbeat_signature_valid <<< "$me")
      [ "$st" = "reporting" ] && [ "$loc" = "true" ] && [ "$hb" = "fresh" ] && [ "$sig" = "true" ] && reporting=1
      detail="status=$st local=$loc hb=$hb hb_age=${hbage}s sig_ok=$sig"
      summary="$summary $label-o$ORACLE_ID=$st/$hb"
    else
      detail="slot $ORACLE_ID absent from getoracles output"
      summary="$summary $label-o$ORACLE_ID=missing"
    fi
    local obody="$label oracle $ORACLE_ID is not signing. $detail"
    if [ "$wloaded" = "1" ] && [ "$reporting" = "0" ]; then
      local wi unlocked
      wi=$($clifn -rpcwallet="$ORACLE_WALLET" getwalletinfo)
      unlocked=$(jq -r '.unlocked_until // "none"' <<< "$wi" 2>/dev/null)
      if [ "$unlocked" = "0" ] && [ "$ismainnet" = "1" ]; then
        obody="$obody
Wallet is LOCKED (likely after a restart). Fix:
digibyte-cli -testnet=0 -chain=main -rpcwallet=$ORACLE_WALLET walletpassphrase \"<passphrase>\" <seconds>
digibyte-cli -testnet=0 -chain=main -rpcwallet=$ORACLE_WALLET startoracle $ORACLE_ID"
      fi
    fi
    report_check "$label-oracle$ORACLE_ID" "$reporting" "DGB ORACLE $ORACLE_ID ($label) NOT REPORTING" "$obody" urgent
    # NETWORK-VIEW check (mainnet only). The node's self-view cannot see a silent price broadcast
    # (slot 29, Oct 2026). Ask a node we do not run. The roster's `status` churns every 40-block
    # round and is NOT the signal; a fresh heartbeat with a stale last_update is. Transitions live in
    # netview_update (pure; --netview-selftest); this block only fetches and reports.
    if [ "$ismainnet" = "1" ]; then
      local nraw nme nids nhb nlu readok=0
      nraw=$(curl -fsS -m 20 -H "User-Agent: dgb-oracle-monitor (slot $ORACLE_ID)" -H 'Accept: application/json' "$NETVIEW_URL" 2>/dev/null || true)
      nids=$(jq -r 'if type=="array" then [.[].oracle_id] | unique | length else 0 end' <<< "$nraw" 2>/dev/null || echo 0)
      nme=""; [ "$nids" = "35" ] && nme=$(jq -c --argjson id "$ORACLE_ID" '[.[] | select(.oracle_id == $id)] | first // empty' <<< "$nraw" 2>/dev/null)
      if [ -n "$nme" ]; then readok=1; nhb=$(jq -r '.heartbeat_status // "n/a"' <<< "$nme"); nlu=$(jq -r '.last_update // 0' <<< "$nme"); else nhb=""; nlu=0; fi
      netview_update "$readok" "$nhb" "$nlu" "$NOW" "$NETVIEW_STALE_SECONDS"   # sets NV_FIRE NV_MISS NV_STREAK NV_AGE NV_MINUTES
      if [ "$readok" = "1" ]; then
        local netok=1; [ "$NV_FIRE" = "1" ] && netok=0
        report_check "$label-oracle$ORACLE_ID-networkview" "$netok" "DGB ORACLE $ORACLE_ID NOT OBSERVED BY THE NETWORK-VIEW NODE" \
          "The observer at $NETVIEW_URL has not received a price from slot $ORACLE_ID for ${NV_AGE}s (heartbeat $nhb, status $(jq -r '.status // "?"' <<< "$nme"), price_source $(jq -r '.price_source // "?"' <<< "$nme")) across $NV_STREAK consecutive reads over $NV_MINUTES minutes, while this node reports ${detail}. This is one observer's view, not network proof. Corroborate first: read the same URL again in 15 minutes and check your own listoracle. If last_update stays stale with a fresh heartbeat, the price broadcast is likely silent; the runbook's 'after any restart or upgrade' section gives the stop/start fix." urgent
        summary="$summary net-o$ORACLE_ID=$(jq -r '.status // "?"' <<< "$nme")/lu${NV_AGE}s"
      else
        log "netview check unknown (pending evidence reset, alert state untouched): ids=$nids slot=$([ -n "$nme" ] && echo present || echo absent) from $NETVIEW_URL"
      fi
    fi
  else
    summary="$summary $label-o$ORACLE_ID=staged(pre-activation)"
  fi
  echo "$summary"
}

# ---------- run ----------
if [ "${1:-}" = "--test" ]; then
  notify "DGB oracle monitor: test alert" "Monitor is installed and can reach you. Box time: $(date +%FT%T)" default wave
  exit 0
fi


if [ "${1:-}" = "--netview-selftest" ]; then
  STATE=$(mktemp -d); t0=1800000000; fails=0; total=0
  run_case() { # name; then steps "readok:hb:age|none:offset:expect" ...
    local name="$1"; shift; local ok=1 trace=""; rm -f "$STATE"/net-*; total=$((total + 1))
    for step in "$@"; do
      IFS=: read -r ro hb age off exp <<< "$step"; local lu=0
      if [ "$age" != "none" ]; then lu=$((t0 + off - age)); fi
      netview_update "$ro" "$hb" "$lu" "$((t0 + off))" 3600; trace="$trace t+${off}s fire=$NV_FIRE streak=$NV_STREAK |"
      [ "$NV_FIRE" = "$exp" ] || ok=0
    done
    if [ "$ok" = "1" ]; then echo "PASS  $name"; else fails=$((fails + 1)); echo "FAIL  $name:$trace"; fi
  }
  run_case "healthy reads never fire" 1:fresh:70:0:0 1:fresh:120:300:0 1:fresh:40:600:0
  run_case "three stale reads inside 10 min do NOT fire (elapsed gate)" 1:fresh:4000:0:0 1:fresh:4300:300:0 1:fresh:4600:600:0
  run_case "fourth stale read at 15 min fires" 1:fresh:4000:0:0 1:fresh:4300:300:0 1:fresh:4600:600:0 1:fresh:4900:900:1
  run_case "unknown ticks reset pending evidence and never fire (OEAE scenario)" 1:fresh:4000:0:0 1:fresh:4300:300:0 0::0:600:0 0::0:900:0 1:fresh:5500:1500:0 1:fresh:5800:1800:0 1:fresh:6100:2100:0 1:fresh:6400:2400:1
  run_case "stale heartbeat with stale last_update is not a miss (restart/index load)" 1:stale:9000:0:0 1:stale:9300:300:0 1:stale:9600:600:0 1:stale:9900:900:0
  run_case "unset last_update with fresh heartbeat counts as stale" 1:fresh:none:0:0 1:fresh:none:300:0 1:fresh:none:600:0 1:fresh:none:900:1
  run_case "a hit clears the streak" 1:fresh:4000:0:0 1:fresh:4300:300:0 1:fresh:50:600:0 1:fresh:4000:900:0 1:fresh:4300:1200:0 1:fresh:4600:1500:0
  echo "netview self-test: $((total - fails))/$total passed"; rm -rf "$STATE"; exit $fails
fi

PARTS=""
[ "${MONITOR_TESTNET:-0}" = "1" ] && PARTS="$PARTS $(check_chain testnet cli_testnet 0)"
[ "${MONITOR_MAINNET:-0}" = "1" ] && PARTS="$PARTS $(check_chain mainnet cli_mainnet 1)"

# systemd restart detection: if NRestarts grew since last run, the daemon
# crashed and came back on its own - say so, with the crash class.
if [ -n "${DAEMON_SERVICE:-}" ] && command -v systemctl >/dev/null; then
  cur=$(systemctl show "$DAEMON_SERVICE" -p NRestarts --value 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" -ge 0 ] 2>/dev/null; then
    prev=$(state_get nrestarts "$cur")
    case "$prev" in ''|*[!0-9]*) prev="$cur" ;; esac
    if [ "$cur" -gt "$prev" ]; then
      notify "DGB daemon auto-restarted by systemd ($((cur - prev))x since last check)" \
        "The node came back on its own; verify your oracle resumed (encrypted wallets need a manual unlock).
Crash-class read: $(crash_class mainnet)" high arrows_counterclockwise
      log "SYSTEMD-RESTART detected: $prev -> $cur"
    fi
    state_set nrestarts "$cur"
  fi
fi

# Disk space
free_gb=$(df -BG --output=avail "$DATADIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$free_gb" ]; then
  ok=0; [ "$free_gb" -gt "$MIN_FREE_DISK_GB" ] && ok=1
  report_check disk "$ok" "DGB oracle box: LOW DISK" \
    "Datadir volume has ${free_gb} GB free (threshold $MIN_FREE_DISK_GB GB)." high
fi

# Version drift vs GitHub (checked hourly). /releases/latest excludes prereleases, so release
# candidates never page. Hourly because a mandatory release can ship with a deadline; one
# unauthenticated GitHub API call per hour is far inside the 60/hour limit.
lastvc=$(state_get ver-check-ts 0)
if [ $((NOW - lastvc)) -gt 3600 ]; then
  state_set ver-check-ts "$NOW"
  latest=$(curl -fsS -m 20 -H 'User-Agent: dgb-oracle-monitor' \
    https://api.github.com/repos/DigiByte-Core/digibyte/releases/latest 2>/dev/null | jq -r .tag_name | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  clifn=cli_mainnet; [ "${MONITOR_MAINNET:-0}" = "1" ] || clifn=cli_testnet
  local_ver=$($clifn getnetworkinfo | jq -r .subversion 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -n "$latest" ] && [ -n "$local_ver" ]; then
    ok=0
    [ "$(printf '%s\n%s\n' "$latest" "$local_ver" | sort -V | tail -1)" = "$local_ver" ] && ok=1
    report_check version "$ok" "DGB oracle box: version drift" \
      "Local $local_ver < latest release $latest. Read the release notes for an upgrade deadline, then plan the upgrade (see runbook for the proven two-chain procedure)." default
  fi
fi

# Daily heartbeat
today=$(date +%F)
if [ "${HEARTBEAT_ENABLED:-0}" = "1" ] && [ "$(state_get hb-date '')" != "$today" ] && [ "$(date +%-H)" -ge "$HEARTBEAT_HOUR" ]; then
  state_set hb-date "$today"
  downs=""
  for f in "$STATE"/down_*; do
    [ -e "$f" ] || continue
    downs="$downs${f##*/down_} "
  done
  status="all checks passing"; [ -n "$downs" ] && status="OPEN ISSUES: $downs"
  notify "DGB oracle daily heartbeat" "$status
$PARTS" min satellite
fi

log "PASS$PARTS"
