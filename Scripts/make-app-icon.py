#!/usr/bin/env python3
"""Draws the iPhone app icon (1024 x 1024, opaque) in the colours of the Mneme ads.

Usage: python3 Scripts/make-app-icon.py [output.png]
Default output: iOS/Mneme/Assets.xcassets/AppIcon.appiconset/AppIcon.png. Needs Pillow.
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
TOP, BOTTOM = (20, 27, 52), (9, 13, 28)
AMBER, TEAL = (245, 184, 91), (94, 214, 190)


def mix(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "iOS/Mneme/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    scale = 2
    s = SIZE * scale
    image = Image.new("RGB", (s, s))
    draw = ImageDraw.Draw(image)
    for y in range(s):
        draw.line([(0, y), (s, y)], fill=mix(TOP, BOTTOM, y / s))

    # A soft glow behind the waveform.
    glow = Image.new("L", (s, s), 0)
    ImageDraw.Draw(glow).ellipse([s * 0.18, s * 0.28, s * 0.82, s * 0.72], fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.09))
    image = Image.composite(Image.new("RGB", (s, s), (56, 74, 150)), image, glow)
    draw = ImageDraw.Draw(image)

    # A waveform that fades from amber (the voice) into teal (the written transcript).
    bars = 13
    width = s * 0.62
    left = (s - width) / 2
    step = width / bars
    bar = step * 0.56
    for i in range(bars):
        t = i / (bars - 1)
        envelope = math.sin(math.pi * (0.08 + 0.84 * t))
        wobble = 0.55 + 0.45 * abs(math.sin(i * 1.7 + 0.4))
        height = s * 0.46 * envelope * wobble + bar
        x = left + i * step + (step - bar) / 2
        y0 = s / 2 - height / 2
        draw.rounded_rectangle([x, y0, x + bar, y0 + height], radius=bar / 2, fill=mix(AMBER, TEAL, t))

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    image.save(out, optimize=True)
    print(out)


if __name__ == "__main__":
    main()
