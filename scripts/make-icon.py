#!/usr/bin/env python3
"""Draws the app icon and writes Resources/AppIcon.iconset (every size macOS asks for).

Needs Pillow (pip install pillow). scripts/build-app.sh turns the iconset into
AppIcon.icns with iconutil, so only rerun this when the artwork changes.

The artwork: a dark tile with a large orange Claude-style spark in the back, and a small
stack of dollar notes and a teal token-usage bar chart in front of it.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SS = 4                      # supersampling factor
N = 1024 * SS               # working canvas
BG_TOP, BG_BOTTOM = (30, 31, 34), (12, 12, 14)
TEAL = (45, 212, 191)
ORANGE = (217, 119, 87)
NOTE, NOTE_DARK, NOTE_INK = (52, 110, 82), (33, 74, 55), (150, 200, 170)

FONT_PATHS = [
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-ExtraBold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
]


def px(v):
    return int(round(v * SS))


def font(size):
    for path in FONT_PATHS:
        if os.path.exists(path):
            return ImageFont.truetype(path, px(size))
    return ImageFont.load_default()


def tile_mask():
    # Big Sur grid: 824pt body centred in the 1024 canvas, ~185pt corner radius.
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([px(100), px(100), px(924), px(924)], px(185), fill=255)
    return m


def background():
    grad = Image.new("RGB", (1, N))
    for y in range(N):
        t = y / (N - 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    return grad.resize((N, N)).convert("RGBA")


def note(w, h):
    img = Image.new("RGBA", (px(w), px(h)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, px(w) - 1, px(h) - 1], px(22), fill=NOTE)
    d.rounded_rectangle([px(18), px(18), px(w - 18), px(h - 18)], px(12), outline=NOTE_DARK, width=px(7))
    cx, cy, r = px(w / 2), px(h / 2), px(h * 0.30)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=NOTE_DARK)
    d.text((cx, cy + px(4)), "$", font=font(h * 0.42), fill=NOTE_INK, anchor="mm")
    for sx in (px(70), px(w - 70)):
        d.ellipse([sx - px(14), cy - px(14), sx + px(14), cy + px(14)], fill=NOTE_DARK)
    return img


def paste_rotated(canvas, img, angle, centre):
    rot = img.rotate(angle, resample=Image.BICUBIC, expand=True)
    shadow = Image.new("RGBA", rot.size, (0, 0, 0, 0))
    shadow.putalpha(rot.getchannel("A").point(lambda a: a * 0.55))
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(14)))
    x, y = centre[0] - rot.width // 2, centre[1] - rot.height // 2
    canvas.alpha_composite(shadow, (x + px(6), y + px(16)))
    canvas.alpha_composite(rot, (x, y))


def spark(canvas, cx, cy, r):
    # Chunky round-capped rays of uneven length, in the spirit of the Claude mark.
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    lengths = [1.0, 0.82, 0.94, 0.78, 1.0, 0.86, 0.92, 0.8, 0.97, 0.84]
    w = r * 0.2
    for i, k in enumerate(lengths):
        a = math.pi / 2 + i * 2 * math.pi / len(lengths)
        tip = (cx + (r * k - w / 2) * math.cos(a), cy - (r * k - w / 2) * math.sin(a))
        d.line([(cx, cy), tip], fill=ORANGE, width=int(w))
        d.ellipse([tip[0] - w / 2, tip[1] - w / 2, tip[0] + w / 2, tip[1] + w / 2], fill=ORANGE)
    d.ellipse([cx - r * 0.24, cy - r * 0.24, cx + r * 0.24, cy + r * 0.24], fill=ORANGE)
    canvas.alpha_composite(layer)


def bars(canvas):
    # Token usage per session: teal bars of uneven height, edged in the tile colour so they
    # stay distinct where they cross the spark.
    base, width, gap = 790, 42, 18
    heights = [110, 200, 150, 250]
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i, h in enumerate(heights):
        x0 = 565 + i * (width + gap)
        box = [px(x0), px(base - h), px(x0 + width), px(base)]
        d.rounded_rectangle([box[0] - px(8), box[1] - px(8), box[2] + px(8), box[3] + px(8)],
                            px(18), fill=BG_BOTTOM)
        d.rounded_rectangle(box, px(10), fill=TEAL)
    canvas.alpha_composite(layer)


def render():
    canvas = background()
    spark(canvas, px(512), px(490), px(300))
    for angle, (x, y) in ((16, (400, 690)), (7, (410, 720)), (-2, (420, 750))):
        paste_rotated(canvas, note(270, 140), angle, (px(x), px(y)))
    bars(canvas)

    mask = tile_mask()
    # A hairline highlight on the tile edge keeps it from melting into dark docks.
    edge = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([px(101), px(101), px(923), px(923)], px(184),
                                           outline=(255, 255, 255, 34), width=px(3))
    canvas.alpha_composite(edge)

    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile_shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile_shadow.putalpha(mask.point(lambda a: a * 0.45))
    out.alpha_composite(tile_shadow.filter(ImageFilter.GaussianBlur(px(18))), (0, px(12)))
    tile = canvas.copy()
    tile.putalpha(mask)
    out.alpha_composite(tile)
    return out.resize((1024, 1024), Image.LANCZOS)


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    iconset = os.path.join(root, "Resources", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    master = render()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            master.resize((size * scale, size * scale), Image.LANCZOS).save(os.path.join(iconset, name))
    if len(sys.argv) > 1:
        master.save(sys.argv[1])
    print(f"wrote {iconset}")


if __name__ == "__main__":
    main()
