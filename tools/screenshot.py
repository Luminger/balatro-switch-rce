#!/usr/bin/env python3
"""Render docs/screenshot.png: the launcher's status screen after boot.

Drives the REAL console UI (src/bl/console.lua via src/bl/app.lua) with
stubbed love/resolve/sockets -- see tools/screenshot.lua -- captures its
draw calls, and rasterizes them with the bundled JetBrains Mono subset
at the same metrics LÖVE would use at 1280x720. The on-screen build id
and per-file hash manifest are computed from src/ and therefore match a
real build of the same tree.

Usage: python3 tools/screenshot.py [output.png]  (default docs/screenshot.png)
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
FONT = ROOT / "src" / "bl" / "assets" / "mono.ttf"
DRIVER = HERE / "screenshot.lua"

W, H = 1280, 720            # Switch handheld output the console targets
SCALE = 2                   # render supersampled for a crisp README image


def main() -> int:
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "screenshot.png"

    # The console picks its font size from the window height (bl/console.lua):
    # max(14, min(48, floor(h / 47))) -> 15 at 720p.
    size = max(14, min(48, H // 47))
    probe = ImageFont.truetype(FONT, size)
    cell = probe.getlength("0")
    for ch in "iMWl ":
        if probe.getlength(ch) != cell:
            raise SystemExit("bundled face is not monospaced?")
    ascent, descent = probe.getmetrics()
    glyph_h = ascent + descent

    with tempfile.NamedTemporaryFile("r", suffix=".ops", delete=False) as tf:
        ops_path = tf.name
    try:
        proc = subprocess.run(
            ["luajit", str(DRIVER), str(cell), str(glyph_h), ops_path],
            cwd=ROOT, capture_output=True, text=True, check=True)
        sys.stderr.write(proc.stderr)
        if "build " in proc.stderr:
            print(proc.stderr.strip())

        image = Image.new("RGB", (W * SCALE, H * SCALE))
        draw = ImageDraw.Draw(image)
        font = ImageFont.truetype(FONT, size * SCALE)

        for line in pathlib.Path(ops_path).read_text().splitlines():
            parts = line.split("\t")
            if parts[0] == "R":
                x, y, w, h = (int(v) for v in parts[1:5])
                fill = _rgb(parts[5])
                draw.rectangle((x * SCALE, y * SCALE,
                                (x + w) * SCALE - 1, (y + h) * SCALE - 1), fill=fill)
            elif parts[0] == "T":
                x, y = int(parts[1]), int(parts[2])
                draw.text((x * SCALE, y * SCALE), parts[4],
                         font=font, fill=_rgb(parts[3]))
            else:
                raise SystemExit(f"unknown op: {line!r}")

        out.parent.mkdir(parents=True, exist_ok=True)
        image.save(out)
        print(f"{out}: {image.size[0]}x{image.size[1]}")
        return 0
    finally:
        pathlib.Path(ops_path).unlink(missing_ok=True)


def _rgb(csv: str) -> tuple[int, int, int]:
    r, g, b = (float(v) for v in csv.split(",")[:3])
    return (round(r * 255), round(g * 255), round(b * 255))


if __name__ == "__main__":
    raise SystemExit(main())
