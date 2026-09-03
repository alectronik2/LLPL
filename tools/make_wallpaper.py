#!/usr/bin/env python3
"""Converts an image into the raw wallpaper format the limine_baremetal_demo
kernel loads from the initrd (see kernel.llpl's draw_wallpaper()).

The source image is scaled+cropped ("cover", like CSS background-size) to
exactly fill the target resolution, then written out as:
  - a 12-byte header: magic (u32 LE), width (u32 LE), height (u32 LE)
  - width*height pixels, each a u32 LE value packed as 0x00RRGGBB - the
    same format Terminal.put_pixel/blit_rect use, so the kernel can blit
    it straight into the framebuffer with no runtime decoding.

Usage: make_wallpaper.py <source-image> <output.raw> [width] [height]
Defaults to 1024x768, matching this demo's QEMU boot resolution.
"""
import struct
import sys

MAGIC = 0x504C4157  # 'WALP' as a little-endian u32


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <source-image> <output.raw> [width] [height]", file=sys.stderr)
        return 1

    src_path = sys.argv[1]
    out_path = sys.argv[2]
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 768

    from PIL import Image

    im = Image.open(src_path).convert("RGB")
    src_w, src_h = im.size

    scale = max(width / src_w, height / src_h)
    scaled_w = max(width, round(src_w * scale))
    scaled_h = max(height, round(src_h * scale))
    im = im.resize((scaled_w, scaled_h), Image.LANCZOS)

    left = (scaled_w - width) // 2
    top = (scaled_h - height) // 2
    im = im.crop((left, top, left + width, top + height))

    pixels = im.load()
    with open(out_path, "wb") as f:
        f.write(struct.pack("<III", MAGIC, width, height))
        row = bytearray(width * 4)
        for y in range(height):
            for x in range(width):
                r, g, b = pixels[x, y]
                off = x * 4
                row[off] = b
                row[off + 1] = g
                row[off + 2] = r
                row[off + 3] = 0
            f.write(row)

    print(f"wrote {out_path}: {width}x{height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
