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
FORK_GAP_BLOCKS="${FORK_GAP_BLOCKS:-100}"        # a peer "claims ahead" when its startingheight exceeds our headers by more than this (triage threshold)
FORK_MIN_PEERS="${FORK_MIN_PEERS:-2}"            # this many peers must claim ahead at once; one erroneous peer cannot set the maximum
FORK_PROGRESS_BLOCKS="${FORK_PROGRESS_BLOCKS:-100}"  # headers advancing by at least this per cycle is a catch-up, not a stall
# Fork detector, crew review 2026-10-07. Oct 2026 lesson: a testnet node sat on a dead branch for 17 days while
# "headers == blocks" looked synced. The check compares our HEADERS with what connected peers CLAIM.
# startingheight is a peer's claim at connect, not a lower bound on the valid chain, so one peer cannot set it:
# FORK_MIN_PEERS peers must each claim more than FORK_GAP_BLOCKS above our headers. synced_headers is not used:
# per Core's help text it is "the last header we have in common with this peer", so it can never exceed ours.
# fork_peers_ahead (pure): args peers_json ourheaders gap -> FK_PEERS_OK(1|0) FK_PEERS_N FK_AHEAD_N FK_CLAIM(max).
# Any row without a numeric startingheight makes the whole read "no data" (same rule as the PowerShell monitor), so
# malformed peer data can neither page nor clear.
fork_peers_ahead() {
  local out
  out=$(jq -r --argjson o "$2" --argjson g "$3" 'if type=="array" and length>0 and all(.[]; type=="object" and (.startingheight|type=="number")) then
          ([.[] | (.startingheight // 0)]) as $sh | "1 \(length) \([$sh[] | select(. > $o + $g)] | length) \($sh | max)"
        else "0 0 0 0" end' <<< "$1" 2>/dev/null || echo "0 0 0 0")
  read -r FK_PEERS_OK FK_PEERS_N FK_AHEAD_N FK_CLAIM <<< "$out"
  case "$FK_PEERS_OK" in 1) ;; *) FK_PEERS_OK=0; FK_PEERS_N=0; FK_AHEAD_N=0; FK_CLAIM=0 ;; esac
}
# fork_update (pure except for state files). Outcomes (FK_OUTCOME):
#  unknown     = no peer data, or no persisted headers sample to measure progress against (the first read after a
#                cold start; the sample survives monitor restarts): pending reset, alert untouched.
#  ok          = fewer than FORK_MIN_PEERS peers claim ahead AND our headers advanced since the previous cycle: the
#                ONLY outcome that clears an alert.
#  unconfirmed = fewer than FORK_MIN_PEERS peers claim ahead but our headers did not move: the corroborating peers
#                may simply have disconnected, so this neither pages nor clears. Pending reset, alert untouched.
#  catchup     = enough peers claim ahead but our headers advanced >= FORK_PROGRESS_BLOCKS since the previous cycle
#                (a sync from behind moves far faster; a chain at 15 s blocks adds ~20 per 5-minute cycle, so a
#                branch that merely keeps chain pace is not catching up): pending reset, alert untouched.
#  stuck       = enough peers claim ahead and our headers advanced less than FORK_PROGRESS_BLOCKS (below the
#                threshold, not necessarily zero): pending evidence; the 3rd consecutive FIRES, i.e. the 4th read
#                after a cold start, 15 minutes after the first at the 5-minute cadence.
#  FK_CLASS on fire: deadbranch when the node looks synced locally (ibd=false and headers-blocks < 10), the pattern
#            of the incident, urgent; stalledsync otherwise (still in IBD, or headers far ahead of blocks), normal
#            priority, no reconsiderblock advice. Neither is a diagnosis: both say "investigate why local headers
#            trail peer claims". Known limit, and the kit has NO backstop for it: peers all on the same dead branch
#            never trip this; peers all claiming wrong heights would mis-trip it. A second node, an explorer, or
#            getchaintips elsewhere is the backstop. The network-view check is not one: it reads the mainnet
#            observer's price receipts, not chain agreement.
# args: key readok ahead_n ourheaders ibd lag [min_peers] [progress_blocks]
#  -> FK_OUTCOME (unknown|ok|unconfirmed|catchup|stuck) FK_FIRE FK_CLASS FK_STREAK FK_PROGRESS
fork_update() {
  local key="$1" readok="$2" an="$3" ours="$4" ibd="$5" lag="$6" minp="${7:-${FORK_MIN_PEERS:-2}}" prog="${8:-${FORK_PROGRESS_BLOCKS:-100}}" m prev
  m=$(state_get "$key" 0); prev=$(state_get "$key-hdr" ""); FK_OUTCOME=unknown; FK_FIRE=0; FK_CLASS=""; FK_STREAK=0; FK_PROGRESS=0
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  case "$an" in ''|*[!0-9]*) an=0 ;; esac
  case "$lag" in ''|*[!0-9-]*) lag=0 ;; esac
  case "$ours" in ''|*[!0-9]*) state_set "$key" 0; return 0 ;; esac
  state_set "$key-hdr" "$ours"
  case "$prev" in ''|*[!0-9]*) prev="" ;; esac
  if [ "$readok" != "1" ]; then state_set "$key" 0; return 0; fi
  if [ -z "$prev" ]; then state_set "$key" 0; return 0; fi
  FK_PROGRESS=$((ours - prev))
  if [ "$an" -lt "$minp" ]; then
    if [ "$FK_PROGRESS" -ge 1 ]; then FK_OUTCOME=ok; else FK_OUTCOME=unconfirmed; fi
    state_set "$key" 0; return 0
  fi
  if [ "$FK_PROGRESS" -ge "$prog" ]; then FK_OUTCOME=catchup; state_set "$key" 0; return 0; fi
  FK_OUTCOME=stuck; m=$((m + 1)); state_set "$key" "$m"; FK_STREAK=$m
  if [ "$m" -ge 3 ]; then
    FK_FIRE=1
    if [ "$ibd" = "false" ] && [ "$lag" -lt 10 ]; then FK_CLASS=deadbranch; else FK_CLASS=stalledsync; fi
  fi
  return 0
}

# Roster validator (pure). "ok" only when: JSON array; row count == unique oracle_id count == 35 (a deliberate
# compatibility restriction to the current mainnet roster size, not proof of completeness); every row is an object
# with an integer oracle_id, string status, string heartbeat_status, and an explicitly present integer last_update
# (0 is the never-received sentinel; null or missing is a schema failure, not a sentinel). Anything else: "bad".
netview_validate() {
  jq -r 'if type=="array" and length==35 and ([.[].oracle_id] | unique | length)==35
            and all(.[]; type=="object"
                        and (.oracle_id|type=="number") and (.oracle_id == (.oracle_id|floor))
                        and (.status|type=="string") and (.heartbeat_status|type=="string")
                        and has("last_update") and (.last_update|type=="number") and (.last_update == (.last_update|floor)) and (.last_update >= 0))
         then "ok" else "bad" end' <<< "$1" 2>/dev/null || echo bad
}

# Network-view state machine (pure except for the state files). Rules, per crew review 2026-10-06/07.
# Outcomes (NV_OUTCOME): miss | hit | zeroed | outofscope | unknown   (crew ruling 2026-10-08, option A)
#  miss       = read ok, heartbeat fresh, last_update > 0 and older than $5 seconds ("aged"): the observer
#               reports an old price timestamp. Pending evidence accrues. This is an observation, not proven
#               silence; on this observer it was seen on 0 of 35 slots in every read of 2026-10-08's samples.
#  hit        = read ok, heartbeat fresh, last_update > 0 and within $5 seconds: CONFIRMED recovery; clears
#               pending evidence and is the only outcome that may clear an active alert.
#  zeroed     = read ok, heartbeat fresh, last_update is the explicit 0 (missing or null is a schema failure
#               that never reaches this machine). The observer zeroes a slot whenever no price message has
#               arrived since its last pending-message clear (every ~14 s), while slots send every 60-250 s:
#               a healthy slot read 0 on 15-52% of reads on 2026-10-08, with runs of 9 minutes. Logged only.
#               Pending evidence reset; alert untouched. NEVER a miss, NEVER a hit.
#  outofscope = read ok but heartbeat not fresh (node down, restarting, loading): says nothing about the
#               price path. Pending evidence reset; alert state untouched.
#  unknown    = read not ok, or last_update malformed or in the future (> now + 300 s): pending evidence
#               reset; alert state untouched. Never a miss, never a hit.
#  FIRE only on a miss that is the 3rd+ consecutive AND >= 900 s after the first of the streak.
# args: readok(1|0) heartbeat_status last_update_raw now stale_seconds
#  -> NV_OUTCOME NV_FIRE NV_STREAK NV_AGE NV_MINUTES
netview_update() {
  local readok="$1" hb="$2" lu="$3" now="$4" stale="$5" streak since
  streak=$(state_get net-miss 0); since=$(state_get net-miss-since "$now")
  NV_OUTCOME=unknown; NV_FIRE=0; NV_STREAK=0; NV_AGE=-1; NV_MINUTES=0
  if [ "$readok" != "1" ]; then state_set net-miss 0; return 0; fi
  # last_update: explicit 0 = zeroed (handled after the heartbeat check); "" / null = malformed -> unknown;
  # non-integer or future = malformed -> unknown
  case "$lu" in 0) NV_AGE=-1 ;; ''|null|*[!0-9]*) state_set net-miss 0; return 0 ;; *) NV_AGE=$((now - lu)); if [ "$NV_AGE" -lt -300 ]; then state_set net-miss 0; return 0; fi; [ "$NV_AGE" -lt 0 ] && NV_AGE=0 ;; esac
  if [ "$hb" != "fresh" ]; then NV_OUTCOME=outofscope; state_set net-miss 0; return 0; fi
  if [ "$NV_AGE" -lt 0 ]; then NV_OUTCOME=zeroed; state_set net-miss 0; return 0; fi
  if [ "$NV_AGE" -gt "$stale" ]; then NV_OUTCOME=miss; else NV_OUTCOME=hit; fi
  if [ "$NV_OUTCOME" = "miss" ]; then [ "$streak" = "0" ] && since=$now; streak=$((streak + 1)); else streak=0; since=$now; fi
  state_set net-miss "$streak"; state_set net-miss-since "$since"; state_set net-last-ok-read "$now"
  NV_STREAK=$streak; NV_MINUTES=$(( (now - since) / 60 ))
  [ "$NV_OUTCOME" = "miss" ] && [ "$streak" -ge 3 ] && [ $((now - since)) -ge 900 ] && NV_FIRE=1
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
  # FORK DETECTOR: local data only (getpeerinfo). See fork_update for the outcomes and the known limit.
  local peers
  peers=$($clifn getpeerinfo 2>/dev/null || true)
  fork_peers_ahead "$peers" "$headers" "$FORK_GAP_BLOCKS"
  fork_update "$label-fork-miss" "$FK_PEERS_OK" "$FK_AHEAD_N" "$headers" "$ibd" "$lag" "$FORK_MIN_PEERS" "$FORK_PROGRESS_BLOCKS"
  case "$FK_OUTCOME" in
    ok) report_check "$label-fork" 1 "" "" ;;
    unconfirmed) log "fork: fewer than $FORK_MIN_PEERS peers claim ahead but headers=$headers did not move this cycle; unconfirmed (corroborating peers may have disconnected); alert state untouched" ;;
    stuck)
      summary="$summary PEERS_AHEAD=$FK_AHEAD_N/$FK_PEERS_N"
      if [ "$FK_FIRE" != "1" ]; then
        log "fork: stuck $FK_STREAK/3 ($FK_AHEAD_N of $FK_PEERS_N peers claim more than $FORK_GAP_BLOCKS above headers=$headers, highest claim $FK_CLAIM; headers +$FK_PROGRESS this cycle); alert state untouched"
      elif [ "$FK_CLASS" = "deadbranch" ]; then
        report_check "$label-fork" 0 "DGB oracle box: $label headers trail peer claims while the node looks synced (dead-branch candidate)" \
          "Our headers=$headers advanced $FK_PROGRESS blocks since the previous check while $FK_AHEAD_N of $FK_PEERS_N connected peers claim a startingheight more than $FORK_GAP_BLOCKS above them (highest claim $FK_CLAIM), for $FK_STREAK consecutive checks (progress below the $FORK_PROGRESS_BLOCKS-block threshold), and this node reports ibd=false with headers within 10 of blocks: locally it looks synced. Local headers that trail peer claims and stay below the progress threshold are consistent with a dead branch (a stored invalid mark, for example after crossing an activation on old software) and also with stale or wrong peer claims. Investigate why local headers trail peer claims before changing anything: digibyte-cli getchaintips; a tip with status=invalid above our height is the signal. Confirm with a node you trust or an explorer that the invalid tip's hash is on the real chain, and that this node's software is at the version the active rules require (otherwise it rejects the block again). Only then: reconsiderblock <hash>. On the oracle box on 2026-10-07 the reorg completed in about 90 s (one observation). Tip-age thresholds do not catch this." urgent
      else
        report_check "$label-fork" 0 "DGB oracle box: $label headers trail peer claims and stay below the progress threshold (stalled sync)" \
          "Our headers=$headers advanced $FK_PROGRESS blocks since the previous check while $FK_AHEAD_N of $FK_PEERS_N connected peers claim a startingheight more than $FORK_GAP_BLOCKS above them (highest claim $FK_CLAIM), for $FK_STREAK consecutive checks (progress below the $FORK_PROGRESS_BLOCKS-block threshold), and this node reports ibd=$ibd with headers-blocks=$lag: it does not look synced locally. This is a stalled sync, not a dead-branch finding. Investigate why local headers trail peer claims (peer connectivity, disk, a sync that stopped). Do not run reconsiderblock on this evidence." high
      fi ;;
    catchup) log "fork: $FK_AHEAD_N of $FK_PEERS_N peers claim more than $FORK_GAP_BLOCKS above headers=$headers but headers advanced +$FK_PROGRESS this cycle (catching up); pending evidence reset, alert state untouched" ;;
    *) log "fork detector unknown (no peer data, or no progress baseline yet); pending evidence reset, alert state untouched" ;;
  esac

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
    # netview_update (pure; --netview-selftest). report_check is called ONLY on miss (ok=0 when firing)
    # and on hit (ok=1, confirmed recovery); outofscope and unknown never touch the alert.
    if [ "$ismainnet" = "1" ]; then
      local nraw nme nvalid nhb nlu readok=0
      nraw=$(curl -fsS -m 20 -H "User-Agent: dgb-oracle-monitor (slot $ORACLE_ID)" -H 'Accept: application/json' "$NETVIEW_URL" 2>/dev/null || true)
      nvalid=$(netview_validate "$nraw")
      nme=""; [ "$nvalid" = "ok" ] && nme=$(jq -c --argjson id "$ORACLE_ID" '[.[] | select(.oracle_id == $id)] | first // empty' <<< "$nraw" 2>/dev/null)
      if [ -n "$nme" ]; then readok=1; nhb=$(jq -r '.heartbeat_status // ""' <<< "$nme"); nlu=$(jq -r '.last_update // ""' <<< "$nme"); else nhb=""; nlu=""; fi
      netview_update "$readok" "$nhb" "$nlu" "$NOW" "$NETVIEW_STALE_SECONDS"
      case "$NV_OUTCOME" in
        miss|hit)
          local netok=1; [ "$NV_FIRE" = "1" ] && netok=0
          if [ "$NV_OUTCOME" = "hit" ] || [ "$NV_FIRE" = "1" ]; then   # a miss that is not yet firing makes no call, so an active alert stands
          report_check "$label-oracle$ORACLE_ID-networkview" "$netok" "DGB ORACLE $ORACLE_ID: NETWORK-VIEW OBSERVER REPORTS AN OLD PRICE TIMESTAMP" \
            "The observer at $NETVIEW_URL holds a last price timestamp for slot $ORACLE_ID that is ${NV_AGE}s old (older than $NETVIEW_STALE_SECONDS s) with a fresh heartbeat (status $(jq -r '.status // "?"' <<< "$nme"), price_source $(jq -r '.price_source // "?"' <<< "$nme")) on $NV_STREAK consecutive reads over $NV_MINUTES minutes, while this node reports ${detail}. This is an observation from one node we do not run, not proven silence; on this observer the condition was seen on no slot in the samples of 2026-10-08, so treat it as rare and corroborate: your own listoracle, the oracle log for price messages, a second observer, and the signing-drought check. Cycling the oracle needs that corroboration, not this alert alone." urgent
          fi
          summary="$summary net-o$ORACLE_ID=$NV_OUTCOME/lu${NV_AGE}s" ;;
        zeroed) summary="$summary net-o$ORACLE_ID=zeroed"; log "netview: observer shows last_update 0 for slot $ORACLE_ID (not in its current scan; a healthy slot reads 0 on 15-52% of reads); logged only, pending evidence reset, alert state untouched" ;;
        outofscope) summary="$summary net-o$ORACLE_ID=hb-$nhb"; log "netview: heartbeat $nhb at the observer; price path not assessed, alert state untouched" ;;
        *) if [ "$nvalid" != "ok" ]; then log "netview check unknown (pending evidence reset, alert state untouched): roster failed schema/completeness check from $NETVIEW_URL"
           elif [ -z "$nme" ]; then log "netview check unknown: slot $ORACLE_ID absent; configuration or response completeness unconfirmed ($NETVIEW_URL)"
           else log "netview check unknown: last_update malformed or in the future for slot $ORACLE_ID (pending evidence reset, alert state untouched)"; fi ;;
      esac
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
  run_case() { # name; then steps "readok:hb:age|none|future|bad:offset:expectFire:expectAlertAfter"
    local name="$1"; shift; local ok=1 trace="" alert=0; rm -f "$STATE"/net-*; total=$((total + 1))
    for step in "$@"; do
      IFS=: read -r ro hb age off expf expa <<< "$step"; local lu=""
      case "$age" in zero) lu=0 ;; none) lu="" ;; future) lu=$((t0 + off + 3600)) ;; soon) lu=$((t0 + off + 120)) ;; bad) lu="12abc" ;; *) lu=$((t0 + off - age)) ;; esac
      netview_update "$ro" "$hb" "$lu" "$((t0 + off))" 3600
      # caller wiring under test: alert set only on fire; cleared only on hit; otherwise untouched
      if [ "$NV_FIRE" = "1" ]; then alert=1; elif [ "$NV_OUTCOME" = "hit" ]; then alert=0; fi
      trace="$trace t+${off}s $NV_OUTCOME fire=$NV_FIRE alert=$alert |"
      [ "$NV_FIRE" = "$expf" ] && [ "$alert" = "$expa" ] || ok=0
    done
    if [ "$ok" = "1" ]; then echo "PASS  $name"; else fails=$((fails + 1)); echo "FAIL  $name:$trace"; fi
  }
  run_case "healthy reads never fire" 1:fresh:70:0:0:0 1:fresh:120:300:0:0 1:fresh:40:600:0:0
  run_case "three stale reads inside 10 min do NOT fire (elapsed gate)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0
  run_case "fourth stale read at 15 min fires" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1
  run_case "unknown ticks reset pending evidence and never fire (OEAE scenario)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 0::0:600:0:0 0::0:900:0:0 1:fresh:5500:1500:0:0 1:fresh:5800:1800:0:0 1:fresh:6100:2100:0:0 1:fresh:6400:2400:1:1
  run_case "stale heartbeat with stale last_update is out of scope, not a miss" 1:stale:9000:0:0:0 1:stale:9300:300:0:0 1:stale:9600:600:0:0 1:stale:9900:900:0:0
  run_case "explicit 0 with a fresh heartbeat is zeroed: logged only, never fires" 1:fresh:zero:0:0:0 1:fresh:zero:300:0:0 1:fresh:zero:600:0:0 1:fresh:zero:900:0:0 1:fresh:zero:1200:0:0 1:fresh:zero:1500:0:0
  run_case "zeroed resets pending aged evidence (the streak restarts after it)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:zero:600:0:0 1:fresh:4900:900:0:0 1:fresh:5200:1200:0:0 1:fresh:5500:1500:0:0 1:fresh:5800:1800:1:1
  run_case "an active aged alert survives zeroed reads (never clears)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 1:fresh:zero:1200:0:1 1:fresh:zero:1500:0:1 1:fresh:zero:1800:0:1
  run_case "empty last_update reaching the state machine is unknown, never a miss" 1:fresh:none:0:0:0 1:fresh:none:300:0:0 1:fresh:none:600:0:0 1:fresh:none:900:0:0
  run_case "a hit clears pending evidence" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:50:600:0:0 1:fresh:4000:900:0:0 1:fresh:4300:1200:0:0 1:fresh:4600:1500:0:0
  run_case "active alert survives unknown reads (unconfirmed, not recovered)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 0::0:1200:0:1 0::0:1500:0:1
  run_case "active alert survives a stale heartbeat (restart does not count as recovery)" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 1:stale:5200:1200:0:1 1:stale:5500:1500:0:1
  run_case "malformed and future timestamps are unknown: never fire, never clear" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 1:fresh:bad:1200:0:1 1:fresh:future:1500:0:1
  run_case "last_update slightly in the future (<= 300 s) clamps to age 0 and is a hit, never a miss" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 1:fresh:soon:1200:0:0
  run_case "confirmed recovery clears the alert" 1:fresh:4000:0:0:0 1:fresh:4300:300:0:0 1:fresh:4600:600:0:0 1:fresh:4900:900:1:1 1:fresh:60:1200:0:0
  # validator against the shared fixtures
  fxdir="$(cd "$(dirname "$0")/.." && pwd)/test/netview-fixtures"
  for f in "$fxdir"/*.json; do n=$(basename "$f"); [ "$n" = "expected.json" ] && continue
    exp=$(jq -r --arg n "$n" '.[$n]' "$fxdir/expected.json"); got=$(netview_validate "$(cat "$f")"); total=$((total + 1))
    if [ "$got" = "$exp" ]; then echo "PASS  validator: $n -> $got"; else fails=$((fails + 1)); echo "FAIL  validator: $n expected $exp got $got"; fi
  done
  # fork peer helper (pure): startingheight only, one peer cannot set the maximum
  run_peers() { local name="$1" json="$2" ours="$3" exp="$4" got; total=$((total + 1)); fork_peers_ahead "$json" "$ours" 100; got="$FK_PEERS_OK $FK_PEERS_N $FK_AHEAD_N $FK_CLAIM"
    if [ "$got" = "$exp" ]; then echo "PASS  $name"; else fails=$((fails + 1)); echo "FAIL  $name: expected [$exp] got [$got]"; fi; }
  run_peers "fork peers: one peer far ahead, two at our height -> 1 of 3 ahead" '[{"startingheight":1500},{"startingheight":1000},{"startingheight":1000}]' 1000 "1 3 1 1500"
  run_peers "fork peers: two peers 50 ahead -> none ahead (gap 100)" '[{"startingheight":1050},{"startingheight":1050}]' 1000 "1 2 0 1050"
  run_peers "fork peers: two peers 500 ahead -> 2 of 3 ahead" '[{"startingheight":1500},{"startingheight":1500},{"startingheight":900}]' 1000 "1 3 2 1500"
  run_peers "fork peers: synced_headers is ignored" '[{"startingheight":1000,"synced_headers":9999},{"startingheight":1000,"synced_headers":9999}]' 1000 "1 2 0 1000"
  run_peers "fork peers: empty array is no data" '[]' 1000 "0 0 0 0"
  run_peers "fork peers: non-JSON is no data" 'garbage' 1000 "0 0 0 0"
  run_peers "fork peers: a row without startingheight makes the read no data" '[{"startingheight":1500},{"addr":"x"}]' 1000 "0 0 0 0"
  run_peers "fork peers: a non-numeric startingheight makes the read no data" '[{"startingheight":"1500"},{"startingheight":1500}]' 1000 "0 0 0 0"
  # fork detector transitions: steps "readok:ahead_n:ours:ibd:lag:expectOutcome:expectFire(0|deadbranch|stalledsync):expectAlertAfter"
  run_fork() { local name="$1"; shift; local ok=1 trace="" alert=0; rm -f "$STATE"/x-fork-miss "$STATE"/x-fork-miss-hdr; total=$((total + 1))
    for step in "$@"; do IFS=: read -r ro an ou ib lg expo expf expa <<< "$step"; fork_update x-fork-miss "$ro" "$an" "$ou" "$ib" "$lg" 2 100
      local fired=0; [ "$FK_FIRE" = "1" ] && fired="$FK_CLASS"
      if [ "$FK_FIRE" = "1" ]; then alert=1; elif [ "$FK_OUTCOME" = "ok" ]; then alert=0; fi   # caller wiring under test: only ok clears
      trace="$trace $FK_OUTCOME/$fired/a$alert |"; { [ "$FK_OUTCOME" = "$expo" ] && [ "$fired" = "$expf" ] && [ "$alert" = "$expa" ]; } || ok=0; done
    if [ "$ok" = "1" ]; then echo "PASS  $name"; else fails=$((fails + 1)); echo "FAIL  $name:$trace"; fi; }
  run_fork "fork: first read is unknown (no baseline); stuck x3 fires deadbranch when the node looks synced" 1:2:1000:false:0:unknown:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:deadbranch:1
  run_fork "fork: one peer ahead is below the minimum: unknown without a baseline, then ok while headers advance" 1:1:1000:false:0:unknown:0:0 1:1:1020:false:0:ok:0:0 1:1:1040:false:0:ok:0:0 1:1:1060:false:0:ok:0:0
  run_fork "fork: ahead peers disconnect with no local progress: unconfirmed, alert retained; clears once headers advance" 1:2:1000:false:0:unknown:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:deadbranch:1 1:0:1000:false:0:unconfirmed:0:1 1:1:1000:false:0:unconfirmed:0:1 1:0:1020:false:0:ok:0:0
  run_fork "fork: advancing catch-up never fires" 1:2:1000:true:0:unknown:0:0 1:2:5000:true:3000:catchup:0:0 1:2:9000:true:2000:catchup:0:0 1:2:13000:true:1000:catchup:0:0 1:2:17000:false:5:catchup:0:0
  run_fork "fork: stuck in IBD fires stalledsync, not deadbranch" 1:2:1000:true:0:unknown:0:0 1:2:1000:true:0:stuck:0:0 1:2:1000:true:0:stuck:0:0 1:2:1000:true:0:stuck:stalledsync:1
  run_fork "fork: headers far ahead of blocks fires stalledsync" 1:2:1000:false:500:unknown:0:0 1:2:1000:false:500:stuck:0:0 1:2:1000:false:500:stuck:0:0 1:2:1000:false:500:stuck:stalledsync:1
  run_fork "fork: a catch-up read resets the streak; stuck counts again from 1" 1:2:1000:false:0:unknown:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:0:0 1:2:1450:false:0:catchup:0:0 1:2:1450:false:0:stuck:0:0 1:2:1450:false:0:stuck:0:0 1:2:1450:false:0:stuck:deadbranch:1
  run_fork "fork: an active alert survives unknown and the following stuck read (no false recovery); only ok clears" 1:2:1000:false:0:unknown:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:deadbranch:1 0:0:1000:false:0:unknown:0:1 1:2:1000:false:0:stuck:0:1 1:2:1000:false:0:stuck:0:1 1:2:1000:false:0:stuck:deadbranch:1 1:0:1020:false:0:ok:0:0
  run_fork "fork: catch-up does not clear an active alert" 1:2:1000:false:0:unknown:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:0:0 1:2:1000:false:0:stuck:deadbranch:1 1:2:1500:false:0:catchup:0:1 1:0:1520:false:0:ok:0:0
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
