#!/usr/bin/env python3
"""Generate a placeholder Lumora app icon (a luminous orb on a dark squircle) → app/AppIcon.icns.
PLACEHOLDER ONLY — replace with real branding when it exists. Requires Pillow + macOS `iconutil`.
Usage: python3 app/make_icon.py
"""
import math, os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024


def squircle_mask(size, radius_frac=0.225):
    """A macOS-style rounded-rect (superellipse-ish) alpha mask."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = int(size * radius_frac)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m


def master():
    # Dark diagonal gradient backdrop (deep indigo -> near-black), drawn small then upscaled.
    g = Image.new("RGBA", (64, 64))
    top, bot = (44, 34, 86), (12, 11, 24)
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126
            g.putpixel((x, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    img = g.resize((S, S), Image.BILINEAR)

    # Soft glow halo behind the moon.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy, R = int(S * 0.52), int(S * 0.46), int(S * 0.30)
    for rad in range(int(R * 1.7), R, -3):
        t = (rad - R) / (R * 0.7)
        gd.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(150, 175, 255, int(60 * (1 - t))))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.02)))

    # Crescent moon = a bright disc minus an offset disc (Lumora = light / moonlight).
    moon = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(moon)
    md.ellipse([cx - R, cy - R, cx + R, cy + R], fill=255)               # full disc
    off = int(R * 0.42)
    md.ellipse([cx - R + off, cy - R - int(R * 0.12), cx + R + off, cy + R - int(R * 0.12)], fill=0)  # bite out
    crescent = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Vertical shimmer in the crescent: pale blue at top -> warm white at the bottom tip.
    col = Image.new("RGBA", (1, S))
    c0, c1 = (205, 220, 255), (250, 246, 235)
    for y in range(S):
        t = y / (S - 1)
        col.putpixel((0, y), tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)) + (255,))
    crescent.paste(col.resize((S, S)), (0, 0), moon)
    img.alpha_composite(crescent)

    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), squircle_mask(S))
    return out


def main():
    base = master()
    with tempfile.TemporaryDirectory() as d:
        iconset = os.path.join(d, "Lumora.iconset")
        os.makedirs(iconset)
        for px, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                         (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]:
            base.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{name}.png"))
        out = os.path.join(HERE, "AppIcon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
        print("wrote", out)


if __name__ == "__main__":
    main()
