# DigiDollar Oracle Operator's Runbook — field notes

Written by an operator (slot 29), from things that actually happened — including a
deliberate reboot test on activation day (July 17, 2026, v9.26.4, Windows Server,
`dbcache=2000`). Your numbers will vary with hardware and settings; the *behaviors*
are what matter. Corrections and additions from other operators welcome.

## What a hard reboot actually does to your oracle

Observed sequence after an unclean shutdown (power cycle / VPS reboot without stopping
the daemon):

1. **The chain rolls back to the last flushed state.** One data point from our box
   (6 vCPU VPS, `dbcache=2000`, ~15 minutes since the last flush): ~5,500 blocks
   lost. Larger `dbcache` and longer-since-flush = more unflushed work to lose. The
   node is healthy; it just has to re-validate.
2. **Re-validation runs.** Expect minutes to tens of minutes — it scales with
   hardware and rollback size (~25 minutes for our 5.5K blocks). RPC answers during
   this; the node *looks* alive.
3. **`startoracle` fails with error -1: "DigiDollar is not yet active on this
   blockchain"** — even though DigiDollar IS active on the network. This is a *local
   timing artifact*: it fires on any node whose locally-validated tip is below the
   activation height — a re-validating node after a rollback, and equally a fresh
   sync that hasn't reached it yet. Nothing is broken. Wait until your local tip
   crosses the activation block (mainnet: 23,869,440), then start normally.
4. **Don't count on the oracle resuming by itself.** In our test, auto-start did not
   fire when the wallet unlock had happened during catch-up (observed once — may not
   be universal). The safe rule: after the tip crosses activation height, **always
   run `startoracle <id>` yourself.** It's idempotent — if the oracle is already
   running it just returns `was_already_running: true`, so running it "unnecessarily"
   costs nothing.

Total observed downtime for slot 29: **~45 minutes** — with zero built-in
notification. That gap is why the [monitor](monitor/) exists.

## Recovery procedure (mainnet)

```
# 1. Wait for re-validation to finish (check local tip vs activation height):
digibyte-cli -testnet=0 -chain=main getblockchaininfo   # blocks >= 23869440?

# 2. Unlock the oracle wallet (passphrase from YOUR password manager, typed by YOU):
digibyte-cli -testnet=0 -chain=main -rpcwallet=oracle walletpassphrase "<passphrase>" <seconds>

# 3. Start the oracle (idempotent — safe to run even if unsure whether it's running):
digibyte-cli -testnet=0 -chain=main -rpcwallet=oracle startoracle <your-slot-id>

# 4. Verify — do not trust the start command alone:
digibyte-cli -testnet=0 -chain=main getoracles false
#   your slot: status=reporting, heartbeat fresh, signature valid
# Then confirm your slot on https://digibyte.io/mainnet/oracles
```

## Prevention

- **Stop the daemon cleanly before any planned reboot** — proven on our box during
  the v9.26.5 upgrade (see the upgrade section below): a clean stop flushes the
  chainstate, avoiding the rollback and re-validation entirely:
  ```
  digibyte-cli -testnet=0 -chain=main stop
  digibyte-cli -testnet stop        # if you run both chains
  # wait for the digibyted processes to exit, then reboot
  ```
  Scheduler note: a clean stop exits 0, so a restart-on-failure task policy will NOT
  relaunch the daemon — it stays down until the boot trigger. Before a planned
  reboot, that's exactly what you want.
- **Expect the wallet to reload LOCKED after any reboot** — even if you unlocked it
  with an enormous timeout. Unlock state is memory-only; it never survives a restart.
  Every reboot means: unlock, then `startoracle`.
- **Know your unlock procedure cold** before you need it at 3 a.m. The passphrase
  lives in your password manager and is typed only by you — never stored in scripts,
  scheduled tasks, or anything an AI assistant can read.
- **Run the monitor** so a dark slot pages you instead of waiting for someone in the
  community to notice. On testnet, 19 of 35 slots sat dark for days-to-weeks at one
  point — nobody was told.

## After any restart or upgrade: confirm your slot from OUTSIDE your node (v9.26.6)

Observed on slot 29, 2026-10-01 to 2026-10-06: after the v9.26.6 upgrade the oracle
auto-started on wallet unlock before the new per-round state existed, and its price
thread never broadcast. For about five days the node's own `listoracle` said running and
price-updating, heartbeats went out, and the observing node never received a price from the slot (the
local `listoracle` and the public roster at digibyte.io disagreed for the whole period). The
node's self-view cannot see this failure; a node you do not run can see what yours cannot.

1. After the oracle starts, wait fifteen minutes, then read a roster served by a node you do
   not run. digibyte.io publishes its node's view at `https://digibyte.io/api/getoracles`
   (one entry per slot: `status`, `heartbeat_status`, `last_update`, `price_source`). It is one
   observer's current-round sample, not network proof, and it is unauthenticated with no
   published rate limit: read it at monitor cadence, never from a feed.
2. **Read `last_update`, not `status`.** `status` churns every 40-block round: three reads
   of digibyte.io's roster within one hour on 2026-10-06 showed 13, 10 and 35 of 35 slots
   "reporting", all 35 with fresh heartbeats, and no slot was found to be at fault in that
   sample; a 12-read sample on the slot-29 box the same day sat at 11 to 16 of 35 for
   consecutive rounds, with slot 29 itself "reporting" in 7 of the 12 while signing normally. `last_update` is the last price the
   observer received from your slot: in the 35-of-35 read above every slot read between 45
   seconds and 11 minutes; during slot 29's silence it read 0 for days while the heartbeat
   stayed `fresh`. Those are the observations the thresholds rest on, not a general bound.
3. The failure signature is therefore: heartbeat `fresh` **and** `last_update` older than an
   hour (or 0, which the RPC help describes as the timestamp of the last price and which read
   0 throughout slot 29's silence), on three reads spanning at least fifteen minutes. One stale
   read is not a signal.
4. Corroborate before acting: read the roster again in fifteen minutes and check your own
   `listoracle`. If the signature holds, cycle the oracle: `stoporacle N`, then `startoracle N`
   (wallet unlocked). On slot 29 the observer showed a fresh `last_update` within two minutes
   and the next signed bundle included the slot four minutes later.

Two v9.26.6 behaviors that will show up and are not understood as failures:

- `Oracle: Manually cleared all pending messages and attestations` in `debug.log` every one or
  two blocks, on every node observed so far. It coincides with the per-round reset. Its full
  meaning has not been confirmed from source; it has not been associated with any failure.
- A "reporting" count that churns from read to read (9, then 35, then 17 within minutes on one
  node). It is a per-round sample, not a network health number. Heartbeats are the stable
  availability signal; price receipts per slot are read from `last_update`.

The monitors in this kit now include this check (`network_view_url`, `network_view_stale_seconds`,
`network_view_roster_stale_max` in the config): a miss is a successful read with a fresh heartbeat and
a stale `last_update` *while the roster is mostly fresh*. If half or more of the roster reads stale at the
same instant, that is a signing-round stall at the observer, not your silence, and it neither pages nor
clears. A 15-minute, 30-second-resolution sample of all 35 slots on the oracle box on 2026-10-07 showed
the roster's stale fraction swinging from 0% to 71% within minutes (median 34%); slot 29 read stale 16 of 30
times, 8 of them during such stalls. A silent slot reads stale against a fresh roster for hours and still
pages at fifteen minutes. Limitation: if the observing node itself is partitioned, the whole roster reads
stale and this check goes quiet; the local checks (sync flag, tip age) and a second node or an explorer
are the backstop. Otherwise the alert fires after three consecutive misses spanning at least fifteen minutes; a failed
fetch, a non-JSON body or an incomplete roster is never a miss and can never fire or clear an
alert: pending evidence is reset and any active alert is left standing until a good read. The alert
asks you to corroborate; it does not tell you to cycle on the first read.

## "headers == blocks" is not "synced" when peers are far ahead (testnet fork, Sep–Oct 2026)

The oracle box's testnet node sat on a dead branch from 2026-09-20 to 2026-10-07 while every
metric the kit watched said synced: `headers` equaled `blocks` and the tip aged slowly. The
tip-age threshold had been raised twice, on Aug 17 (before the incident) and on Oct 6 (during
it); the Oct 6 raise tuned the remaining symptom out. What the node was doing was refusing the
real chain: it had marked the real block 432,386 (Thaw Day + 286 on testnet26) invalid, so
every later header its peers announced was rejected, and `synced_headers` for all 30 peers
stuck at 437,232 while their `startingheight` read 451,725. A second v9.26.5 node on the Tools
VPS accepted the same block and followed the real chain, so software version alone is not the
explanation. The cause of the original invalidity mark is not recoverable: the log had
rotated. Block 432,386 contained three DigiDollar transactions, two with 226 inputs each,
which is a candidate for a validation-state divergence and nothing more.

- **What the kit checks** (both monitors, local `getpeerinfo` only): whether your *headers*
  trail what connected peers *claim*. `startingheight` is a peer's claim at connect, not a
  lower bound on the valid chain, so one peer cannot set it: at least two peers
  (`fork_min_peers`) must claim more than 100 blocks (`fork_gap_blocks`) above your headers,
  for three consecutive five-minute cycles, while your headers advance by fewer than 100
  blocks per cycle (`fork_progress_blocks`). A normal sync from behind advances far faster
  than that, and a chain at 15-second blocks adds about 20 per cycle, so a branch that merely
  keeps pace does not count as catching up. The three numbers are triage thresholds, not
  correctness boundaries. `synced_headers` is not used: per Core's help text it is "the last
  header we have in common with this peer", so it can never exceed yours and cannot show a
  dead branch.
- **What the alert says** depends on what the node looks like locally. If it reports
  `initialblockdownload=false` with headers within 10 of blocks, it looks synced, which is the
  pattern of this incident; the alert is urgent and names a dead branch as a *candidate*.
  Otherwise (still in initial block download, or headers far ahead of blocks) the alert is a
  stalled sync at normal priority and gives no `reconsiderblock` advice. Either way the
  instruction is the same: investigate why local headers trail peer claims. A node that is
  catching up is not alerted on; a node with no peer data is unknown, which resets pending
  evidence and never pages or clears.
- **Only a within-gap read clears the alert.** Unknown, catch-up and pending reads leave an
  active alert standing; a streak reset is not a recovery.
- **Fix, conditional:** `getchaintips`; a tip with `status: invalid` at a height above yours is
  the signal. Confirm with a node you trust, or an explorer, that the invalid tip's hash is on
  the real chain, and confirm your software is at the version the active rules require,
  otherwise the node rejects the block again. Only then `reconsiderblock <hash>`. On the
  oracle box on 2026-10-07 the reorg from 437,233 to 451,739 completed in about 90 seconds;
  that is one observation, not a rule.
- **Known limit, and the kit has no backstop for it:** a node whose peers are all on the same
  dead branch will not trip this check, and peers that all claim wrong heights would mis-trip
  it. The backstop is outside the kit: a second node, an explorer, or `getchaintips` on a node
  you trust. The network-view check is not a backstop here: it reads the mainnet observer's
  price receipts, not chain agreement, and a testnet node on a dead branch keeps heartbeating,
  since heartbeats do not need blocks.

## Upgrading the node (proven: v9.26.4 → v9.26.5, July 24, 2026; v9.26.6 → v9.26.7, Oct 7–8, 2026)

Total slot-29 downtime for a two-chain upgrade on our box: **~25 minutes** of machine
work, zero rollback, zero re-validation. The entire trick is stopping cleanly BEFORE the
installer runs; this supersedes reboot-and-revalidate as the maintenance path. The other
trick, learned the hard way on Oct 7, is not stopping until the next human step is certain
(step 1b).

```
# 1. Download the new installer and verify its hash BEFORE touching the node.
#    v9.26.6 (MANDATORY before mainnet block 24,490,000, ~1 Nov 2026) is the first release
#    with published checksums; GitHub's asset digests match the release notes:
#      714dfdb2a2dfcf1893b66c541386b173b1959153675699bab30eac96e0135db5  digibyte-9.26.6-win64-setup.exe
#      cdbd6ed7efdb006b91b76389db79d2a3db2593f05e56dd789f394a1b4366c211  digibyte-9.26.6-x86_64-linux-gnu.tar.gz
#    (v9.26.5 Windows asset, self-recorded because that release published none:
#    SHA256 880CDD2CC3CABCC838AEA6045647D7FD4AC4CA95BE25FD808C939641386B9325)
#    v9.26.7 (2026-10-06, /releases/latest; no consensus change, no reindex; carries the
#    getblockchaininfo difficulty-walk fix described in the correction at the end):
#      dc91563e439c8a9875a1e9ee576744d60afa60a983a1b84079afd450cfa71043  digibyte-9.26.7-win64-setup.exe
#      85f1a587e7d45fc63ef65cbbd0e5fa56f6d94f2f5cd7657a8d02ba66638cd8d6  digibyte-9.26.7-x86_64-linux-gnu.tar.gz

# 1b. DO NOT STOP ANYTHING until the operator confirms they are at the keyboard and will run
#    the next step within the minute. Download, checksum, and the pre-upgrade baseline all
#    happen before the stop; the stop itself takes minutes. On Oct 7, 2026 the oracle box was
#    stopped and the installer line handed to an operator who was away; with auto-restart
#    correctly disabled nothing relaunched, the network monitor listed slot 29 stale within
#    the hour, and the wallet-unlock step waited another ~11 hours. Total slot outage about
#    20 hours for about 20 minutes of machine work. Two rules follow:
#      - A stop-and-wait handoff carries a ~15-minute timeout. If the next human step is not
#        confirmed by then, relaunch the CURRENT version and redo the stop later.
#      - An oracle outage is never worth a non-urgent release. A node without an oracle but
#        with public services behind it (faucet, gateway, API) follows the same rule.

# 2. PAUSE AUTO-RESTART FIRST. If you installed this kit's keeper task (5-minute repetition)
#    or the systemd unit (Restart=always), it will relaunch the daemon minutes after a CLI
#    stop and race the installer. Observed on slot 29 during the v9.26.6 upgrade
#    (2026-10-01): both daemons came back mid-window, and the mainnet one was in warmup,
#    where RPC refuses `stop`.
#      Windows:  Disable-ScheduledTask -TaskName DigiByteOracleNode     (your task name)
#                Disabling prevents future launches; it does not cancel a starter that is
#                already running.
#      Linux:    sudo systemctl stop digibyted     (one command per chain if you run a unit
#                per chain). An explicit systemd stop sends SIGTERM, which is a clean
#                shutdown, and suppresses the restart. This IS the clean stop: skip step 3.

# 3. Windows, or any setup not managed by systemd: stop BOTH chains cleanly.
digibyte-cli -testnet=0 -chain=main stop
digibyte-cli -testnet stop
#    If RPC refuses `stop` because the daemon is still warming up, wait for warmup to
#    finish and ask again. Do not kill it.

# 4. WAIT for the clean flush, and confirm it. Observed shutdowns on our box: 2-4 minutes
#    in July; about 7 minutes during the v9.26.6 upgrade after 35 days of uptime; 130 s
#    during the v9.26.7 upgrade after 6 days. Flush time tracks uptime and dbcache, not the
#    version. These are observations, not guarantees. Budget 10. Confirm "Shutdown: done" in the log AND that
#    the process has exited, for both chains, before installing. Never kill the process:
#    that converts your clean upgrade into the hard-reboot scenario at the top of this
#    runbook. Note the shipped systemd unit sets TimeoutStopSec=600: systemd itself will
#    force-kill a shutdown that runs past 600 seconds, so a flush longer than that needs
#    the timeout raised first.

# 5. Run the installer over the old binaries. Then resume:
#      Linux:    sudo systemctl start digibyted
#      Windows:  Enable-ScheduledTask -TaskName DigiByteOracleNode, then start it once
#                (Start-ScheduledTask -TaskName DigiByteOracleNode). The 5-minute trigger
#                is a re-check, not a start.

# 6. Unlock the wallet, start the oracle, verify (recovery steps 2–4 above). Then confirm the
#    version from the running process, not from a file on disk: getnetworkinfo must report
#    subversion /DigiByte:9.26.7/ on both chains.
```

Observed on the v9.26.7 upgrade (oracle box, unpruned, 16 GB, 2026-10-08): silent NSIS
install rewrote the binaries in seconds; testnet RPC answered about 2 minutes after start;
mainnet about 14 minutes, then the wallet reloaded locked and the oracle auto-started on
unlock; no reindex or rebuild lines in either log; the DigiDollar stats baseline taken
before the stop matched the one taken after. Expect a pruned 8 GB box to differ; measure it.

Because the clean stop flushes the chainstate, the mainnet tip never drops below
the DigiDollar activation height — the misleading "DigiDollar is not yet active"
window never opens. On our box the oracle auto-started the moment the encrypted
wallet was unlocked; treat that as a bonus, observed once, and still verify with
`getoracles`.

**Why v9.26.5 is worth the 25 minutes:** its headline fix caches versionbits
state, cutting the mainnet oracle startup scan from ~15 minutes to seconds —
every future restart, planned or otherwise, gets cheaper. No consensus change,
no coordination deadline; drop-in binaries.

## Known network-level nuance (activation week)

Price bundles may be intermittent network-wide until more mining pools add the
`digidollar-oracle` GBT rule. That is miner-side adoption, not an oracle fault —
check whether *your* slot is reporting with a fresh, valid heartbeat before assuming
you have a problem.

## The August 2026 crash — what a network-wide incident looks like from inside

On August 26–27, 2026, a malformed network message crashed mainnet daemons across
the oracle network. Reporting oracles fell from ~31 of 35 to **11** (quorum is 7)
within hours, and recovery took about a day — driven almost entirely by operators
noticing by hand. Our slot was among the crashed and came back quickly for one
boring reason: a scheduled task restarted the daemon, and the monitor paged us.
Everything in this section is what that day taught.

### Make the restart automatic — the two Windows task traps

A startup-only scheduled task starts your daemon **once per boot**. The first
crash after that leaves the box dark until a human logs in — which is exactly how
most slots spent the incident. Two settings fix it, and both are non-defaults:

1. **Add a repetition trigger** (every 5 minutes) that runs a starter script which
   exits silently when the daemon is already up. Boot trigger alone is not a
   restart policy.
2. **Set the task's execution time limit to 0.** The Windows default (PT72H)
   silently kills any task after 72 hours — for a task that IS your daemon, that
   is a scheduled outage three days after every boot.

The kit's `monitor/install-node-task.ps1` registers a task with both settings;
`linux/systemd/digibyted.service` is the same protection via `Restart=always`.

A third trap, for anyone editing the PowerShell scripts: variable names are case-insensitive,
so a local `$net` inside a function that declares a `[string[]]$Net` parameter is the same
variable, and every assignment to it is coerced to strings. Name locals distinctly from every
parameter, ignoring case. (Found on slot 29, 2026-10-06: a roster of 35 objects became 35
strings and every oracle id read as absent.)

### Post-crash triage: one incident, not two

After an unclean daemon death, **`getdigidollarstats` can stay unavailable for
HOURS while `getoracles` and `getoracleprice` work perfectly.** The DigiDollar
stats index rebuilds from genesis after a crash (~100K blocks/min on our box);
the oracle-price index is separate and comes back immediately. So a node whose
oracle is signing fine but whose stats RPC errors is EXPECTED after a crash — it
is the tail of the same incident, not a second one. It self-heals; don't restart
the node again (that starts the rebuild over).

### Read the crash class before you shrug

The monitor and the node keeper (`start-node.ps1`, the auto-restart task; not the withdrawn
`anchor-keeper.ps1`) annotate every daemon-down alert with a crash-class
read from the last 400 log lines. What the classes mean:

| Signature in the log | What it means | What to do |
|---|---|---|
| `length_error` / `vector::reserve` | the oversized-message class from this incident | restart is safe; be on the latest release |
| `bad_alloc` | out of memory | check RAM vs `dbcache` before it repeats |
| `Assertion failed` | consensus-adjacent bug | save the log, report to Core |
| `Corrupted block database` | unclean-death damage | expect `-reindex`; see reboot section |
| `Disk space is too low` | disk full | free space; the monitor's disk check warns earlier |

A crash with **no** known signature is worth keeping the log for — new classes
are how the next incident gets named.

### Are your price sources reachable?

Every oracle fetches the same six public exchange APIs and needs **3 of 6** to
publish. If your slot stops publishing with the daemon healthy, check outbound
reachability before suspecting the oracle (`Insufficient price sources` in the
log is the giveaway — see the operator guide's exchange-feed section). A quick
probe from the box:

```
curl -sfm 10 -o /dev/null -w "coingecko %{http_code}\n" "https://api.coingecko.com/api/v3/ping"
curl -sfm 10 -o /dev/null -w "binance   %{http_code}\n" "https://api.binance.com/api/v3/ping"
curl -sfm 10 -o /dev/null -w "kucoin    %{http_code}\n" "https://api.kucoin.com/api/v1/timestamp"
```

Any two of those failing from a box that can otherwise reach the internet means
your slot's problem is network egress (DNS, TLS CA bundle, geoblocking), not
DigiByte.

### Version lag is the exploit window

During the incident, seven slots were running releases one or two versions old.
When a crash-fix release ships, the gap between "release published" and "your
slot upgraded" is the window in which the same bug can take you down again. The
monitor's version-drift check exists for exactly this; the runbook's upgrade
template above makes the fix a 25-minute job. Treat a version-drift alert as
maintenance scheduling, not information.

### Correction, 2026-10-01: "rpc-accept-dead" was a misdiagnosis

On 2026-09-09 this runbook described a crash class `rpc-accept-dead` on our prune-mode anchor
node and said a keeper had been dry-run verified against it. **Both statements were incorrect,
and the error was ours.** The condition is now named **RPC timeout with chain-progress stall;
cause unconfirmed.** Three levels of evidence, kept separate:

- **Observed (2026-10-01, v9.26.5, Windows, 8 GB RAM, `prune=10000`).** Block processing and
  RPC stopped together for 14 minutes 37 seconds (last `UpdateTip` 22:30:05Z, next 22:44:42Z),
  then the node resumed and caught up 60 blocks within seconds, under the same process, with
  no restart. Earlier instances lasted about 30 and 103 minutes and also ended by themselves.
- **Strongly implicated trigger.** All four recorded stalls followed our own
  `getblockchaininfo` request on that node. On 2026-10-01, `getblockcount` and
  `getdigidollarstats` had answered seconds earlier.
- **Leading explanation (Core, 2026-10-06); attribution unconfirmed.** Core identified and
  fixed a difficulty-history walk under `cs_main` in v9.26.7: the release notes say
  `getblockchaininfo` and `getchainstates` previously computed the scalar `difficulty` with a
  default that "could walk far back through retired Groestl history while holding the main
  chain lock, delaying other requests", and v9.26.7 reads the difficulty directly from the
  tip block. The change is four lines in `src/rpc/blockchain.cpp` (`GetDifficulty(&tip,
  nullptr)` becomes a call that passes the tip's own algorithm). This is now the leading
  explanation for our stalls, including the oracle box's unpruned eight-minute case. It does
  not require prune mode. Our earlier prune-height explanation is superseded; attribution to
  this incident remains unconfirmed without a trace or a controlled before/after measurement.
  Whether memory pressure or pruning made the walk slower on this box is unmeasured. v9.26.7
  contains the fix and no consensus change.

What follows from the observation alone:

- A probe timeout means **unknown**, not dead, and is not permission to kill. This node
  recovered every time without a restart.
- Separate two questions. *Is the process and its network side responsive?* and *is the tip
  advancing?* `getblockcount` also takes `cs_main` and will time out during such a stall;
  `getnetworkinfo` answering does not show chain progress. Read local tip advancement from
  this node's `UpdateTip` log; use an independent explorer to measure network advancement
  and the node's lag.
- `getdigidollarstats` is not free either: it paused block processing for about a minute in
  the same timeline. Do not schedule heavy RPC calls against a node that has shown this stall.
- A client timeout does not cancel the call on the server. Repeated probes can pile up behind
  the one already running.
- The oracle box (unpruned) showed a related effect in August: `getblockchaininfo` went
  unanswered for about eight minutes while a stats-index rebuild held the same lock.

**Known issue in this kit's own monitor.** `oracle-monitor.ps1` and `dgb-oracle-monitor.sh` call
`getblockchaininfo` on every run to read blocks, headers, tip time and the initial-sync flag. On
any version before v9.26.7 that is the call Core's note identifies, issued every five minutes.
On the oracle box (unpruned) the monitor has done this since July without a recorded stall of
its own; on the anchor (8 GB, `prune=10000`, v9.26.5) our `getblockchaininfo` calls preceded
all four recorded stalls. Whether box size or pruning changes the cost is unmeasured. Until the
monitor's liveness check is changed, do not point it at a node that has shown this stall, and
run v9.26.7 where you can.

**`monitor/anchor-keeper.ps1` is withdrawn.** It would have mistaken this recoverable stall for
a condition requiring termination. It was never installed. A bounded escalation path remains
the goal: alert on a stall that outlasts a stated limit and leave the decision to restart to
the operator, with thread stacks and CPU and disk figures captured first.
