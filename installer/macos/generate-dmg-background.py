#!/usr/bin/env python3
"""Generates the HelpHer macOS DMG background at 2× resolution (1320×800 px).

Window layout (1× points, 660×400 window):
  HelpHer.app  centre: (165, 195)
  Applications centre: (495, 195)
  Icon size: 128 pt
"""
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1320, 800

TOP = (247, 244, 250)   # #F7F4FA  — near-white lavender
BOT = (225, 210, 240)   # #E1D2F0  — soft purple

img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)

# Vertical gradient
for y in range(H):
    t = y / (H - 1)
    color = tuple(int(TOP[i] + (BOT[i] - TOP[i]) * t) for i in range(3))
    draw.line([(0, y), (W - 1, y)], fill=color)

# ── Arrow between icon positions ─────────────────────────────────────────────
# 1× centres scaled to 2×: HelpHer.app→(330,390)  Applications→(990,390)
ARROW = (107, 79, 124)
APP_CX, APP_CY = 330, 390
APS_CX = 990

ICON_HALF = 128
GAP = 24
x0 = APP_CX + ICON_HALF + GAP
x1 = APS_CX - ICON_HALF - GAP
mid_y = APP_CY

draw.line([(x0, mid_y), (x1, mid_y)], fill=ARROW, width=7)
head = 26
for i in range(head):
    draw.line(
        [(x1 - i, mid_y - i), (x1 - i, mid_y + i)],
        fill=ARROW, width=3,
    )

# ── HelpHer wordmark ──────────────────────────────────────────────────────────
BRAND_COLOR = (107, 79, 124)
font_title = None
for path, idx in [
    ("/System/Library/Fonts/Helvetica.ttc", 1),
    ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
    ("/System/Library/Fonts/Arial.ttf", 0),
]:
    try:
        font_title = ImageFont.truetype(path, 96, index=idx)
        break
    except Exception:
        pass

if font_title:
    bbox = draw.textbbox((0, 0), "HelpHer", font=font_title)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, 80), "HelpHer", fill=BRAND_COLOR, font=font_title)

# ── Caption text ──────────────────────────────────────────────────────────────
TEXT = "Drag to Applications to install"
TEXT_COLOR = (154, 116, 174)
TEXT_Y = H - 88

font_caption = None
for path in [
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Arial.ttf",
]:
    try:
        font_caption = ImageFont.truetype(path, 28)
        break
    except Exception:
        pass

if font_caption:
    bbox = draw.textbbox((0, 0), TEXT, font=font_caption)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, TEXT_Y), TEXT, fill=TEXT_COLOR, font=font_caption)
else:
    draw.text((W // 2 - 130, TEXT_Y), TEXT, fill=TEXT_COLOR)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dmg-background.png")
img.save(out, "PNG")
print(f"Saved {out}  ({W}×{H})")
