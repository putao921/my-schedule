# -*- coding: utf-8 -*-
"""Generate PWA icons from the avatar cut-out.

The source is pixel art, so upscaling uses NEAREST -- resampling would smear
the very grain that matches the app's pixel look.

maskable icons need a safe zone: Android may crop a circle around the centre,
so the art is inset to ~70% and floated on a solid brand background.
"""
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "shots", "avatar-girl-portrait.png")
OUT = os.path.join(ROOT, "web", "icons")

BG = (0xEF, 0xD7, 0xD4)      # light Backdrop token
BG_DEEP = (0xE9, 0xAE, 0xAE)  # light ChromeDeep token


def load():
    im = Image.open(SRC).convert("RGBA")
    # Trim fully transparent margins so the art fills the canvas.
    return im.crop(im.getbbox())


def plain(size):
    art = load()
    canvas = Image.new("RGBA", (size, size), BG + (255,))
    # Fit inside ~86% of the canvas, centred.
    box = int(size * 0.86)
    art = art.resize((box, box), Image.NEAREST)
    off = (size - box) // 2
    canvas.alpha_composite(art, (off, off))
    return canvas


def maskable(size):
    """Safe zone: art at 70%, on a full-bleed brand background."""
    art = load()
    canvas = Image.new("RGBA", (size, size), BG_DEEP + (255,))
    box = int(size * 0.70)
    art = art.resize((box, box), Image.NEAREST)
    off = (size - box) // 2
    canvas.alpha_composite(art, (off, off))
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)

    for size in (192, 512):
        p = os.path.join(OUT, "icon-%d.png" % size)
        plain(size).save(p)
        print("icon-%d.png (%d bytes)" % (size, os.path.getsize(p)))

    p = os.path.join(OUT, "icon-maskable.png")
    maskable(512).save(p)
    print("icon-maskable.png (%d bytes)" % os.path.getsize(p))

    # Favicon-ish small tile, handy for browser tabs.
    p = os.path.join(OUT, "icon-32.png")
    plain(32).save(p)
    print("icon-32.png")


if __name__ == "__main__":
    main()
