# Oracle Operator Starter Kit — one page

You run (or want to run) a DigiDollar oracle slot. This page gets your slot to
the state where **a crash fixes itself and a real problem pages your phone** —
in about 15 minutes. Everything is free and open source; nothing here touches
your keys or passphrase.

## Why bother

In the August 2026 incident, one malformed network message crashed daemons
across the oracle network. Reporting slots fell from ~31/35 to **11** — the
price feed needs 7 — and recovery took about a day, because most slots had no
auto-restart and no monitoring. The slots that came back in minutes had both.
This kit is that setup.

## The 15 minutes

**1. Phone first (2 min).** Install the official [ntfy](https://ntfy.sh) app
([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) ·
[iPhone](https://apps.apple.com/app/ntfy/id1625396347)), invent a long random
topic name (it's a password — `dgb-oracle7-k3x9v2m8q4w6`, not `my-oracle`),
subscribe to it.

**2. Get the kit onto the box (1 min).**
[Download](https://github.com/dgb-tools/oracle-ops/archive/refs/heads/main.zip)
or `git clone https://github.com/dgb-tools/oracle-ops`.

**3. Configure (5 min).**
- *Windows:* `monitor\config.json.example` → `config.json`; set `oracle_id`,
  `oracle_wallet`, `cli_exe`, `daemon_exe`, `datadir`, `ntfy_topic`.
- *Linux:* `linux/config.example` → `config`; same fields, shell syntax.

**4. Install auto-restart (3 min).** The part that matters most.
- *Windows (elevated):* `monitor\install-node-task.ps1` — boot trigger + 5-min
  re-check + no 72-hour task kill.
- *Linux:* edit `linux/systemd/digibyted.service` (User=, paths), then
  `sudo cp` it into `/etc/systemd/system/`, `daemon-reload`, `enable --now`.

**5. Install the monitor (3 min).**
- *Windows (elevated):* `monitor\install.ps1`
- *Linux:* `sudo linux/install.sh`

Both fire a test alert — if your phone buzzes, you're done.

**6. Prove it (1 min, recommended).** Kill your daemon on purpose — a *hard*
kill, simulating a crash: `taskkill /f /im digibyted.exe` on Windows,
`sudo systemctl kill -s SIGKILL digibyted` on Linux. (A plain `systemctl
kill` sends SIGTERM — the clean-stop path, which can sit in the shutdown
timeout instead of demonstrating crash recovery.) Within ~5 minutes: the
daemon is back, and your phone explains what happened. If your
oracle wallet is encrypted, the alert also reminds you the ORACLE needs a
manual unlock — that's by design, not a bug.

## What you'll get afterward

- Red alerts only when something is wrong, **with the fix commands in the
  message** and a crash-class read (what killed the daemon, not just that it
  died)
- A green RECOVERED notice when it clears; a quiet daily heartbeat so silence
  never means "the monitor died"
- A version-drift warning when a new Core release ships — during the August
  incident, seven slots were running old releases; when the fix ships, the
  un-upgraded window is where the same crash can repeat

## When something does break

[runbook.md](runbook.md) — written from live incidents on slot 29: what a hard
reboot does to an oracle, the misleading "DigiDollar is not yet active" error,
the 25-minute clean-upgrade procedure, post-crash triage (why
`getdigidollarstats` can error for hours while your oracle signs happily), and
the crash-class table.

## Want a slot of your own?

Slot assignment is handled by DigiByte Core — see
[`docs/ORACLE_OPERATOR_GUIDE.md`](https://github.com/DigiByte-Core/digibyte/blob/develop/docs/ORACLE_OPERATOR_GUIDE.md)
in the Core repo (generate a key, send the maintainer your *public* key, run
`startoracle` once a release includes it). What Core asks of you is 95%+
uptime; this kit is how a volunteer operator actually delivers that.

---
*Part of [oracle-ops](README.md) · [dgb-tools](https://github.com/dgb-tools) ·
MIT · written by the operator of slot 29. Corrections from other operators
make this better — issues and PRs welcome.*
