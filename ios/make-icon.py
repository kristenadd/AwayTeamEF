#!/usr/bin/env python3
"""Make ios/AppIcon-1024.png, the iPhone / iPad app icon, from macos/icon/source.webp.

iOS wants a full-bleed, opaque square: it rounds the corners itself and fills
any transparency with white (the white border the macOS icon got on iOS).
So this crops the source to the artwork's rounded body, scales it to 1024 and
paints the light corners outside the body dark navy. iOS's corner mask is
larger than the artwork's own corner radius, so those corners are never seen.

    python3 ios/make-icon.py      (needs Pillow; run once, commit the png)
"""
import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "macos", "icon", "source.webp")
DST = os.path.join(HERE, "AppIcon-1024.png")
SIZE = 1024
INSET = 6          # source pixels trimmed inside the body's outer edge (its light rim)


def dark(p):
    return sum(p[:3]) < 300


def main():
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    px = im.load()
    mx, my = w // 2, h // 2
    left = next(x for x in range(w) if dark(px[x, my]))
    right = next(x for x in range(w - 1, -1, -1) if dark(px[x, my]))
    top = next(y for y in range(h) if dark(px[mx, y]))
    bottom = next(y for y in range(h - 1, -1, -1) if dark(px[mx, y]))
    box = (left + INSET, top + INSET, right - INSET + 1, bottom - INSET + 1)
    body = im.crop(box).resize((SIZE, SIZE), Image.LANCZOS)

    # flood the light corner pixels (connected to the border) with the body's edge colour
    bp = body.load()
    fill = bp[SIZE // 2, 4]
    seen = set()
    queue = deque((x, y) for x in (0, SIZE - 1) for y in (0, SIZE - 1))
    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or not (0 <= x < SIZE and 0 <= y < SIZE):
            continue
        seen.add((x, y))
        if dark(bp[x, y]):
            continue
        bp[x, y] = fill
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    body.save(DST)
    print(f"{DST}: body {box} of {w}x{h}, {len(seen)} corner pixels filled")


if __name__ == "__main__":
    main()
