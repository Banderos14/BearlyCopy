#!/usr/bin/env python3
"""Wraps the raw README renders (see macos/Tests/.../ReadmeVisualsTests.swift)
in a dark frame: removes the light-grey test background around the island,
adds a soft shadow and a caption.

  PROMPT_RELAY_README_SHOTS=/tmp/shots swift test --filter Phase6VisualTests/testWriteReadmeVisuals
  python3 scripts/make-readme-images.py /tmp/shots docs/images/readme
"""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

src, out = sys.argv[1], sys.argv[2]
CAPTIONS = {
    "peek": "Quick Peek — hover the notch",
    "details": "Details — task, answer, attachments",
    "context-preview": "Copy with Context — every claim labelled",
    "attachment": "Attachments — files the agent produced",
}

def wrap(name, title, pad=80):
    im = Image.open(f"{src}/{name}.png").convert("RGB")
    w, h = im.size
    flood = im.copy()
    for pt in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (0, h // 2), (w - 1, h // 2), (w // 2, h - 1), (w // 2, 0)]:
        px = flood.getpixel(pt)
        if all(abs(c - 219) < 14 for c in px):
            ImageDraw.floodfill(flood, pt, (255, 0, 255), thresh=22)
    fl = flood.load()
    alpha = Image.new("L", (w, h), 255)
    ap = alpha.load()
    for y in range(h):
        for x in range(w):
            if fl[x, y] == (255, 0, 255):
                ap[x, y] = 0
    alpha = alpha.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
    im = im.convert("RGBA")
    im.putalpha(alpha)
    W, H = w + pad * 2, h + pad * 2 + 90
    canvas = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(canvas)
    top, bot = (52, 43, 38), (26, 22, 20)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh = Image.new("RGBA", im.size, (0, 0, 0, 200))
    sh.putalpha(alpha)
    shadow.paste(sh, (pad, pad + 26))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.alpha_composite(im, (pad, pad))
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 34)
    ImageDraw.Draw(canvas).text((W // 2, H - pad // 2 - 8), title, fill=(224, 178, 120, 255), font=font, anchor="mm")
    canvas.convert("RGB").save(f"{out}/{name}.png", optimize=True)

for n, t in CAPTIONS.items():
    wrap(n, t)
