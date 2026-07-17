# DigiDollar Oracle Operator's Runbook — field notes

Written by an operator (slot 29), from things that actually happened — including a
deliberate reboot test on activation day (July 17, 2026, v9.26.4, Windows Server,
`dbcache=2000`). Your numbers will vary with hardware and settings; the *behaviors*
are what matter. Corrections and additions from other operators welcome.

## What a hard reboot actually does to your oracle

Observed sequence after an unclean shutdown (power cycle / VPS reboot without stopping
the daemon):

1. **The chain rolls back to the last flushed state** — in our case ~5,500 blocks
   (larger `dbcache` = more unflushed work to lose). The node is healthy; it just has
   to re-validate.
2. **Re-validation runs** (~260 blocks/min on a 4-core VPS ≈ 25 minutes for 5.5K
   blocks). RPC answers during this; the node looks alive.
3. **`startoracle` fails with error -1: "DigiDollar is not yet active on this
   blockchain"** — even though DigiDollar IS active on the network. This is a *local
   timing artifact*: your node's re-validating tip is still below the activation
   height. Nothing is broken. Wait until your local tip re-crosses the activation
   block (mainnet: 23,869,440), then start normally.
4. **Auto-start does not resume if your wallet unlock happened during catch-up.**
   With an encrypted wallet, the unlock does not persist across the reboot, and
   unlocking while the node is still re-validating does not arm the oracle. After
   the tip crosses activation height you must run `startoracle <id>` manually.

Total observed downtime for slot 29: **~45 minutes** — with zero built-in
notification. That gap is why the [monitor](monitor/) exists.

## Recovery procedure (mainnet)

```
# 1. Wait for re-validation to finish (check local tip vs activation height):
digibyte-cli -testnet=0 -chain=main getblockchaininfo   # blocks >= 23869440?

# 2. Unlock the oracle wallet (passphrase from YOUR password manager, typed by YOU):
digibyte-cli -testnet=0 -chain=main -rpcwallet=oracle walletpassphrase "<passphrase>" <seconds>

# 3. Start the oracle:
digibyte-cli -testnet=0 -chain=main -rpcwallet=oracle startoracle <your-slot-id>

# 4. Verify — do not trust the start command alone:
digibyte-cli -testnet=0 -chain=main getoracles false
#   your slot: status=reporting, heartbeat fresh, signature valid
# Then confirm your slot on https://digibyte.io/mainnet/oracles
```

## Prevention

- **Stop the daemon cleanly before any planned reboot** (`digibyte-cli stop`, wait for
  exit). A clean shutdown flushes the chainstate, which avoids the rollback and the
  re-validation wait entirely.
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
