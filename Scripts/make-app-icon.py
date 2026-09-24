#!/usr/bin/env python3
"""Builds Packaging/AppIcon.icns from Packaging/AppIcon-source.png.

The source is the author's 1024-point square from Paper ("Pairtask", page 4,
"Icon"). macOS draws an application's icon on a grid: a rounded square 824
points wide in the middle of a 1024 canvas, with a soft shadow under it, so a
square filling the canvas looks larger and sharper than everything beside it
in the Dock. This puts the art on that grid, then asks iconutil for the .icns.

Run it again only when the source changes; the .icns is committed.
"""
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "Packaging", "AppIcon-source.png")
OUTPUT = os.path.join(ROOT, "Packaging", "AppIcon.icns")

CANVAS = 1024
SQUARE = 824
RADIUS = 185  # the grid's corner, 22.5% of the square
SCALE = 4     # drawn larger and reduced, for smooth corners


def master() -> Image.Image:
    art = Image.open(SOURCE).convert("RGBA").resize((SQUARE * SCALE, SQUARE * SCALE), Image.LANCZOS)
    mask = Image.new("L", art.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, art.size[0] - 1, art.size[1] - 1], radius=RADIUS * SCALE, fill=255
    )
    art.putalpha(mask)
    art = art.resize((SQUARE, SQUARE), Image.LANCZOS)

    offset = (CANVAS - SQUARE) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shape = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(shape).rounded_rectangle(
        [offset, offset + 10, offset + SQUARE - 1, offset + SQUARE + 9], radius=RADIUS, fill=77
    )
    shadow.putalpha(shape.filter(ImageFilter.GaussianBlur(10)))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(art, (offset, offset))
    return canvas


def main() -> None:
    icon = master()
    work = tempfile.mkdtemp()
    iconset = os.path.join(work, "AppIcon.iconset")
    os.makedirs(iconset)
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            pixels = points * factor
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            icon.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUTPUT], check=True)
    shutil.rmtree(work)
    print(OUTPUT)


if __name__ == "__main__":
    main()
