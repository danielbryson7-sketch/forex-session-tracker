#!/usr/bin/env python3
"""Render the five-hour M15 snapshot attached to a V2 Slack entry."""

import json
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFont


def font(size, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    path = Path("/usr/share/fonts/truetype/dejavu") / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main(source, destination):
    trade = json.loads(Path(source).read_text())
    bars = sorted(trade["bars"], key=lambda row: row["time"])
    if len(bars) < 2:
        raise ValueError("Need at least two completed M15 candles for the chart")

    width, height = 1280, 680
    left, right, top, bottom = 92, 1158, 92, 565
    navy, panel, grid = "#081725", "#10263a", "#2b4052"
    image = Image.new("RGB", (width, height), navy)
    d = ImageDraw.Draw(image)
    d.rectangle((left, top, right, bottom), fill=panel)
    small, medium, title = font(17), font(19), font(27, True)

    pair = trade["pair"]
    digits = 3 if pair.endswith("/JPY") else 5
    fmt = lambda value: f"{float(value):.{digits}f}"
    side = trade["direction"].upper()
    d.text((left, 27), f"{pair}  ·  {side} opened", font=title, fill="#f2f7fb")
    d.text((right, 33), "OANDA bid M15 · 5 hours through entry · New York time", anchor="ra", font=small, fill="#a2b8ca")

    low_zone = float(trade["zoneLow"])
    high_zone = float(trade["zoneHigh"])
    entry_level = float(trade["entryTarget"])
    values = [float(b[key]) for b in bars for key in ("high", "low")]
    values.extend((low_zone, high_zone, entry_level))
    pmin, pmax = min(values), max(values)
    span = max(pmax - pmin, 0.0002 if digits == 5 else 0.02)
    pmin -= span * 0.12
    pmax += span * 0.12

    def y(price):
        return bottom - (float(price) - pmin) / (pmax - pmin) * (bottom - top)

    for i in range(6):
        yy = top + i * (bottom - top) / 5
        d.line((left, yy, right, yy), fill=grid, width=1)
        d.text((right + 14, yy), fmt(pmax - i * (pmax - pmin) / 5), anchor="lm", font=small, fill="#95aabd")

    zone_top, zone_bottom = sorted((y(high_zone), y(low_zone)))
    overlay = Image.new("RGBA", image.size)
    od = ImageDraw.Draw(overlay)
    od.rectangle((left, zone_top, right, zone_bottom), fill=(255, 180, 38, 36))
    image = Image.alpha_composite(image.convert("RGBA"), overlay)
    d = ImageDraw.Draw(image)
    for level in (low_zone, high_zone):
        yy = y(level)
        d.line((left, yy, right, yy), fill="#efa843", width=2)
    entry_y = y(entry_level)
    for xx in range(left, right, 16):
        d.line((xx, entry_y, min(xx + 8, right), entry_y), fill="#ffd166", width=2)
    d.text((left + 8, zone_top + 7), "OTE ZONE", font=small, fill="#ffca79")

    signal_time = parse_time(trade["signalTime"])
    entry_time = parse_time(trade["entryTime"])
    ny = ZoneInfo("America/New_York")
    step = (right - left) / 20
    start = entry_time.timestamp() - 19 * 900

    def x_for(moment):
        return left + step / 2 + (moment.timestamp() - start) / 900 * step

    entry_x = x_for(entry_time)
    d.rectangle((entry_x - step * 0.46, top, entry_x + step * 0.46, bottom), outline="#489be0", width=2)
    for bar in bars:
        moment = parse_time(bar["time"])
        xx = x_for(moment)
        if xx < left or xx > right:
            continue
        op, hi, lo, cl = (float(bar[key]) for key in ("open", "high", "low", "close"))
        color = "#22c7b7" if cl >= op else "#fb6269"
        body = max(4, step * 0.47)
        d.line((xx, y(hi), xx, y(lo)), fill=color, width=2)
        d.rectangle((xx - body / 2, min(y(op), y(cl)), xx + body / 2,
                     max(y(op), y(cl)) if abs(y(op) - y(cl)) >= 2 else min(y(op), y(cl)) + 2),
                    fill=color)

    signal_x = x_for(signal_time)
    if left <= signal_x <= right:
        match = next((b for b in bars if parse_time(b["time"]) == signal_time), None)
        marker_y = max(top + 18, y(match["high"]) - 26) if match else top + 27
        r = 9
        d.polygon(((signal_x, marker_y - r), (signal_x + r, marker_y),
                   (signal_x, marker_y + r), (signal_x - r, marker_y)), fill="#ffb44c")
        d.text((signal_x, marker_y - 18), "SIGNAL", anchor="mb", font=small, fill="#ffca79")

    for index in range(0, 20, 4):
        moment = datetime.fromtimestamp(start + index * 900, tz=entry_time.tzinfo).astimezone(ny)
        d.text((left + step / 2 + index * step, bottom + 16), moment.strftime("%H:%M"),
               anchor="mt", font=small, fill="#99aec2")
    d.text((entry_x, bottom + 16), entry_time.astimezone(ny).strftime("%H:%M"),
           anchor="mt", font=small, fill="#70bfff")
    d.text((left, 626), f"OTE {fmt(low_zone)}–{fmt(high_zone)}  ·  70.5% entry {fmt(entry_level)}",
           font=medium, fill="#e9bc65")
    d.text((right, 626), f"Signal {signal_time.astimezone(ny):%m/%d %H:%M}  ·  Entry {entry_time.astimezone(ny):%m/%d %H:%M}",
           anchor="ra", font=small, fill="#a2b8ca")
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(destination, format="PNG", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: render-slack-trade-chart.py trade.json chart.png")
    main(sys.argv[1], sys.argv[2])
