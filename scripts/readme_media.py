"""Composes the README pictures from panel frames rendered by the test suite.

Usage: readme_media.py <frames directory> <output directory> [settings render]. Needs Pillow.
The frames are the panel's own drawing with sample readings on a transparent
background; this script puts them on a stand-in wallpaper behind a frosted pane,
which is what the window's glass material does on a real desktop.
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

frames, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
RADIUS = 28  # the panel's 14 pt corner at 2x


def wallpaper(width, height):
    small = Image.new("RGB", (width // 8, height // 8))
    pixels = small.load()
    lights = [((0.18, 0.2), (86, 72, 190), 0.75), ((0.85, 0.85), (190, 80, 120), 0.7), ((0.8, 0.1), (40, 120, 170), 0.55)]
    for y in range(small.height):
        for x in range(small.width):
            u, v = x / small.width, y / small.height
            color = [22 + 10 * v, 24 + 8 * v, 44 + 14 * v]
            for (cx, cy), tint, reach in lights:
                glow = max(0.0, 1 - math.hypot(u - cx, (v - cy) * height / width) / reach) ** 2
                color = [c + (t - c) * glow * 0.8 for c, t in zip(color, tint)]
            pixels[x, y] = tuple(int(c) for c in color)
    return small.resize((width, height), Image.BICUBIC).filter(ImageFilter.GaussianBlur(12))


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def place(canvas, panel, x, y):
    """Draws `panel` on `canvas` at (x, y) as a frosted pane with a soft shadow."""
    width, height = panel.size
    radius = min(RADIUS, height // 2)
    mask = rounded_mask((width, height), radius)
    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(mask.point(lambda value: value * 0.55), (x, y + 18))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(26)))
    box = (x, y, x + width, y + height)
    glass = canvas.crop(box).filter(ImageFilter.GaussianBlur(40))
    glass = Image.blend(glass, Image.new("RGB", glass.size, (26, 28, 36)), 0.66)
    glass.paste(panel, (0, 0), panel)
    canvas.paste(glass, (x, y), mask)
    rim = Image.new("L", (width, height), 0)
    ImageDraw.Draw(rim).rounded_rectangle([0, 0, width - 1, height - 1], radius=radius, outline=44, width=2)
    canvas.paste(Image.new("RGB", (width, height), (255, 255, 255)), (x, y), rim)


def frame(size, index=0):
    return Image.open(frames / f"{size}-{index:03d}.png").convert("RGBA")


# 1. The same panel at six sizes.
canvas = wallpaper(2400, 1400)
for size, x, y in [("300x420", 110, 110), ("660x230", 820, 110), ("480x260", 820, 674), ("270x150", 1830, 674), ("96x32", 1830, 1020), ("400x30", 110, 1250)]:
    place(canvas, frame(size), x, y)
canvas.save(out / "sizes.png", optimize=True)

# 2. A large window: more content, not larger type.
panel = frame("1049x500")
canvas = wallpaper(panel.width + 240, panel.height + 240)
place(canvas, panel, 120, 110)
canvas.save(out / "large.png", optimize=True)

# 3. The settings: the block as a right-click brings it up, and with "More" open.
if len(sys.argv) > 3:
    render = Path(sys.argv[3])
    closed = Image.open(render / "control-en-closed.png").convert("RGBA")
    opened = Image.open(render / "control-en-open.png").convert("RGBA")
    gap, edge = 90, 110
    canvas = wallpaper(closed.width + opened.width + gap + edge * 2, opened.height + edge * 2)
    RADIUS = 36  # the block's 18 pt corner at 2x
    place(canvas, closed, edge, edge)
    place(canvas, opened, edge + closed.width + gap, edge)
    canvas.save(out / "settings.png", optimize=True)

# 4. The panel through a few seconds, when the frames directory holds a loop.
loop = sorted(frames.glob("660x230-*.png"))
if len(loop) > 1:
    first = Image.open(loop[0])
    base = wallpaper(first.width + 200, first.height + 200)
    shots = []
    for path in loop:
        shot = base.copy()
        place(shot, Image.open(path).convert("RGBA"), 100, 90)
        shots.append(shot.resize((shot.width // 2, shot.height // 2), Image.LANCZOS))
    palette = shots[0].quantize(colors=255, method=Image.MEDIANCUT, dither=Image.NONE)
    stills = [shot.quantize(palette=palette, dither=Image.NONE) for shot in shots]
    stills[0].save(out / "live.gif", save_all=True, append_images=stills[1:], duration=66, loop=0, optimize=False)
