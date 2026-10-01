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

For threaded Slack alerts with trade charts, add the `chat:write` and `files:write` bot scopes to your Slack app, install or reinstall it, and invite the bot to the destination channel. Put its Bot User OAuth Token (`xoxb-...`) and that channel's ID (`C...`) in the ignored `slack-credentials.local.ps1` file (see the example), or set `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID` as environment variables. Restrict the credential file to your user (`chmod 600`). The notifier posts the armed setup as the thread parent and edits that first message as the trade progresses. Its first line shows the custom armed emoji, then the long or short emoji at entry, then the take-profit or stop-loss emoji at the corresponding exit. While an armed or open setup's fresh OANDA midpoint quote is inside its OTE zone, it also shows the custom in-OTE emoji; this is removed when price leaves the zone or the setup ends. Other exit reasons use a finish-flag emoji rather than being mislabeled as TP or SL. Open and close details remain in thread replies. The opened reply states the pair, direction, paper entry price and candle time, and the separate OANDA practice fill when available. Its PNG shows about five hours of M15 candles, the OTE zone, and the dashboard's A arm and L/S entry markers. The closing reply includes a second PNG from setup through exit with the same markers, a green or red trade path, and the exit dot and result. Chart rendering requires Python 3 with Pillow; the OANDA token already used by V2 is read from `credentials-v2.local.ps1`. If chart generation or upload fails, the update is sent as text. The notifier saves parent timestamps and status in the ignored `data/slack-v2-state.json` so replies and edits survive restarts. If an arm happened before bot mode was configured, the notifier recreates its parent when the trade opens or closes. New live forex events only; historical replay is excluded. Existing incoming-webhook configuration remains supported as a fallback, but sends separate text messages because Slack's webhook response has no parent timestamp. The notifier checks the V2 ledger every 20 seconds. Never commit or share the token or webhook URL. `pwsh -NoProfile -File ./slack-v2-notifier.ps1 -TestSend` sends a connection check.

At 17:00 New York on weekdays, the same notifier posts a daily V2 paper-trading report after the worker has recorded the closing bar. It shows the just-finished trading day and week to date, with entries, closed trades, win rate, gross gained and lost pips, net pips, and pair tables sorted by net pips. Only prospective `live`-origin ledger trades count; historical replay and unrealized open pips are excluded. The week starts Sunday at 17:00 New York. The report's date is saved in `data/slack-v2-state.json` to prevent duplicate posts after restarts.

With bot-token Slack access, the daily report also posts a PNG progress chart for each pair with a live trade active during that trading day. It compares the pair's realized net pips with the distance, in pips, from its frozen trade OTE zone to its completed 17:00 M15 close. For example, +35 net pips and a 100-pip zone distance fills 35% of the bar. Losses appear as red bars, open trades add no realized pips, and a missing completed close is labeled rather than estimated. Bars cap visually at 100%, while the percentage label can exceed 100% after multiple trades or an intraday reversal.

## Optional data and tools

- `/qqq` hosts a separate QQQ backtest viewer. Historical aggregates are omitted from Git. Supply a licensed `data/qqq-source.json` with `bars` containing Massive-style `t`, `o`, `h`, `l`, and `c` fields, then run `pwsh -NoProfile -File ./build-qqq-backtest.ps1`. It writes the ignored `data/qqq-backtest-6mo.json` used by the page. It models QQQ price points, not option P/L.
- `/dxy` reads an optional local `data/dxy-history.csv`; the app has no live DXY feed.
- High-impact news overlays read an optional local `data/forexfactory-calendar-current.csv`. It is a manually refreshed export, not an API timer.
- `import-v2-history.ps1` can import a compatible CSV via `-SourcePath`. Imported history is labeled replay and never sends practice orders.
- `test-oanda-account.ps1 -AccountId YOUR_PRACTICE_ACCOUNT -Environment practice` checks API access without placing an order.

## Public repository contents

The repository contains source code and example configuration only. Git ignores credentials, ledgers, logs, market data, research outputs, and generated QQQ results. No GitHub Actions, hosted server, or cloud timer is configured; the processes run only while your computer and `start.sh` are running.
