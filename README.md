# Forex Session Tracker V2

A local PowerShell dashboard and worker for 28 forex pairs. The worker reads completed OANDA M15 bid/ask candles, models Daily OTE trades, records a local paper ledger, and can optionally submit new entries to an **OANDA practice account**. The included Pine script is the TradingView reference for the V2 engine. The QQQ page is a separate historical study and never submits orders.

## Requirements

- Linux with Bash, PowerShell 7 (`pwsh`), and `iproute2` for the optional phone page.
- An OANDA v20 **practice** token and practice account ID.
- A browser for the local dashboard. Python is only needed for optional research tooling.

## Start

```bash
git clone https://github.com/danielbryson7-sketch/forex-session-tracker.git
cd forex-session-tracker
cp credentials-v2.local.ps1.example credentials-v2.local.ps1
chmod 600 credentials-v2.local.ps1
# Edit the local credential file with your practice token and account ID.
./start.sh
```

Open <http://127.0.0.1:8771/>. `credentials-v2.local.ps1` stays on your machine. You may use `OANDA_API_TOKEN`, `OANDA_ACCOUNT_ID`, and `OANDA_ENVIRONMENT=practice` environment variables instead of the file. A placeholder credential file must be removed if environment variables are used, because the file overrides them.

`./start.sh` starts the V2 chart server and worker. On a fresh checkout it **records paper trades only**. To also submit new prospective entries as actual OANDA **practice** orders, start with `ENABLE_PRACTICE_ORDERS=1 ./start.sh`. This option is deliberately explicit. The execution module rejects a live OANDA environment. Practice orders are sized to approximately **USD $0.25 per pip** using the current quote-currency conversion, with the paper stop and target attached. Broker fills, spread, and account results can differ from the modeled midpoint ledger.

The worker scans after each completed 15-minute candle, at the UTC quarter-hour plus 20 seconds. It will not submit replayed entries, old positions found after a restart, entries discovered over two minutes after the candle closed, or a position when an OANDA trade is already open for that pair. The ledger and logs live under ignored `data/`. Back up that directory before replacing your checkout.

## Strategy and timing

The V2 engine is `indicator-engine-v2.ps1`, following `daily-ote-st-ema-atr-v3.pine`. It builds yesterday's New York 17:00-to-17:00 trading-day range from completed M15 midpoint candles. A developing daily Supertrend (ATR 10, factor 3) sets direction. Yesterday's candle orients the OTE levels. An M15 zone touch and rejection arms a trade only when EMA20/EMA50 alignment and ATR14/ATR50 ≤ 1.4 pass. A **later** M15 touch of 70.5% enters. The frozen prior-day extremes are the take profit and stop. Entries are limited to the configured New York windows, two per pair per trading day, with one open trade per pair. The experimental same-candle entry discussed during research is **not** in this worker.

The dashboard's chart refreshes around M15 boundaries; the selected pair's forming candle is polled while the page is visible. The worker continues to run when the browser is closed. Price data comes from the OANDA v20 REST API; this project does not include account credentials or market-data caches.

## Optional phone page and email

`ENABLE_MOBILE=1 ./start.sh` starts the phone page on the current LAN IPv4 address, port **8768**, and prints its URL. Set `LAN_SUMMARY_IP` if auto-detection is wrong. The listener accepts only clients on that IPv4 subnet. It has **no login**: anyone on that subnet can see trade data and use its paper-close control. Do not expose that port to the internet. The main chart and credential settings remain on loopback port **8771**.

To enable hourly email, set `GMAIL_FROM`, `GMAIL_TO`, and `GMAIL_APP_PASSWORD` in your environment, or use the ignored `mail-credentials.local.ps1` for the app password, then start with `ENABLE_HOURLY_EMAIL=1 ./start.sh`. The mail process reads the **V2** ledger and V2 server, sends at the top of each hour, and records the last sent hour to avoid duplicates. `pwsh -NoProfile -File ./hourly-paper-email.ps1 -Preview` writes a local HTML preview without sending.

For Slack alerts, create a Slack incoming webhook for a channel in your workspace. Set `SLACK_WEBHOOK_URL` locally or copy `slack-credentials.local.ps1.example` to the ignored `slack-credentials.local.ps1`, fill in the URL, and restrict the file to your user (`chmod 600`). When credentials are present, `./start.sh` starts `slack-v2-notifier.ps1`. It posts **new live forex** arming, entry, and exit events, and baselines existing history on first launch so old replay rows are not sent. It checks the V2 ledger every 20 seconds. The webhook is a secret: never commit or share its URL. `pwsh -NoProfile -File ./slack-v2-notifier.ps1 -TestSend` sends a connection check.

## Optional data and tools

- `/qqq` hosts a separate QQQ backtest viewer. Historical aggregates are omitted from Git. Supply a licensed `data/qqq-source.json` with `bars` containing Massive-style `t`, `o`, `h`, `l`, and `c` fields, then run `pwsh -NoProfile -File ./build-qqq-backtest.ps1`. It writes the ignored `data/qqq-backtest-6mo.json` used by the page. It models QQQ price points, not option P/L.
- `/dxy` reads an optional local `data/dxy-history.csv`; the app has no live DXY feed.
- High-impact news overlays read an optional local `data/forexfactory-calendar-current.csv`. It is a manually refreshed export, not an API timer.
- `import-v2-history.ps1` can import a compatible CSV via `-SourcePath`. Imported history is labeled replay and never sends practice orders.
- `test-oanda-account.ps1 -AccountId YOUR_PRACTICE_ACCOUNT -Environment practice` checks API access without placing an order.

## Public repository contents

The repository contains source code and example configuration only. Git ignores credentials, ledgers, logs, market data, research outputs, and generated QQQ results. No GitHub Actions, hosted server, or cloud timer is configured; the processes run only while your computer and `start.sh` are running.
