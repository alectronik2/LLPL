#!/usr/bin/env python3
"""Converts an RGBA cursor image into the raw sprite format
kern/mouse.llpl loads from the initrd.

The source is cropped to its opaque bounding box (trimming transparent
padding, since that box's top-left corner becomes the cursor's hotspot -
the point that tracks the actual mouse position) and scaled so its longer
side matches --size, preserving aspect ratio.

Output:
  - a 16-byte header: magic (u32 LE), width (u32 LE), height (u32 LE),
    reserved (u32 LE, always 0)
  - width*height pixels, each a u32 LE value packed as 0xAARRGGBB (alpha
    in the top byte) - kern/mouse.llpl blend_pixel()s each one against
    whatever is already on screen, so soft/anti-aliased edges (and this
    cursor's drop shadow) composite correctly over any background,
    including a photo wallpaper.

Usage: make_cursor.py <source-image> <output.raw> [--size N]
"""
import argparse
import struct
import sys

MAGIC = 0x53525543  # 'CURS' as a little-endian u32


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--size", type=int, default=32, help="longer side, in pixels (default 32)")
    args = ap.parse_args()

    from PIL import Image

    im = Image.open(args.source).convert("RGBA")
    bbox = im.getbbox()
    if bbox is not None:
        im = im.crop(bbox)

    src_w, src_h = im.size
    scale = args.size / max(src_w, src_h)
    width = max(1, round(src_w * scale))
    height = max(1, round(src_h * scale))
    im = im.resize((width, height), Image.LANCZOS)

    pixels = im.load()
    with open(args.output, "wb") as f:
        f.write(struct.pack("<IIII", MAGIC, width, height, 0))
        row = bytearray(width * 4)
        for y in range(height):
            for x in range(width):
                r, g, b, a = pixels[x, y]
                off = x * 4
                row[off] = b
                row[off + 1] = g
                row[off + 2] = r
                row[off + 3] = a
            f.write(row)

    print(f"wrote {args.output}: {width}x{height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
