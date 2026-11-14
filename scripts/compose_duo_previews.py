"""Cut iPhone Duo App Store app previews from simulator recordings.

App Store Connect accepts only 886x1920 / 1920x886 previews for iPhone Duo, which match
neither Duo display. Instead of stretching the footage, each scene places the undistorted
recording on the promo gradient with its headline, matching PromoScreenshots/iPhoneDuo.

Usage: python compose_duo_previews.py <rawdir> <outdir>
Expects rawdir to hold the recordings named in SCENES (simctl io recordVideo output).
Requires Pillow and ffmpeg.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAW = Path(sys.argv[1])
OUT = Path(sys.argv[2])
WORK = OUT / "work"
WORK.mkdir(parents=True, exist_ok=True)

FPS = 30
FADE = 0.4
FONT = "/System/Library/Fonts/SFNSMono.ttf"
INK = (31, 41, 46)
TL, TR, BL, BR = (243, 209, 255), (194, 156, 255), (194, 160, 232), (254, 230, 190)
MID = (186, 151, 238)

# (headline, source clip, start seconds, duration of output, playback speed)
SCENES = {
    "inner": [
        ("CHAT", "inner-nav.mov", 3.2, 10.0, 2.4),
        ("APPROVE FROM ANYWHERE", "inner-permission.mov", 4.1, 4.5, 1.0),
        ("SESSION REVIEW", "inner-nav.mov", 36.8, 4.5, 1.0),
        ("PROJECT SWITCHER", "inner-nav.mov", 44.8, 4.5, 1.0),
        ("RICH DIFF SUPPORT", "inner-diff.mov", 3.9, 5.0, 1.0),
    ],
    "outer": [
        ("CHAT", "outer-chat.mov", 3.2, 10.0, 2.4),
        ("APPROVE FROM ANYWHERE", "outer-permission.mov", 4.1, 4.5, 1.0),
        ("SESSION REVIEW", "outer-review.mov", 2.6, 4.5, 1.0),
        ("PROJECT SWITCHER", "outer-workspace.mov", 2.6, 4.5, 1.0),
        ("RICH DIFF SUPPORT", "outer-diff.mov", 3.9, 5.0, 1.0),
    ],
}
CANVAS = {"inner": (1920, 886), "outer": (886, 1920)}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h):
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            u, v = x / 63, y / 63
            c = lerp(lerp(TL, TR, u), lerp(BL, BR, u), v)
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


def wrap(draw, text, font, max_w):
    lines, line = [], ""
    for word in text.split():
        test = f"{line} {word}".strip()
        if line and draw.textlength(test, font=font) > max_w:
            lines.append(line)
            line = word
        else:
            line = test
    return lines + [line]


def layout(kind, src_size):
    """Returns the screen rectangle (x, y, w, h) and the headline box for a canvas."""
    W, H = CANVAS[kind]
    sw, sh = src_size
    if kind == "inner":  # landscape: headline column on the left, screen on the right
        h = int(H * 0.86) // 2 * 2
        w = int(h * sw / sh) // 2 * 2
        x, y = W - w - int(H * 0.07), (H - h) // 2
        text_box = (int(H * 0.07), 0, x - int(H * 0.07) * 2, H)
    else:  # portrait: headline on top, screen below
        w = int(W * 0.84) // 2 * 2
        h = int(w * sh / sw) // 2 * 2
        x, y = (W - w) // 2, H - h - int(W * 0.10)
        text_box = (int(W * 0.06), 0, W - int(W * 0.12), y)
    return (x, y, w, h), text_box


def background(kind, title, screen, text_box, path):
    W, H = CANVAS[kind]
    canvas = gradient(W, H).convert("RGBA")
    x, y, w, h = screen
    radius = int(min(w, h) * 0.06)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 18, x + w, y + h + 18], radius, fill=(60, 30, 110, 90))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(28)))

    d = ImageDraw.Draw(canvas)
    tx, ty, tw, th = text_box
    font = bold_font(int(W * 0.062) if kind == "inner" else int(W * 0.085))
    lines = wrap(d, title, font, tw)
    asc, desc = font.getmetrics()
    lh = int((asc + desc) * 1.08)
    block = lh * len(lines)
    top = ty + (th - block) // 2
    for i, line in enumerate(lines):
        lw = d.textlength(line, font=font)
        lx = tx if kind == "inner" else tx + (tw - lw) / 2
        d.text((lx, top + i * lh), line, font=font, fill=INK)
    canvas.convert("RGB").save(path)

    # Corner mask: gradient pixels outside the rounded screen, transparent inside.
    mask = Image.new("L", canvas.size, 255)
    ImageDraw.Draw(mask).rounded_rectangle([x, y, x + w - 1, y + h - 1], radius, fill=0)
    corners = canvas.copy()
    corners.putalpha(mask)
    corners.save(path.with_name(path.stem + "-corners.png"))


def probe_size(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height:stream_side_data=rotation", "-of", "default=nw=1", path], text=True)
    vals = dict(l.split("=") for l in out.split() if "=" in l)
    w, h = int(vals["width"]), int(vals["height"])
    return (h, w) if abs(int(float(vals.get("rotation", 0)))) == 90 else (w, h)


def render_scene(kind, idx, title, clip, start, dur, speed):
    src = RAW / clip
    screen, text_box = layout(kind, probe_size(src))
    bg = WORK / f"{kind}-{idx}-bg.png"
    background(kind, title, screen, text_box, bg)
    x, y, w, h = screen
    out = WORK / f"{kind}-{idx}.mp4"
    graph = (f"[1:v]setpts=(PTS-STARTPTS)/{speed},fps={FPS},scale={w}:{h}:flags=lanczos,"
             f"tpad=stop_mode=clone:stop_duration={dur}[v];"
             f"[0:v][v]overlay={x}:{y}[o];[o][2:v]overlay=0:0,format=yuv420p")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-framerate", str(FPS), "-i", bg,
                    "-ss", str(start), "-i", src,
                    "-loop", "1", "-framerate", str(FPS), "-i", bg.with_name(bg.stem + "-corners.png"),
                    "-filter_complex", graph, "-t", str(dur), "-r", str(FPS),
                    "-c:v", "libx264", "-crf", "12", "-preset", "slow", out], check=True)
    return out, dur


def assemble(kind, parts):
    inputs, graph, offset, last = [], [], 0.0, "0:v"
    for i, (path, dur) in enumerate(parts):
        inputs += ["-i", path]
        if i == 0:
            offset = dur - FADE
            continue
        label = f"x{i}"
        graph.append(f"[{last}][{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.3f}[{label}]")
        last, offset = label, offset + dur - FADE
    total = offset + FADE
    out = OUT / f"duo-{kind}-preview.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs,
                    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                    "-filter_complex", ";".join(graph), "-map", f"[{last}]", "-map", f"{len(parts)}:a",
                    "-t", f"{total:.3f}", "-r", str(FPS),
                    "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-pix_fmt", "yuv420p",
                    "-b:v", "11M", "-maxrate", "12M", "-bufsize", "24M",
                    "-c:a", "aac", "-b:a", "256k", "-ac", "2", "-movflags", "+faststart", out], check=True)
    print(f"{out.name}: {total:.1f}s")


kinds = sys.argv[3:] or list(SCENES)
for kind in kinds:
    parts = [render_scene(kind, i, *scene) for i, scene in enumerate(SCENES[kind], 1)
             if (RAW / scene[1]).exists()]
    assemble(kind, parts)
