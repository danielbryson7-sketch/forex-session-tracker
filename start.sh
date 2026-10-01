#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p data

# A fresh public checkout starts with paper tracking only. Set this to 1 to
# submit new prospective entries to an OANDA practice account.
worker_args=()
if [[ "${ENABLE_PRACTICE_ORDERS:-0}" != "1" ]]; then
  worker_args+=(-DisablePracticeExecution)
fi

pwsh -NoProfile -File ./paper-worker-v2.ps1 "${worker_args[@]}" >> data/paper-worker-v2.log 2>&1 &
worker_pid=$!
pwsh -NoProfile -File ./server-v2.ps1 -Port 8771 >> data/server-v2.log 2>&1 &
server_pid=$!
children=("$worker_pid" "$server_pid")

lan_ip="${LAN_SUMMARY_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}"
if [[ "${ENABLE_MOBILE:-0}" == "1" && -n "$lan_ip" ]]; then
  lan_cidr="$(ip -4 -o addr show | awk -v address="$lan_ip" '$4 ~ "^" address "/" {print $4; exit}')"
  lan_prefix="${lan_cidr#*/}"
  [[ "$lan_prefix" =~ ^[0-9]+$ ]] || lan_prefix=24
  pwsh -NoProfile -File ./lan-summary-v2.ps1 -BindIp "$lan_ip" -PrefixLength "$lan_prefix" >> data/lan-summary-v2.log 2>&1 &
  children+=("$!")
  echo "Mobile dashboard: http://$lan_ip:8768/"
fi

if [[ "${ENABLE_HOURLY_EMAIL:-0}" == "1" ]]; then
  pwsh -NoProfile -File ./hourly-paper-email.ps1 >> data/hourly-paper-email.log 2>&1 &
  children+=("$!")
fi

if [[ -f slack-credentials.local.ps1 || -n "${SLACK_WEBHOOK_URL:-}" || ( -n "${SLACK_BOT_TOKEN:-}" && -n "${SLACK_CHANNEL_ID:-}" ) ]]; then
  pwsh -NoProfile -File ./slack-v2-notifier.ps1 >> data/slack-v2-notifier.log 2>&1 &
  children+=("$!")
  echo 'V2 Slack trade alerts: enabled.'
fi

echo 'V2 dashboard: http://127.0.0.1:8771/'
echo 'Worker: completed M15 candles, scanned at each 15-minute boundary plus 20 seconds.'
if [[ "${ENABLE_PRACTICE_ORDERS:-0}" == "1" ]]; then
  echo 'OANDA practice order submission: enabled.'
else
  echo 'OANDA practice order submission: disabled (paper tracking only).'
fi

cleanup() {
  for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${children[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM
wait -n "${children[@]}"
