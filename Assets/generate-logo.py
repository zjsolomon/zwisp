#!/usr/bin/env python3
"""Generate the zwisp pixel-art logo: a microphone with a bold Z on its head.

Designed on a 32x32 pixel grid (true pixel-art), then scaled up with
nearest-neighbour so the pixels stay crisp at every size. Pure stdlib (zlib)
so it runs anywhere without Pillow/ImageMagick.
"""
import struct, zlib, os, sys

N = 32  # base grid is 32x32 pixels

# ---- palette (r,g,b,a) -----------------------------------------------------
CLR = {
    ' ': (0, 0, 0, 0),          # transparent (outside the rounded tile)
    '.': (79, 70, 229, 255),    # indigo tile
    ',': (67, 56, 202, 255),    # indigo tile, darker (bottom shading band)
    'w': (245, 246, 252, 255),  # mic body (near-white)
    'd': (52, 44, 148, 255),    # drop shadow on the tile (darker purple)
    'Z': (255, 138, 24, 255),   # orange Z (main fill)
    'H': (255, 184, 102, 255),  # orange Z highlight (top/left bevel)
    'S': (198, 92, 10, 255),    # orange Z shadow (bottom/right bevel)
}

grid = [[' '] * N for _ in range(N)]


def rounded_rect_mask(x0, y0, x1, y1, r):
    """Yield (x,y) inside a filled rounded rectangle [x0,x1]x[y0,y1]."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            dx = 0
            if x < x0 + r:
                dx = (x0 + r) - x
            elif x > x1 - r:
                dx = x - (x1 - r)
            dy = 0
            if y < y0 + r:
                dy = (y0 + r) - y
            elif y > y1 - r:
                dy = y - (y1 - r)
            if dx * dx + dy * dy <= r * r:
                yield x, y


def put(x, y, c):
    if 0 <= x < N and 0 <= y < N:
        grid[y][x] = c


# ---- 1. background tile (rounded square) -----------------------------------
# Diagonal two-tone: lighter toward the top-left, darker toward the bottom-right,
# so the split reads as lighting rather than a horizontal "shelf" line.
for x, y in rounded_rect_mask(0, 0, 31, 31, 6):
    grid[y][x] = '.' if (x + y) < 30 else ','

BG = lambda x, y: '.' if (x + y) < 30 else ','

# ---- 2. a big bold Z ------------------------------------------------------
# Hand-drawn 20x22 Z bitmap: thick top/bottom bars joined by a fat diagonal.
Zart = [
    "####################",  # 0  top bar
    "####################",  # 1
    "####################",  # 2
    "####################",  # 3
    "####################",  # 4
    ".............####....",  # 5  fat diagonal, top-right → bottom-left
    "............####.....",  # 6
    "...........####......",  # 7
    "..........####.......",  # 8
    ".........####........",  # 9
    "........####.........",  # 10
    ".......####..........",  # 11
    "......####...........",  # 12
    ".....####............",  # 13
    "....####.............",  # 14
    "...####..............",  # 15
    "..####...............",  # 16
    "####################",  # 17  bottom bar
    "####################",  # 18
    "####################",  # 19
    "####################",  # 20
    "####################",  # 21
]
ZW, ZH = 20, 22
zx, zy = (N - ZW) // 2, (N - ZH) // 2  # centre the Z on the tile

mask = set()
for ry, row in enumerate(Zart):
    for rx, ch in enumerate(row):
        if ch == '#':
            mask.add((zx + rx, zy + ry))

# Drop shadow: the Z shape offset down-right, painted darker purple behind it.
for (x, y) in mask:
    for ox, oy in ((2, 2), (2, 1), (1, 2)):
        p = (x + ox, y + oy)
        if p not in mask and 0 <= p[0] < N and 0 <= p[1] < N \
                and grid[p[1]][p[0]] in ('.', ','):
            put(p[0], p[1], 'd')

# Bevel shading: top/left rim = highlight, bottom/right rim = shadow.
for (x, y) in mask:
    up = (x, y - 1) not in mask
    left = (x - 1, y) not in mask
    down = (x, y + 1) not in mask
    right = (x + 1, y) not in mask
    if down or right:
        put(x, y, 'S')
    elif up or left:
        put(x, y, 'H')
    else:
        put(x, y, 'Z')

# ---------------------------------------------------------------------------
def to_rgba(scale):
    """Return (w, h, rows[bytes]) upscaled by integer `scale` (nearest)."""
    w = h = N * scale
    rows = []
    for y in range(N):
        line = bytearray()
        for _ in range(scale):
            line_row = bytearray()
            for x in range(N):
                r, g, b, a = CLR[grid[y][x]]
                line_row += bytes((r, g, b, a)) * scale
            line[:] = line_row
            rows.append(bytes(line))
    return w, h, rows


def resample(scale_from_rows, src_w, src_h, dst):
    """Nearest-neighbour resample already-rendered rows to dst x dst."""
    out = []
    for dy in range(dst):
        sy = dy * src_h // dst
        srow = scale_from_rows[sy]
        line = bytearray()
        for dx in range(dst):
            sx = dx * src_w // dst
            line += srow[sx * 4:sx * 4 + 4]
        out.append(bytes(line))
    return dst, dst, out


def write_png(path, w, h, rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    raw = bytearray()
    for r in rows:
        raw += b'\x00' + r  # filter type 0
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


# Render a big crisp master at 32x (1024px), then derive every size from it.
master_w, master_h, master_rows = to_rgba(32)  # 1024x1024

out_dir = sys.argv[1]
iconset = os.path.join(out_dir, 'AppIcon.iconset')
os.makedirs(iconset, exist_ok=True)

# .iconset entries required by iconutil
sizes = {
    'icon_16x16.png': 16, 'icon_16x16@2x.png': 32,
    'icon_32x32.png': 32, 'icon_32x32@2x.png': 64,
    'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
    'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
    'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
}
for name, px in sizes.items():
    w, h, rows = resample(master_rows, master_w, master_h, px)
    write_png(os.path.join(iconset, name), w, h, rows)

# README/GitHub logo + a general-purpose PNG
for name, px in (('logo.png', 512), ('icon-1024.png', 1024)):
    w, h, rows = resample(master_rows, master_w, master_h, px)
    write_png(os.path.join(out_dir, name), w, h, rows)

print("generated pixel-art assets in", out_dir)
