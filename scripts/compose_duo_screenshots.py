"""Compose iPhone Duo App Store screenshots in the existing OpenLens promo style."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

RAW = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)

SHOTS = [
    ("1-chat", "CHAT"),
    ("2-permission", "APPROVE FROM ANYWHERE"),
    ("3-review", "SESSION REVIEW"),
    ("4-workspace", "PROJECT SWITCHER"),
    ("5-diff", "RICH DIFF SUPPORT"),
]
RAW_NAME = {"1-chat": "chat", "2-permission": "permission", "3-review": "review",
            "4-workspace": "workspace", "5-diff": "diff"}

FONT = "/System/Library/Fonts/SFNSMono.ttf"
INK = (31, 41, 46)
# Corner colors sampled from PromoScreenshots/0x0ss-*.png
TL, TR, BL, BR = (243, 209, 255), (194, 156, 255), (194, 160, 232), (254, 230, 190)
MID = (186, 151, 238)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h):
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            u, v = x / 63, y / 63
            top, bottom = lerp(TL, TR, u), lerp(BL, BR, u)
            c = lerp(top, bottom, v)
            # pull the middle toward lavender like the existing set
            d = 1 - min(1, ((u - .5) ** 2 + (v - .5) ** 2) ** .5 * 1.6)
            px[x, y] = lerp(c, MID, max(0, d) * .55)
    return small.resize((w, h), Image.BICUBIC)


def bold_font(size):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name("Bold")
    except Exception:
        pass
    return f


def device(shot, bezel, radius):
    w, h = shot.size
    frame = Image.new("RGBA", (w + 2 * bezel, h + 2 * bezel), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle([0, 0, frame.width - 1, frame.height - 1], radius + bezel, fill=(28, 28, 30, 255))
    d.rounded_rectangle([3, 3, frame.width - 4, frame.height - 4], radius + bezel - 3, outline=(90, 90, 96, 255), width=3)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    return frame


def compose(raw_path, title, size, out_path):
    W, H = size
    canvas = gradient(W, H).convert("RGBA")
    landscape = W > H
    font = bold_font(int((H if landscape else W) * (0.075 if landscape else 0.072)))
    d = ImageDraw.Draw(canvas)
    head_top = int(H * 0.055)
    tb = d.textbbox((0, 0), title, font=font)
    d.text(((W - (tb[2] - tb[0])) / 2 - tb[0], head_top - tb[1]), title, font=font, fill=INK)
    head_bottom = head_top + (tb[3] - tb[1])

    shot = Image.open(raw_path).convert("RGB")
    gap = int(H * 0.05)
    avail_h = (H - head_bottom - gap - int(H * 0.05)) / 1.044  # leave room for the bezel and a bottom margin
    scale = min((W * 0.80) / shot.width, avail_h / shot.height)
    sw, sh = int(shot.width * scale), int(shot.height * scale)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    bezel = int(sw * 0.022)
    dev = device(shot, bezel, int(sw * 0.06))

    x = (W - dev.width) // 2
    y = head_bottom + gap
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x + 10, y + 30, x + dev.width - 10, y + dev.height + 30],
                                             int(sw * 0.08), fill=(60, 30, 110, 90))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.alpha_composite(dev, (x, y))
    canvas.convert("RGB").save(out_path, optimize=True)


for prefix, size in (("outer", (1398, 2034)), ("inner", (2853, 2007))):
    for key, title in SHOTS:
        raw = RAW / f"{prefix}-{RAW_NAME[key]}.png"
        if raw.exists():
            out = OUT / f"duo-{prefix}-{key}.png"
            compose(raw, title, size, out)
            print(out.name)
