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

- **Stop the daemon cleanly before any planned reboot** — recommended (untested by
  us, but standard node behavior: a clean stop flushes the chainstate, avoiding the
  rollback and re-validation entirely):
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

## Known network-level nuance (activation week)

Price bundles may be intermittent network-wide until more mining pools add the
`digidollar-oracle` GBT rule. That is miner-side adoption, not an oracle fault —
check whether *your* slot is reporting with a fresh, valid heartbeat before assuming
you have a problem.
