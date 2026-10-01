#!/usr/bin/env python3
"""Render V2 Slack trade charts with the dashboard's arm, entry, and exit markers."""

import json
import math
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFont

NY = ZoneInfo("America/New_York")


def font(size, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    path = Path("/usr/share/fonts/truetype/dejavu") / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def badge(draw, x, y, letter, fill):
    draw.ellipse((x - 12, y - 12, x + 12, y + 12), fill=fill, outline="#0c1928", width=3)
    draw.text((x, y + 1), letter, anchor="mm", font=font(13, True), fill="#0c1928")


def main(source, destination):
    trade = json.loads(Path(source).read_text())
    bars = sorted(trade["bars"], key=lambda row: row["time"])
    if len(bars) < 2:
        raise ValueError("Need at least two completed M15 candles for the chart")
    mode = trade.get("mode", "entry")
    if mode not in ("entry", "close"):
        raise ValueError("Chart mode must be entry or close")
    pair, side = trade["pair"], trade["direction"].upper()
    digits = 3 if pair.endswith("/JPY") else 5
    fmt = lambda value: f"{float(value):.{digits}f}"
    signal_time = parse_time(trade["signalTime"])
    entry_time = parse_time(trade["entryTime"])
    end_time = parse_time(trade["exitTime"]) if mode == "close" else entry_time
    first_time = min(parse_time(bars[0]["time"]), signal_time)
    last_time = max(parse_time(bars[-1]["time"]), end_time)
    slots = max(20, math.ceil((last_time - first_time).total_seconds() / 900) + 1)
    width, height = min(2400, max(1280, 325 + slots * 20)), 770
    left, right, top, bottom = 100, width - 145, 106, 608
    image = Image.new("RGB", (width, height), "#081725")
    d = ImageDraw.Draw(image)
    d.rectangle((left, top, right, bottom), fill="#10263a")
    small, medium, title = font(17), font(19), font(29, True)
    result = float(trade.get("netPips", 0))
    outcome = f"closed {result:+.1f} pips" if mode == "close" else "opened"
    d.text((left, 30), f"{pair}  ·  {side} {outcome}", font=title, fill="#f2f7fb")
    d.text((right, 40), "OANDA bid M15 · New York time", anchor="ra", font=small, fill="#a2b8ca")

    low_zone, high_zone = float(trade["zoneLow"]), float(trade["zoneHigh"])
    entry_level = float(trade["entryTarget"])
    signal_price, entry_price = float(trade["signalPrice"]), float(trade["entryPrice"])
    exit_price = float(trade["exitPrice"]) if mode == "close" else None
    values = [float(b[key]) for b in bars for key in ("high", "low")]
    values.extend((low_zone, high_zone, entry_level, signal_price, entry_price))
    if exit_price is not None:
        values.append(exit_price)
    pmin, pmax = min(values), max(values)
    span = max(pmax - pmin, 0.0002 if digits == 5 else 0.02)
    pmin -= span * 0.12
    pmax += span * 0.12

    def y(price):
        return bottom - (float(price) - pmin) / (pmax - pmin) * (bottom - top)

    def x(moment):
        elapsed = (moment - first_time).total_seconds()
        duration = max(900, (last_time - first_time).total_seconds())
        return left + 18 + elapsed / duration * (right - left - 36)

    for i in range(6):
        yy = top + i * (bottom - top) / 5
        d.line((left, yy, right, yy), fill="#2b4052", width=1)
        d.text((right + 14, yy), fmt(pmax - i * (pmax - pmin) / 5),
               anchor="lm", font=small, fill="#95aabd")
    zone_top, zone_bottom = sorted((y(high_zone), y(low_zone)))
    overlay = Image.new("RGBA", image.size)
    ImageDraw.Draw(overlay).rectangle((left, zone_top, right, zone_bottom), fill=(255, 180, 38, 36))
    image = Image.alpha_composite(image.convert("RGBA"), overlay)
    d = ImageDraw.Draw(image)
    for level in (low_zone, high_zone):
        d.line((left, y(level), right, y(level)), fill="#efa843", width=2)
    for xx in range(left, right, 16):
        d.line((xx, y(entry_level), min(xx + 8, right), y(entry_level)), fill="#ffd166", width=2)
    zone_label_y = max(top + 10, min(bottom - 30, zone_top + 6))
    d.text((left + 8, zone_label_y), "OTE ZONE", font=small, fill="#ffca79")

    step = (right - left - 36) / max(1, (last_time - first_time).total_seconds() / 900)
    body_width = max(5, min(14, step * 0.5))
    for bar in bars:
        moment = parse_time(bar["time"])
        xx = x(moment)
        if not left <= xx <= right:
            continue
        op, hi, lo, cl = (float(bar[key]) for key in ("open", "high", "low", "close"))
        color = "#22c7b7" if cl >= op else "#fb6269"
        d.line((xx, y(hi), xx, y(lo)), fill=color, width=2)
        upper, lower = sorted((y(op), y(cl)))
        d.rectangle((xx - body_width / 2, upper, xx + body_width / 2, max(upper + 2, lower)), fill=color)

    sx, sy = x(signal_time), y(signal_price)
    ex, ey = x(entry_time), y(entry_price)
    d.line((sx, sy, ex, ey), fill="#0c1928", width=7)
    length = math.hypot(ex - sx, ey - sy)
    if length > 1:
        for offset in range(0, int(length), 14):
            start, stop = offset / length, min(1, (offset + 7) / length)
            d.line((sx + (ex - sx) * start, sy + (ey - sy) * start,
                    sx + (ex - sx) * stop, sy + (ey - sy) * stop), fill="#e0bf76", width=3)
    if mode == "close":
        exit_time = parse_time(trade["exitTime"])
        tx, ty = x(exit_time), y(exit_price)
        path_color = "#4bd0b0" if result >= 0 else "#f17e78"
        d.line((ex, ey, tx, ty), fill="#0c1928", width=8)
        d.line((ex, ey, tx, ty), fill=path_color, width=4)
        d.ellipse((tx - 8, ty - 8, tx + 8, ty + 8), fill=path_color, outline="#0c1928", width=3)
        label = f"{str(trade['exitReason']).upper()} {result:+.1f}p"
        lx = tx + 12 if tx < right - 180 else tx - 12
        anchor = "lm" if lx > tx else "rm"
        ly = max(top + 16, min(bottom - 16, ty - 18))
        d.text((lx, ly), label, anchor=anchor, font=font(18, True), fill=path_color,
               stroke_width=3, stroke_fill="#0c1928")
    badge(d, sx, sy, "A", "#e0bf76")
    badge(d, ex, ey, "L" if side == "LONG" else "S", "#57d6d9" if side == "LONG" else "#d56bea")

    label_every = max(4, math.ceil(slots / 12))
    for index in range(0, slots, label_every):
        timestamp = first_time.timestamp() + index * 900
        moment = datetime.fromtimestamp(timestamp, tz=first_time.tzinfo)
        xx = x(moment)
        if xx <= right:
            d.text((xx, bottom + 18), moment.astimezone(NY).strftime("%m/%d %H:%M"),
                   anchor="mt", font=font(14), fill="#99aec2")
    d.text((left, 674), f"OTE {fmt(low_zone)}–{fmt(high_zone)}  ·  70.5% {fmt(entry_level)}",
           font=medium, fill="#e9bc65")
    d.text((left, 711),
           f"A arm {signal_time.astimezone(NY):%m/%d %H:%M}  ·  {side[0]} entry {entry_time.astimezone(NY):%m/%d %H:%M} at {fmt(entry_price)}",
           font=small, fill="#a2b8ca")
    if mode == "close":
        d.text((right, 711), f"Exit {exit_time.astimezone(NY):%m/%d %H:%M} at {fmt(exit_price)}",
               anchor="ra", font=small, fill="#a2b8ca")
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(destination, format="PNG", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: render-slack-trade-chart.py trade.json chart.png")
    main(sys.argv[1], sys.argv[2])
