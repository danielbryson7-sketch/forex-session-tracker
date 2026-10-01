#!/usr/bin/env python3
"""Render one end-of-day OTE distance and captured-pip bar per traded pair."""

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def font(size, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    path = Path("/usr/share/fonts/truetype/dejavu") / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def main(source, destination):
    report = json.loads(Path(source).read_text(encoding="utf-8"))
    rows = report["rows"]
    width = 1200
    row_height = 72
    height = max(340, 194 + row_height * len(rows) + 86)
    image = Image.new("RGB", (width, height), "#081725")
    draw = ImageDraw.Draw(image)
    title, body, small = font(29, True), font(20), font(16)
    draw.text((48, 35), f"OTE DISTANCE / PIPS CAPTURED  ·  {report['date']}", font=title, fill="#f2f7fb")
    draw.text((48, 87), "Each row: pair's realized net pips ÷ distance from its OTE zone at the 17:00 NY close", font=small, fill="#a2b8ca")
    draw.text((48, 131), "PAIR", font=small, fill="#91a8bd")
    draw.text((275, 131), "PIPS CAPTURED / DISTANCE", font=small, fill="#91a8bd")
    draw.text((1138, 131), "STATUS", anchor="ra", font=small, fill="#91a8bd")
    draw.line((48, 161, 1152, 161), fill="#31506a", width=2)

    if not rows:
        draw.text((48, 209), "No live V2 trades were taken in this trading day.", font=body, fill="#a2b8ca")
    for index, row in enumerate(rows):
        y = 185 + index * row_height
        if index % 2 == 0:
            draw.rounded_rectangle((37, y - 9, 1162, y + 54), radius=8, fill="#10263a")
        pair = row["pair"]
        net = float(row["netPips"])
        distance = row["distancePips"]
        draw.text((50, y + 3), pair, font=font(21, True), fill="#f2f7fb")
        draw.text((176, y + 6), f"{row['closed']}/{row['trades']} closed", font=small, fill="#91a8bd")
        track_left, track_right = 275, 760
        track_top, track_bottom = y + 5, y + 28
        draw.rounded_rectangle((track_left, track_top, track_right, track_bottom), radius=10, fill="#294052")
        if distance is not None and float(distance) > 0:
            fraction = abs(net) / float(distance)
            fill_width = max(0, min(track_right - track_left, int((track_right - track_left) * fraction)))
            if fill_width:
                color = "#37c7b2" if net >= 0 else "#fb6269"
                draw.rounded_rectangle((track_left, track_top, track_left + fill_width, track_bottom), radius=10, fill=color)
            percentage = f"{net / float(distance) * 100:+.0f}%"
            measure = f"{net:+.1f} / {float(distance):.1f} pips ({percentage})"
        elif distance is None:
            measure = f"{net:+.1f} pips / no completed 17:00 close"
        else:
            measure = f"{net:+.1f} pips / 0.0 away (inside OTE)"
        draw.text((275, y + 35), measure, font=small, fill="#f2f7fb")
        status = str(row["side"]).upper()
        status_color = "#e9bc65" if status == "INSIDE" else "#91a8bd"
        draw.text((1138, y + 5), status, anchor="ra", font=font(18, True), fill=status_color)
        if distance is not None and float(distance) > 0 and abs(net) > float(distance):
            draw.text((1138, y + 34), "bar capped at 100%", anchor="ra", font=small, fill="#91a8bd")

    footer_y = height - 62
    draw.line((48, footer_y - 12, 1152, footer_y - 12), fill="#31506a", width=1)
    draw.text((48, footer_y), "Pips are V2 paper net results. Open trades do not fill the bar.", font=small, fill="#a2b8ca")
    draw.text((48, footer_y + 23), "A result can exceed the final distance after multiple trades or an intraday reversal; the bar caps at 100%.", font=small, fill="#a2b8ca")
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format="PNG", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: render-daily-progress.py report.json chart.png")
    main(sys.argv[1], sys.argv[2])
