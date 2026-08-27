#!/usr/bin/env bash
# Installs the Linux oracle monitor as a systemd timer (every 5 minutes) and,
# optionally, the digibyted auto-restart service. Run as root (sudo) from this
# directory, AFTER copying config.example to config and editing it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo (installs systemd units)." >&2; exit 1; }
[ -f "$HERE/config" ] || { echo "No config found. Copy config.example to config and edit it first." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required: apt install jq (or dnf install jq)." >&2; exit 1; }

# shellcheck source=/dev/null
. "$HERE/config"

# The ntfy topic is effectively a password: refuse to install the placeholder.
if [ "${NTFY_TOPIC:-}" = "PICK-A-LONG-RANDOM-TOPIC-NAME" ] || [ -z "${NTFY_TOPIC:-}${TELEGRAM_BOT_TOKEN:-}${WEBHOOK_URL:-}" ]; then
  suggested="dgb-oracle${ORACLE_ID:-X}-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 24)"
  echo "Set a private NTFY_TOPIC in config first (or a Telegram/webhook channel)." >&2
  echo "Suggested random topic:  $suggested" >&2
  echo "Subscribe to it in the ntfy app, then re-run install." >&2
  exit 1
fi

# Monitor user: reuse the unit's default (digibyte) unless overridden.
RUN_USER="${MONITOR_USER:-digibyte}"
if ! id "$RUN_USER" >/dev/null 2>&1; then
  echo "User '$RUN_USER' does not exist. Set MONITOR_USER in config to the user that runs your node." >&2
  exit 1
fi

chmod +x "$HERE/dgb-oracle-monitor.sh"

# The monitor runs as $RUN_USER but this checkout is often root-owned (sudo
# git clone): make sure the state dir and logs are writable by the monitor,
# or every run fails silently from its own timer.
mkdir -p "$HERE/state"
touch "$HERE/monitor.log"
chown -R "$RUN_USER" "$HERE/state" "$HERE/monitor.log"

# Write units pointing at THIS checkout (no /opt copy needed).
sed -e "s|^ExecStart=.*|ExecStart=$HERE/dgb-oracle-monitor.sh|" \
    -e "s|^User=.*|User=$RUN_USER|" \
    "$HERE/systemd/dgb-oracle-monitor.service" > /etc/systemd/system/dgb-oracle-monitor.service
cp "$HERE/systemd/dgb-oracle-monitor.timer" /etc/systemd/system/dgb-oracle-monitor.timer

systemctl daemon-reload
systemctl enable --now dgb-oracle-monitor.timer

echo "Monitor timer installed and started (every 5 minutes, as $RUN_USER)."
echo "Sending test alert..."
sudo -u "$RUN_USER" "$HERE/dgb-oracle-monitor.sh" --test
echo "If no notification arrived, check your ntfy topic subscription and config."
echo ""

# The monitor is installed - but the monitor only TELLS you the daemon died.
# Auto-restart is the protection the August 2026 incident was about, and it
# is a separate unit. Do not let a green test alert read as "done".
if [ -n "${DAEMON_SERVICE:-}" ] && ! systemctl list-unit-files 2>/dev/null | grep -q "^$DAEMON_SERVICE.service"; then
  echo "=================================================================="
  echo "  WARNING - AUTO-RESTART: NOT INSTALLED"
  echo "=================================================================="
  echo "DAEMON_SERVICE='$DAEMON_SERVICE' is set but no such systemd unit"
  echo "exists. Your monitor will PAGE you when the daemon dies, but nothing"
  echo "will RESTART it - which is exactly how most oracle slots spent the"
  echo "August 2026 incident. Finish the job:"
  echo "  1. Edit $HERE/systemd/digibyted.service (User= and paths)"
  echo "  2. sudo cp $HERE/systemd/digibyted.service /etc/systemd/system/"
  echo "  3. sudo systemctl daemon-reload && sudo systemctl enable --now digibyted"
  echo "(Stop any manually-started daemon first: digibyte-cli stop)"
  echo "=================================================================="
else
  echo "AUTO-RESTART: covered ('$DAEMON_SERVICE' unit present, or DAEMON_SERVICE unset by choice)."
fi
