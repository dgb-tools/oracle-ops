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

## Set it up (~10 minutes — start with your phone)

The monitor runs on the same Windows box as your node and oracle, and pages your
phone through [ntfy](https://ntfy.sh) — a free, open-source push service. No account
needed anywhere: a private topic name is the entire channel.

**1. Install the *official* ntfy app** (there are lookalikes in both stores — use
these exact links; the real one is by Philipp Heckel, package `io.heckel.ntfy`):

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=io.heckel.ntfy) · [F-Droid](https://f-droid.org/packages/io.heckel.ntfy/)
- **iPhone:** [App Store](https://apps.apple.com/app/ntfy/id1625396347)
- Project: [github.com/binwiederhier/ntfy](https://github.com/binwiederhier/ntfy) · [docs.ntfy.sh](https://docs.ntfy.sh)

Allow notifications when the app asks.

**2. Invent your private topic name** — long and random, like
`dgb-oracle7-k3x9v2m8q4w6`. **The topic is a password:** anyone who knows it can read
your alert stream *and send you fake alerts*. Don't pick anything guessable, don't
post it anywhere. (`install.ps1` suggests a random one if you leave the placeholder.)

**3. Subscribe your phone:** ntfy app → **+** (Add subscription) → server `ntfy.sh` →
enter your topic → subscribe. Then add ntfy to your Do-Not-Disturb / sleep-focus
exceptions — a 3 a.m. page that politely respects DND is a diary entry, not an alert.

**4. On the oracle box** — clone or [download](https://github.com/dgb-tools/oracle-ops/archive/refs/heads/main.zip) this repo anywhere (e.g. `C:\oracle-ops`):

```powershell
cd oracle-ops\monitor
copy config.json.example config.json
notepad config.json    # set: oracle_id, oracle_wallet, cli_exe, datadir, ntfy_topic
```

**5. Install** (elevated PowerShell):

```powershell
.\install.ps1          # creates the 5-min scheduled task + fires a test alert
```

**6. Verify:** the test alert should hit your phone within seconds. If it doesn't:
check the app's subscription topic matches `config.json` exactly, and that
notifications are allowed. You can also watch the raw stream in any browser at
`https://ntfy.sh/<your-topic>`.

From then on: red alerts only when something is actually wrong (with the fix commands
in the message body), a green **RECOVERED** notice when it clears, re-alerts every
`realert_hours` while a problem persists, and one quiet daily heartbeat so silence
never means "the monitor died." Prefer Telegram or a webhook instead of ntfy? Both
supported — see `config.json.example`.

**Supported today: Windows (PowerShell 5.1+, scheduled task).** One trap for anyone
extending the script: PowerShell **aliases outrank functions** — a function named
`Cli` silently invokes the built-in `cli` alias (Clear-Item) instead of itself, and
`"$var: text"` in double quotes parses the colon as scope syntax (use `"${var}:"`).
Both were found the hard way on a live deployment; stick to Verb-Noun names. Linux/macOS
operators: the checks are a direct translation (`getblockchaininfo`, `listwallets`,
`getoracles`, `getdigidollardeploymentinfo` + curl to ntfy, under cron/systemd). PRs
welcome — this repo would happily carry a bash twin.

## The runbook

[runbook.md](runbook.md) — what a hard reboot does to your oracle (chainstate
rollback, the misleading "DigiDollar is not yet active" error, why auto-start won't
resume with an encrypted wallet), the recovery procedure, how to avoid all of it
with a clean stop — and the proven two-chain **upgrade template** (v9.26.4 →
v9.26.5 in ~25 minutes, no rollback). Learned on a live slot so you don't have to.

**If you haven't upgraded yet:** v9.26.5's versionbits cache cuts the mainnet
oracle startup scan from ~15 minutes to seconds, so every future restart gets
cheaper. Drop-in binaries, no consensus change.

## Related

Part of [dgb-tools](https://github.com/dgb-tools) — open-source DigiByte tooling for
the agent economy: payments, identity, attestation, and a live x402 gateway.

MIT.
