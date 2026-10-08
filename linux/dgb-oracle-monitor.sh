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
DROUGHT_EPOCHS="${DROUGHT_EPOCHS:-36}"            # completed-gap threshold from the ledger packet (provisional); the monitor fires on the 35th absent bundle epoch
DROUGHT_SCAN_BLOCKS="${DROUGHT_SCAN_BLOCKS:-100}" # getoraclesigners window: Core's default; the scan walks every block under cs_main, and sightings are persisted
DROUGHT_STALL_BLOCKS="${DROUGHT_STALL_BLOCKS:-160}" # newest mature bundle more than this many blocks behind the tip = no recent bundle on this node's chain (stall)
DROUGHT_STALL_WARN_SECONDS="${DROUGHT_STALL_WARN_SECONDS:-3600}" # a stall older than this raises the degraded-observation warning
DROUGHT_TESTNET="${DROUGHT_TESTNET:-0}"           # the math is from mainnet; enable on testnet deliberately
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

# Signing-drought check: chain-participation evidence for our slot, from local getoraclesigners (crew data and
# FIX rounds, 2026-10-08). Every bundle names exactly 7 signers chosen by lottery among nonce-submitting oracles.
# In the participation ledger (10,476 bundle epochs, Jul 18 to Oct 1, 2026) the 22 slots with a normal signing
# rate signed about one epoch in five: median gap 3 bundle epochs, 99th percentile 19; completed gaps >= 36 were
# 0.073% of healthy gaps (0.041% under an independent, equal-probability model, an assumption the similar
# marginal rates are consistent with but do not establish). Slot 29's silent price path of Oct 1-6 did not sign
# for its duration: one case. Method, assumptions and the labeling of every gap >= 36:
# data/drought/ledger-gaps-2026-10-08.md. DROUGHT_EPOCHS (36) and the 160-block bound are PROVISIONAL triage
# thresholds. Absent participation is evidence, not proof of a silent price path.
# CLOCK: the packet counts BUNDLE epochs (epochs in which a bundle was included), and so does this check: it
# keeps a persisted count of distinct bundle epochs observed since the reference point, and fires when that count
# reaches DROUGHT_EPOCHS - 1 (35 absent bundle epochs between two signings is a completed gap of 36). Epochs
# with no bundle do not advance it, which is also why a bundle stall is not a drought.
# Core clamps getoraclesigners to 1..1000 blocks and walks every block of the window under cs_main, so the default
# window is Core's default of 100 and everything is persisted. State keys ($key-*):
#  last / last-h / last-hash = the newest epoch in which our id appeared in a mature bundle, with that bundle's
#      height and block hash. On every read the caller fetches getblockhash(last-h) and passes it in; a hash
#      mismatch means the sighting was reorged out: it is discarded and evidence restarts. No hash = unverifiable
#      = unknown, state untouched.
#  floor = the epoch evidence (re)starts from: the oldest epoch of the first window, or of the window after a
#      coverage gap or a discarded sighting. It may be only partly covered. A lower bound of OBSERVATION.
#  count = distinct bundle epochs observed above the reference (last sighting if at or above the floor, else the
#      floor). tip / newest = last processed tip and newest epoch. stall-since = when the current stall began.
# Only bundles at least DROUGHT_MATURITY (12) blocks below the tip count. Outcomes (DR_OUTCOME; DR_WHY explains):
#  unknown     = RPC failed; malformed output (schema below); a bundle above the tip; a valid window whose only
#                bundles are immature; the newest epoch went backwards (regression: state untouched); the sighting
#                anchor could not be verified (state untouched) or did not match (sighting discarded, evidence
#                restarted); or a coverage gap (the tip advanced more than window minus maturity since the last
#                read, so blocks were never scanned: evidence restarts from this window's oldest epoch). Alert
#                untouched in every case: an active drought alert survives all of these.
#  stall       = a VALID window with no bundle at all (Core's shape, bundles empty), or the newest mature bundle
#                more than DROUGHT_STALL_BLOCKS behind the tip (reachable only when the scan is wider than that
#                bound): no recent bundle on THIS node's chain. Neither pages nor clears; DR_STALL_SECONDS tells
#                the caller how long, for the degraded-observation warning. A lagging or stalled local tip does
#                not show here; the sync and fork checks own that.
#  ok          = a sighting is the reference (basis=sighting) and the count is below the threshold: the ONLY
#                outcome that clears an alert.
#  unconfirmed = the floor is the reference (no sighting since evidence (re)started) and the count is below the
#                threshold: nothing is known either way; neither pages nor clears. Rebuilding evidence is not
#                recovery.
#  drought     = count >= DROUGHT_EPOCHS - 1: fires (priority high; about six hours at full bundle rate).
# Schema: bundles[] objects with integer epoch >= 0, integer height in [0, tip], string blockhash, signer_ids a
# non-empty array of integers, bitmap_valid true when present; anything else makes the whole read unknown (same
# in PowerShell). A state wipe restarts evidence (floor), which cannot clear an alert by itself: only a sighting.
# args: key ourid getoraclesigners_json tipheight [epochs] [stall_blocks] [scan_blocks] [anchor_hash]
#  -> DR_OUTCOME DR_FIRE DR_DROUGHT(count) DR_NEWEST DR_NEWESTH DR_LASTSIGNED DR_BASIS DR_STALL_SECONDS DR_WHY
drought_update() {
  local key="$1" id="$2" js="$3" tip="$4" K="${5:-${DROUGHT_EPOCHS:-36}}" stallb="${6:-${DROUGHT_STALL_BLOCKS:-160}}" scan="${7:-${DROUGHT_SCAN_BLOCKS:-100}}" anchor="${8:-}"
  local mat="${DROUGHT_MATURITY:-12}" mature parsed newest newesth oldest seen seenh seenhash epochs last lasth lasthash floor count ptip pnewest now v ss restart=0 n
  DR_OUTCOME=unknown; DR_FIRE=0; DR_DROUGHT=""; DR_NEWEST=""; DR_NEWESTH=""; DR_LASTSIGNED=""; DR_BASIS=""; DR_STALL_SECONDS=0; DR_WHY=""
  case "$tip" in ''|*[!0-9]*) DR_WHY="tip unknown"; return 0 ;; esac
  mature=$((tip - mat)); now="${NOW:-$(date +%s)}"
  count=$(state_get "$key-count" 0); case "$count" in ''|*[!0-9]*) count=0 ;; esac
  parsed=$(jq -r --argjson id "$id" --argjson tip "$tip" --argjson mature "$mature" '
      if type=="object" and (.bundles|type=="array") and (.bundles|length)==0 and has("scan_blocks") and has("chain_height") then "empty"
      elif type=="object" and (.bundles|type=="array") and (.bundles|length)>0
         and all(.bundles[]; type=="object"
                   and (.epoch|type=="number") and (.epoch==(.epoch|floor)) and (.epoch>=0)
                   and (.height|type=="number") and (.height==(.height|floor)) and (.height>=0) and (.height<=$tip)
                   and (.blockhash|type=="string") and ((.blockhash|length)>0)
                   and (.signer_ids|type=="array") and ((.signer_ids|length)>=1) and all(.signer_ids[]; type=="number" and .==floor)
                   and ((has("bitmap_valid")|not) or .bitmap_valid==true))
      then ([.bundles[] | select(.height <= $mature)]) as $m
           | if ($m|length)==0 then "nomature"
             else ([$m[] | select(.signer_ids|any(.==$id))] | sort_by(.epoch, .height) | last) as $s
                  | "\([$m[].epoch]|max) \([$m[].height]|max) \([$m[].epoch]|min) \(if $s then "\($s.epoch) \($s.height) \($s.blockhash)" else "-1 0 -" end) \([$m[].epoch]|unique|join(","))" end
      else "bad" end' <<< "$js" 2>/dev/null || echo bad)
  case "$parsed" in
    bad|'') DR_WHY="malformed or empty getoraclesigners output (schema: integer epoch, integer height within the tip, blockhash, non-empty integer signer_ids, bitmap_valid true)"; return 0 ;;
    nomature) DR_WHY="the window's only bundles are fewer than $mat blocks below the tip"; state_set "$key-stall-since" ""; state_set "$key-tip" "$tip"; return 0 ;;
    empty)   # the window was scanned and held no bundle: the tip advances so a long stall is not later read as a coverage gap
      ss=$(state_get "$key-stall-since" ""); case "$ss" in ''|*[!0-9]*) ss=$now; state_set "$key-stall-since" "$ss" ;; esac
      state_set "$key-tip" "$tip"
      DR_STALL_SECONDS=$((now - ss)); DR_DROUGHT=$count; DR_OUTCOME=stall; DR_WHY="no bundle in the last $scan blocks"; return 0 ;;
  esac
  read -r newest newesth oldest seen seenh seenhash epochs <<< "$parsed"
  for v in "$newest" "$newesth" "$oldest" "$seenh"; do case "$v" in ''|*[!0-9]*) DR_WHY="parse failure"; return 0 ;; esac; done
  case "$seen" in ''|*[!0-9-]*) seen=-1 ;; esac
  DR_NEWEST=$newest; DR_NEWESTH=$newesth
  pnewest=$(state_get "$key-newest" ""); ptip=$(state_get "$key-tip" ""); last=$(state_get "$key-last" ""); floor=$(state_get "$key-floor" "")
  lasth=$(state_get "$key-last-h" ""); lasthash=$(state_get "$key-last-hash" "")
  case "$pnewest" in ''|*[!0-9]*) pnewest="" ;; esac; case "$ptip" in ''|*[!0-9]*) ptip="" ;; esac
  case "$last" in ''|*[!0-9]*) last="" ;; esac; case "$floor" in ''|*[!0-9]*) floor="" ;; esac; case "$lasth" in ''|*[!0-9]*) lasth="" ;; esac
  # 1. validate before any state write: regression, then the sighting anchor
  if [ -n "$pnewest" ] && [ "$newest" -lt "$pnewest" ]; then DR_WHY="newest epoch $newest is below the last processed epoch $pnewest (reorg, or state from another chain); state untouched"; return 0; fi
  if [ -n "$last" ]; then
    if [ -z "$lasth" ] || [ -z "$lasthash" ]; then restart=1; DR_WHY="persisted sighting at epoch $last has no block anchor (state from an older version); discarded, evidence restarts from epoch $oldest"
    elif [ -z "$anchor" ]; then DR_WHY="sighting anchor at height $lasth could not be verified (getblockhash failed); state untouched"; return 0
    elif [ "$anchor" != "$lasthash" ]; then restart=1; DR_WHY="sighting at epoch $last (height $lasth) is no longer on the active chain; discarded, evidence restarts from epoch $oldest"; fi
    if [ "$restart" = "1" ]; then last=""; state_set "$key-last" ""; state_set "$key-last-h" ""; state_set "$key-last-hash" ""; fi
  fi
  # 2. coverage gap
  if [ "$restart" = "0" ] && [ -n "$ptip" ] && [ $((tip - ptip)) -gt $((scan - mat)) ]; then restart=1; DR_WHY="coverage gap: the tip advanced $((tip - ptip)) blocks since the last read, more than the $scan-block window covers; evidence restarts from epoch $oldest"; fi
  # 3. the clock: distinct bundle epochs observed above the reference
  count_above() { local ref="$1" e c=0; for e in ${epochs//,/ }; do [ "$e" -gt "$ref" ] && c=$((c + 1)); done; echo "$c"; }
  if [ "$restart" = "1" ] || [ -z "$floor" ] || [ -z "$pnewest" ]; then
    floor=$oldest; state_set "$key-floor" "$floor"
    if [ "$seen" -ge 0 ]; then last=$seen; lasth=$seenh; lasthash=$seenhash; state_set "$key-last" "$last"; state_set "$key-last-h" "$lasth"; state_set "$key-last-hash" "$lasthash"; count=$(count_above "$seen")
    else count=$(count_above "$floor"); fi
  elif [ "$seen" -ge 0 ] && { [ -z "$last" ] || [ "$seen" -gt "$last" ]; }; then
    last=$seen; lasth=$seenh; lasthash=$seenhash; state_set "$key-last" "$last"; state_set "$key-last-h" "$lasth"; state_set "$key-last-hash" "$lasthash"; count=$(count_above "$seen")
  else
    n=$(count_above "$pnewest"); count=$((count + n))
  fi
  state_set "$key-count" "$count"; state_set "$key-tip" "$tip"; state_set "$key-newest" "$newest"
  DR_DROUGHT=$count; DR_LASTSIGNED="${last:-none}"; DR_BASIS=floor
  if [ -n "$last" ] && [ "$last" -ge "$floor" ]; then DR_BASIS=sighting; fi
  if [ "$restart" = "1" ]; then return 0; fi
  # 4. stall by distance (only reachable when the scan is wider than the bound)
  if [ $((tip - newesth)) -gt "$stallb" ]; then
    ss=$(state_get "$key-stall-since" ""); case "$ss" in ''|*[!0-9]*) ss=$now; state_set "$key-stall-since" "$ss" ;; esac
    DR_STALL_SECONDS=$((now - ss)); DR_OUTCOME=stall; DR_WHY="newest mature bundle is $((tip - newesth)) blocks behind the tip"; return 0
  fi
  state_set "$key-stall-since" ""
  if [ "$count" -ge $((K - 1)) ]; then DR_OUTCOME=drought; DR_FIRE=1
  elif [ "$DR_BASIS" = "sighting" ]; then DR_OUTCOME=ok
  else DR_OUTCOME=unconfirmed; fi
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
    # SIGNING DROUGHT (chain-participation evidence, local getoraclesigners; mainnet by default). See drought_update
    # for the rule, the clock, and the state keys. report_check is called ONLY on ok (clears both keys), on drought
    # (fires; clears the observation key), on unconfirmed (clears the observation key only), and on a stall that
    # has persisted past DROUGHT_STALL_WARN_SECONDS (degraded observation, its own key).
    if [ "$ismainnet" = "1" ] || [ "$DROUGHT_TESTNET" = "1" ]; then
      local sig lasth anchor=""
      sig=$($clifn getoraclesigners "$DROUGHT_SCAN_BLOCKS" 2>/dev/null || true)
      lasth=$(state_get "$label-drought-last-h" ""); case "$lasth" in ''|*[!0-9]*) lasth="" ;; esac
      [ -n "$lasth" ] && anchor=$($clifn getblockhash "$lasth" 2>/dev/null || true)
      drought_update "$label-drought" "$ORACLE_ID" "$sig" "$blocks" "$DROUGHT_EPOCHS" "$DROUGHT_STALL_BLOCKS" "$DROUGHT_SCAN_BLOCKS" "$anchor"
      case "$DR_OUTCOME" in
        ok) report_check "$label-drought" 1 "" ""; report_check "$label-drought-observation" 1 "" ""; summary="$summary drought=$DR_DROUGHT" ;;
        unconfirmed) report_check "$label-drought-observation" 1 "" ""; summary="$summary drought=$DR_DROUGHT?"; log "drought: $DR_DROUGHT bundle epochs observed since evidence started at epoch $(state_get "$label-drought-floor" "?") with no sighting of slot $ORACLE_ID; unconfirmed, alert state untouched" ;;
        drought)
          report_check "$label-drought" 0 "DGB ORACLE $ORACLE_ID ($label): NO SIGNING PARTICIPATION IN THE LAST $DR_DROUGHT BUNDLE EPOCHS" \
            "Our slot $ORACLE_ID has not appeared in any of the last $DR_DROUGHT oracle bundle epochs observed on this node's chain (newest mature bundle epoch $DR_NEWEST at height $DR_NEWESTH; last sighting $DR_LASTSIGNED; basis: $DR_BASIS, where floor means counted since monitoring (re)started). In the participation ledger a healthy slot signs about one epoch in five (median gap 3 bundle epochs, 99th percentile 19); a completed gap of 36 or more was 0.073% of healthy gaps, and most longer gaps coincide with dated events. This is evidence of absent participation on this node's chain, not proof of a silent price path; the thresholds are provisional. Corroborate: listoracle / getoracles for your slot, the oracle log for price and nonce messages, a second node or an observer, and the runbook's 'after any restart or upgrade' section; a silent price broadcast after a restart presented exactly like this on slot 29, Oct 1 to 6, 2026." high
          report_check "$label-drought-observation" 1 "" ""; summary="$summary DROUGHT=$DR_DROUGHT" ;;
        stall)
          summary="$summary drought=stall"
          if [ "$DR_STALL_SECONDS" -ge "${DROUGHT_STALL_WARN_SECONDS:-3600}" ]; then
            report_check "$label-drought-observation" 0 "DGB ORACLE $ORACLE_ID ($label): DROUGHT CHECK DEGRADED, NO RECENT BUNDLE ON THIS NODE'S CHAIN" \
              "This node's chain shows no oracle bundle in the last $DROUGHT_SCAN_BLOCKS blocks ($DR_WHY), and has not for $((DR_STALL_SECONDS / 60)) minutes. The signing-drought check cannot assess slot $ORACLE_ID while this persists (its count stands at $DR_DROUGHT). This is a local observation: no recent bundle on this node's chain. Possible causes include miners not including bundles, the oracle network not producing them, or this node on a branch without them; a lagging or stalled local tip looks different and is covered by the sync and fork checks. It clears on the next read that finds a bundle." high
          else log "drought: $DR_WHY for $((DR_STALL_SECONDS / 60)) min (count stands at $DR_DROUGHT); no recent bundle on this node's chain; alert state untouched"; fi ;;
        *) log "drought unknown: ${DR_WHY:-getoraclesigners failed}; alert state untouched" ;;
      esac
    fi
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
  # drought check: synthetic bundles and the real Core fixture. Spec items "e/h/ids" or "e1-e2/auto/ids" (one
  # bundle per epoch at height e*40), ';'-separated; "empty" = Core's valid empty window; "raw=<json>". Steps
  # "tip:expectOutcome:expectFire:expectAlertAfter[:scan=N][:anchor=none|reorged]:spec" (spec last: raw JSON may
  # contain colons). The harness replays the caller: it passes the persisted sighting hash back as the chain's
  # answer unless a step says otherwise.
  dr_json() { local out="" b e h ids lo hi; for b in ${1//;/ }; do IFS=/ read -r e h ids <<< "$b"
      if [ "$h" = "auto" ]; then lo="${e%-*}"; hi="${e#*-}"; for ((e=lo; e<=hi; e++)); do out="$out{\"epoch\":$e,\"height\":$((e * 40)),\"blockhash\":\"h$((e * 40))\",\"signer_ids\":[${ids//-/,}]},"; done
      else out="$out{\"epoch\":$e,\"height\":$h,\"blockhash\":\"h$h\",\"signer_ids\":[${ids//-/,}]},"; fi; done; printf '{"bundles":[%s]}' "${out%,}"; }
  dr_reset() { local k; for k in last last-h last-hash floor tip newest count stall-since; do rm -f "$STATE/x-drought-$k"; done; }
  dr_call() { # id tip spec scan anchormode
    local id="$1" tip="$2" spec="$3" scan="$4" mode="$5" anchor js
    case "$mode" in none) anchor="" ;; reorged) anchor="reorged" ;; *) anchor=$(state_get x-drought-last-hash "") ;; esac
    case "$spec" in raw=*) js="${spec#raw=}" ;; empty) js="{\"chain_height\":$tip,\"scan_blocks\":100,\"bundle_count\":0,\"bundles\":[]}" ;; *) js=$(dr_json "$spec") ;; esac
    drought_update x-drought "$id" "$js" "$tip" 36 160 "$scan" "$anchor"; }
  run_drought() { local name="$1" id="$2"; shift 2; local ok=1 trace="" alert=0 tip expo expf expa spec rest opt scan mode; dr_reset; total=$((total + 1))
    for step in "$@"; do IFS=: read -r tip expo expf expa rest <<< "$step"; scan=100000; mode=verified
      while :; do case "$rest" in scan=*|anchor=*) opt="${rest%%:*}"; rest="${rest#*:}"; case "$opt" in scan=*) scan="${opt#scan=}" ;; anchor=*) mode="${opt#anchor=}" ;; esac ;; *) break ;; esac; done
      spec="$rest"; dr_call "$id" "$tip" "$spec" "$scan" "$mode"
      if [ "$DR_FIRE" = "1" ]; then alert=1; elif [ "$DR_OUTCOME" = "ok" ]; then alert=0; fi   # caller wiring under test: only ok clears
      trace="$trace $DR_OUTCOME/$DR_DROUGHT/f$DR_FIRE/a$alert |"; { [ "$DR_OUTCOME" = "$expo" ] && [ "$DR_FIRE" = "$expf" ] && [ "$alert" = "$expa" ]; } || ok=0; done
    if [ "$ok" = "1" ]; then echo "PASS  $name"; else fails=$((fails + 1)); echo "FAIL  $name:$trace"; fi; }
  run_drought "drought: sighted in the window -> ok; the count is bundle epochs observed after the sighting" 29 "4060:ok:0:0:100/4000/1-2-29;101/4040/3-4-5" "4100:ok:0:0:101/4040/3-4-5;102/4080/6-7-8"
  run_drought "drought: never sighted -> unconfirmed (not ok); fires on the 35th absent bundle epoch; a sighting clears" 29 "4060:unconfirmed:0:0:100-101/auto/1-2-3" "5420:unconfirmed:0:0:102-134/auto/1-2-3" "5460:drought:1:1:135/5400/4-5-6" "5500:ok:0:0:136/5440/29-8-9"
  run_drought "drought: persisted sighting, then no sighting: 34 absent bundle epochs is ok, 35 fires (completed gap 36)" 29 "4020:ok:0:0:100/4000/29-2-3" "5420:ok:0:0:101-134/auto/1-2-3" "5460:drought:1:1:135/5400/7-8-9"
  run_drought "drought: bundle epochs are the clock: a window skipping epochs counts only the epochs it shows" 29 "4020:ok:0:0:100/4000/29-2-3" "4420:ok:0:0:105/4200/1-2-3;110/4400/4-5-6"
  run_drought "drought: a valid empty window (Core's shape) is a stall: neither pages nor clears; the next bundle resumes" 29 "4020:ok:0:0:100/4000/29-2-3" "5460:drought:1:1:101-135/auto/7-8-9" "5700:stall:0:1:empty" "5740:stall:0:1:empty" "5780:drought:1:1:136/5760/7-8-9" "5820:ok:0:0:137/5800/29-8-9"
  run_drought "drought: a long stall is not a coverage gap afterwards: the tip advances on empty reads, the first bundle after it continues the count" 29 "4020:ok:0:0:100/4000/29-2-3" "5460:drought:1:1:101-135/auto/7-8-9" "5540:stall:0:1:scan=100:empty" "5620:stall:0:1:scan=100:empty" "5700:stall:0:1:scan=100:empty" "5780:drought:1:1:scan=100:136/5760/7-8-9" "5820:ok:0:0:scan=100:137/5800/29-8-9"
  run_drought "drought: malformed output is unknown and touches nothing; an immature-only window is unknown" 29 "4020:ok:0:0:100/4000/29-2-3" "4060:unknown:0:0:raw={\"bundles\":[]}" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":\"x\",\"height\":1,\"blockhash\":\"h\",\"signer_ids\":[1]}]}" "4060:unknown:0:0:raw=garbage" "4060:unknown:0:0:raw=" "4010:unknown:0:0:101/4005/3-4-5" "4060:ok:0:0:101/4040/3-4-5"
  run_drought "drought: schema: empty signer_ids, scalar signer_ids, bitmap_valid false, fractional height, height above the tip, missing blockhash are all unknown" 29 "4020:ok:0:0:100/4000/29-2-3" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":101,\"height\":4040,\"blockhash\":\"h\",\"signer_ids\":[]}]}" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":101,\"height\":4040,\"blockhash\":\"h\",\"signer_ids\":29}]}" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":101,\"height\":4040,\"blockhash\":\"h\",\"signer_ids\":[29],\"bitmap_valid\":false}]}" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":101,\"height\":4040.5,\"blockhash\":\"h\",\"signer_ids\":[29]}]}" "4060:unknown:0:0:100/4000/1-2-3;101/4100/4-5-6" "4060:unknown:0:0:raw={\"bundles\":[{\"epoch\":101,\"height\":4040,\"signer_ids\":[29]}]}" "4060:ok:0:0:101/4040/3-4-5"
  run_drought "drought: regression after a fire is unknown and keeps the alert; fires again when the chain passes; a sighting clears" 29 "4020:ok:0:0:100/4000/29-2-3" "5460:drought:1:1:101-135/auto/7-8-9" "5460:unknown:0:1:134/5360/7-8-9" "5500:drought:1:1:136/5440/7-8-9" "5540:ok:0:0:137/5480/29-7-8"
  run_drought "drought: coverage gap after a fire restarts evidence but keeps the alert; in-window reads without our signer are unconfirmed, not ok; a sighting clears (OEAE/HEAE)" 29 "4020:ok:0:0:100/4000/29-2-3" "5460:drought:1:1:101-135/auto/7-8-9" "5900:unknown:0:1:scan=100:146/5880/1-2-3" "5940:unconfirmed:0:1:146/5880/1-2-3;147/5920/4-5-6" "5980:ok:0:0:148/5960/29-5-6"
  run_drought "drought: a sighting whose block is no longer on the active chain is discarded and evidence restarts; the alert stays; unconfirmed until a new sighting" 29 "4020:ok:0:0:100/4000/29-2-3" "5460:drought:1:1:101-135/auto/7-8-9" "5500:unknown:0:1:anchor=reorged:136/5440/7-8-9" "5540:unconfirmed:0:1:137/5480/7-8-9" "5580:ok:0:0:138/5520/29-7-8"
  run_drought "drought: an unverifiable anchor (getblockhash failed) is unknown and touches nothing" 29 "4020:ok:0:0:100/4000/29-2-3" "4060:unknown:0:0:anchor=none:101/4040/3-4-5" "4100:ok:0:0:101/4040/3-4-5;102/4080/6-7-8"
  total=$((total + 1)); dr_reset; dr_call 29 4020 "100/4000/1-2-3" 100000 verified; dr_call 29 4050 "100/4000/1-2-3;101/4045/29-2-3" 100000 verified; a="$DR_OUTCOME/$DR_LASTSIGNED/$DR_NEWEST"
  dr_call 29 4070 "101/4045/29-2-3" 100000 verified; b="$DR_OUTCOME/$DR_LASTSIGNED/$DR_DROUGHT/$(state_get x-drought-last-h "")/$(state_get x-drought-last-hash "")"
  if [ "$a" = "unconfirmed/none/100" ] && [ "$b" = "ok/101/0/4045/h4045" ]; then echo "PASS  drought: a bundle fewer than 12 blocks below the tip is not a sighting until it matures; the sighting's height and hash are persisted"; else fails=$((fails + 1)); echo "FAIL  drought maturity: $a | $b"; fi
  total=$((total + 1)); dr_reset; dr_call 29 4020 "100/4000/29-2-3" 100000 verified; NOW=1000 dr_call 29 4300 empty 100000 verified; a="$DR_OUTCOME/$DR_STALL_SECONDS"
  NOW=4700 dr_call 29 4320 empty 100000 verified; b="$DR_OUTCOME/$DR_STALL_SECONDS"; NOW=4800 dr_call 29 4340 "100/4000/29-2-3;108/4320/1-2-3" 100000 verified; c="$DR_OUTCOME/$DR_STALL_SECONDS/$DR_DROUGHT"
  if [ "$a" = "stall/0" ] && [ "$b" = "stall/3700" ] && [ "$c" = "ok/0/1" ]; then echo "PASS  drought: stall duration accrues from its first empty read (3700 s on the second) and resets on the next read with a bundle"; else fails=$((fails + 1)); echo "FAIL  drought stall timing: $a | $b | $c"; fi
  fx="$(dirname "$0")/../test/drought-fixtures/getoraclesigners-1000.json"; fxraw=$(jq -c . "$fx" 2>/dev/null || echo garbage)
  run_drought "drought fixture: slot 3 sighted at the newest mature epoch -> ok, count 0" 3 "24183636:ok:0:0:raw=$fxraw"
  run_drought "drought fixture: slot 14 absent -> 25 bundle epochs observed above the floor, unconfirmed (not ok), and again on the second read" 14 "24183636:unconfirmed:0:0:raw=$fxraw" "24183636:unconfirmed:0:0:raw=$fxraw"
  total=$((total + 1)); dr_reset; state_set x-drought-floor 604540; state_set x-drought-last 604550; state_set x-drought-last-h 24182000; state_set x-drought-last-hash deadbeef; state_set x-drought-newest 604589; state_set x-drought-tip 24183600; state_set x-drought-count 39
  drought_update x-drought 14 "$fxraw" 24183636 36 160 100000 deadbeef; a="$DR_OUTCOME/$DR_DROUGHT/$DR_BASIS"; drought_update x-drought 14 "$fxraw" 24183836 36 160 100000 deadbeef; b="$DR_OUTCOME/$DR_DROUGHT"
  if [ "$a" = "drought/40/sighting" ] && [ "$b" = "stall/40" ]; then echo "PASS  drought fixture: persisted sighting (anchored) with 39 absent epochs + the fixture's newest epoch -> 40, fires; tip+200 with a wide scan -> stall by distance"; else fails=$((fails + 1)); echo "FAIL  drought fixture persisted: $a | $b"; fi
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
