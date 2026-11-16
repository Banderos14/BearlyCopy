#!/usr/bin/env python3
"""Draws docs/images/readme/how-it-works.png (the README diagram)."""
import sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1] if len(sys.argv) > 1 else "docs/images/readme/how-it-works.png"
W, H = 2400, 760
img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
for y in range(H):
    t = y / H
    d.line([(0, y), (W, y)], fill=tuple(int(a * (1 - t) + b * t) for a, b in zip((52, 43, 38), (26, 22, 20))))
f_title = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 52)
f_body = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 36)
f_num = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 40)
steps = [
    ("Your agent", ["Claude Code or Codex", "does the work as usual"]),
    ("Prompt Relay", ["Keeps the final answer", "exactly as written, with the", "request, project and files"]),
    ("Copy", ["Copy Answer, or Copy with", "Context for a reviewer:", "every claim labelled"]),
    ("Paste anywhere", ["ChatGPT, another Claude", "chat, a teammate"]),
]
bw, bh, gap = 480, 500, 120
x0 = (W - (4 * bw + 3 * gap)) // 2
y0 = 140
accent = (217, 166, 107)
for i, (title, lines) in enumerate(steps):
    x = x0 + i * (bw + gap)
    hl = i == 1
    d.rounded_rectangle([x, y0, x + bw, y0 + bh], radius=36, fill=(58, 48, 42) if hl else (40, 34, 31),
                        outline=accent if hl else (86, 74, 66), width=5 if hl else 3)
    d.ellipse([x + 36, y0 + 36, x + 104, y0 + 104], fill=accent)
    d.text((x + 70, y0 + 70), str(i + 1), font=f_num, fill=(30, 24, 20), anchor="mm")
    d.text((x + 36, y0 + 150), title, font=f_title, fill=(255, 255, 255))
    for j, line in enumerate(lines):
        d.text((x + 36, y0 + 235 + j * 54), line, font=f_body, fill=(206, 196, 186))
    if i < 3:
        ax = x + bw + 16
        ay = y0 + bh // 2
        d.line([(ax, ay), (ax + gap - 40, ay)], fill=accent, width=8)
        d.polygon([(ax + gap - 40, ay - 22), (ax + gap - 4, ay), (ax + gap - 40, ay + 22)], fill=accent)
img.resize((W // 2, H // 2), Image.LANCZOS).save(out, optimize=True)
