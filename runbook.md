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

## Upgrading the node (proven: v9.26.4 → v9.26.5, July 24, 2026)

Total slot-29 downtime for a two-chain upgrade on our box: **~25 minutes**, zero
rollback, zero re-validation. The entire trick is stopping cleanly BEFORE the
installer runs — this supersedes reboot-and-revalidate as the maintenance path:

```
# 1. Download the new installer and verify its hash BEFORE touching the node.
#    (v9.26.5 Windows asset, self-recorded — the release published no checksums:
#    SHA256 880CDD2CC3CABCC838AEA6045647D7FD4AC4CA95BE25FD808C939641386B9325)

# 2. Stop BOTH chains cleanly:
digibyte-cli -testnet=0 -chain=main stop
digibyte-cli -testnet stop

# 3. WAIT for the clean flush — 2–4 minutes with a big dbcache. The log line you
#    want is "Shutdown: done". Never kill the process: that converts your clean
#    upgrade into the hard-reboot scenario at the top of this runbook.

# 4. Run the installer over the old binaries; restart your tasks/daemons.

# 5. Unlock the wallet, start the oracle, verify (recovery steps 2–4 above).
```

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

### Post-crash triage: one incident, not two

After an unclean daemon death, **`getdigidollarstats` can stay unavailable for
HOURS while `getoracles` and `getoracleprice` work perfectly.** The DigiDollar
stats index rebuilds from genesis after a crash (~100K blocks/min on our box);
the oracle-price index is separate and comes back immediately. So a node whose
oracle is signing fine but whose stats RPC errors is EXPECTED after a crash — it
is the tail of the same incident, not a second one. It self-heals; don't restart
the node again (that starts the rebuild over).

### Read the crash class before you shrug

The monitor and keeper now annotate every daemon-down alert with a crash-class
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

### Crash classes added 2026-09-09 (anchor node, v9.26.5 Windows)

| class | what you see | what it is not | remedy |
|---|---|---|---|
| `rpc-accept-dead` | process alive; `UpdateTip` still advancing in `debug.log`; RPC port `LISTENING` with nothing connected; every `digibyte-cli` call fails with *"Could not connect … timeout reached"* for minutes | not a crash (no signal, no exit), not a hang (blocks keep flowing), not a stuck client (kill the clients, it persists) | `monitor/anchor-keeper.ps1`: 5 consecutive failed probes on the same PID → kill that PID → wait for the port to free → boot task once → verify new PID answers RPC → once more if not → alert. Budget 3/day. |
| `process-hung` | process alive, height not advancing, log stalls | not `rpc-accept-dead` — the keeper records it and pages, it does not auto-restart | investigate; hard-kill by hand if confirmed |

Seen three times in 48 hours on the same anchor, and **intermittent**: the RPC came back on its own after stretches of roughly 10–100 minutes (14:00→15:43Z on 09-08; ~23:00→23:31Z on 09-09) with the same PID throughout. So: the keeper's 5-consecutive-minute rule restarts only inside a stretch; a scheduled RPC client (the calendar batcher) must retry across its window rather than fail on the first dead minute; and a dry-run of the keeper against the live class classified it correctly on 09-09 (`rpc-accept-dead`, height advancing 24183614→24183615) while the real kill path has not yet fired — the RPC recovered before the live run's first probe. A boot-trigger-only task reports "currently running" after the daemon is killed; the first `schtasks /Run` clears that stale instance and starts nothing — the keeper accounts for that. Log rotation is a false "stall"; a node in IBD answers RPC with `-28`, which the keeper treats as healthy for this class.
