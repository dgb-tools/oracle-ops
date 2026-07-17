# oracle-ops

**Tools and field notes for DigiDollar oracle operators.** A personal watchdog that
pages *you* when *your* slot goes dark, plus an operator's runbook written from
things that actually happened — including what a reboot really does to a running
oracle (spoiler: more than you'd think).

> Written by the operator of slot 29, live on mainnet since ~40 minutes after
> DigiDollar activation (block 23,869,440, July 17, 2026). Independent community
> project — not affiliated with the DigiByte Foundation.

## Why this exists

[digibyte.io](https://digibyte.io/mainnet/oracles) already has an excellent oracle
dashboard — it shows the whole room. What it can't do is wake **you** when **your**
slot stops signing. On testnet, 19 of 35 slots sat dark at one point, some for weeks;
nobody was notified, because nothing existed to notify them. DigiDollar's price feed
needs 7 of 35 signatures — every dark slot thins the margin.

The monitor is the complement, not a replacement: a small watchdog on your own box,
checking your own node, paging your own phone.

## What the monitor checks (every 5 minutes)

| Check | Alert when |
|---|---|
| Daemon process (testnet + mainnet) | `digibyted` not running |
| RPC | daemon up but not answering |
| Sync | in IBD, header lag, or stale tip |
| Oracle wallet | not loaded |
| **Your oracle slot** | not `reporting`, stale/invalid heartbeat, or absent from `getoracles` — with wallet-locked detection and fix instructions in the alert itself |
| DigiDollar deployment (mainnet) | state changes (e.g. the moment it flips `active`, with your start instructions) |
| Disk / version drift | low space; local version behind latest release |
| Daily heartbeat | one quiet "all is well" so silence never means "broken monitor" |

Alerts dedupe (re-send every `realert_hours`), and every failure sends a matching
**RECOVERED** notice. Channels: [ntfy](https://ntfy.sh) (easiest — install the app,
subscribe to your topic, done), Telegram bot, or any webhook.

**Read-only by design:** status RPCs only. It never touches keys, wallets, or
passphrases — your passphrase is typed by you, at a keyboard, or not at all.

## Quick start (Windows)

```powershell
cd monitor
copy config.json.example config.json
# edit config.json: your slot id, paths, and a LONG RANDOM ntfy topic name
# (anyone who knows the topic can read your alerts — treat it like a password)
.\install.ps1        # elevated: creates the 5-min scheduled task + sends a test alert
```

**Supported today: Windows (PowerShell 5.1+, scheduled task).** Linux/macOS
operators: the checks are a direct translation (`getblockchaininfo`, `listwallets`,
`getoracles`, `getdigidollardeploymentinfo` + curl to ntfy, under cron/systemd). PRs
welcome — this repo would happily carry a bash twin.

## The runbook

[runbook.md](runbook.md) — what a hard reboot does to your oracle (chainstate
rollback, the misleading "DigiDollar is not yet active" error, why auto-start won't
resume with an encrypted wallet), the recovery procedure, and how to avoid all of it
with a clean stop. Learned on a live slot so you don't have to.

## Related

Part of [dgb-tools](https://github.com/dgb-tools) — open-source DigiByte tooling for
the agent economy: payments, identity, attestation, and a live x402 gateway.

MIT.
