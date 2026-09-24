#!/usr/bin/env python3
"""Generate the zwisp graphics: an 8-bit LED equalizer, echoing the on-screen
dictation wave (columns of discrete lit cells, white with subtly-coloured tips,
on a black tile).

Produces:
  - AppIcon.iconset/*  + logo.png + icon-1024.png  — the square app icon
  - banner.png                                     — README header: equalizer + "zwisp" wordmark
  - dmg-background.png                             — the installer window (build-dmg.sh): banner
                                                     above a pixel arrow between the two icons
  - og.png                                         — 1200×630 link-preview card for the website

Pure stdlib (zlib) so it runs anywhere without Pillow/ImageMagick. The look
mirrors Sources/zwisp/DictationOverlay.swift: 9 bars, 5 rows, lit cells fill
from the base, faint ghost cells above, sharp corners (the pixel aesthetic).
"""
import struct, zlib, os, sys

# ---- palette ---------------------------------------------------------------
TILE   = (6, 6, 8)          # near-black background tile
LIT    = (242, 243, 250)    # lit LED cell (near-white)
GHOST  = (32, 32, 38)       # unlit ghost cell (white at low alpha over black)
CLEAR  = (0, 0, 0, 0)       # transparent (outside the rounded tile)

# Bar heights (lit cells, 1..ROWS) — a symmetric, lively equalizer snapshot.
HEIGHTS = [2, 4, 3, 5, 4, 5, 3, 4, 2]
BARS = len(HEIGHTS)
ROWS = 5

# Subtle colour at the very tip (top lit cell) of each bar — soft, light hues
# that read as white-ish with a colour cast on black. One per bar.
TIPS = [
    (109, 182, 255),  # blue
    (87, 240, 203),   # teal
    (155, 240, 107),  # green
    (244, 228, 107),  # yellow
    (255, 176, 102),  # orange
    (255, 133, 189),  # pink
    (192, 140, 255),  # purple
    (109, 168, 255),  # blue
    (87, 240, 203),   # teal
]

# Cell-to-gap ratios (bar gap = 0.5·barWidth, row gap = 0.5·cellHeight), so a
# box of width bw fits BARS bars and height bh fits ROWS rows.
BAR_GAP = 0.5
ROW_GAP = 0.5


# ---- framebuffer -----------------------------------------------------------
def new_fb(w, h):
    return [bytearray(w * 4) for _ in range(h)]  # all zero = transparent


def set_px(fb, w, h, x, y, rgb):
    if 0 <= x < w and 0 <= y < h:
        o = x * 4
        fb[y][o:o + 4] = bytes((rgb[0], rgb[1], rgb[2], 255))


def fill_rect(fb, w, h, x0, y0, x1, y1, rgb):
    xa, xb = int(round(x0)), int(round(x1))
    ya, yb = int(round(y0)), int(round(y1))
    for y in range(max(0, ya), min(h, yb)):
        for x in range(max(0, xa), min(w, xb)):
            o = x * 4
            fb[y][o:o + 4] = bytes((rgb[0], rgb[1], rgb[2], 255))


def fill_rounded_rect(fb, w, h, x0, y0, x1, y1, r, rgb):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
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
                set_px(fb, w, h, x, y, rgb)


def draw_equalizer(fb, w, h, bx, by, bw, bh):
    """Draw the 9x5 LED equalizer filling the box (bx,by,bw,bh). Bars grow from
    the box's bottom edge; unlit cells above each bar render as faint ghosts."""
    bar_w = bw / (BARS + (BARS - 1) * BAR_GAP)
    gap_x = bar_w * BAR_GAP
    cell_h = bh / (ROWS + (ROWS - 1) * ROW_GAP)
    gap_y = cell_h * ROW_GAP
    baseline = by + bh
    for i in range(BARS):
        x0 = bx + i * (bar_w + gap_x)
        lit = HEIGHTS[i]
        for row in range(ROWS):          # row 0 = bottom
            y1 = baseline - row * (cell_h + gap_y)
            y0 = y1 - cell_h
            if row < lit:
                color = TIPS[i] if row == lit - 1 else LIT
            else:
                color = GHOST
            fill_rect(fb, w, h, x0, y0, x0 + bar_w, y1, color)


# ---- pixel font (lowercase, 9 rows tall; baseline row 6, descender rows 7-8) -
GLYPHS = {
    'z': ["....."[:5], ".....",
          "#####", "...#.", "..#..", ".#...", "#####",
          ".....", "....."],
    'w': [".....", ".....",
          "#...#", "#...#", "#...#", "#.#.#", ".#.#.",
          ".....", "....."],
    'i': ["#", ".",
          "#", "#", "#", "#", "#",
          ".", "."],
    's': [".....", ".....",
          ".####", "#....", ".###.", "....#", "####.",
          ".....", "....."],
    'p': [".....", ".....",
          "####.", "#...#", "#...#", "####.", "#....",
          "#....", "#...."],
}
FONT_ROWS = 9
# Accent the dot of the 'i' with a tip hue for a subtle touch of colour.
I_DOT_COLOR = TIPS[4]  # orange


def wordmark_dims(cell):
    word = "zwisp"
    widths = [len(GLYPHS[c][2]) for c in word]
    total = sum(widths) + (len(word) - 1)  # 1-col gap between glyphs
    return total * cell, FONT_ROWS * cell


def draw_wordmark(fb, w, h, ox, oy, cell):
    word = "zwisp"
    cx = ox
    for c in word:
        g = GLYPHS[c]
        gw = len(g[2])
        for ry in range(FONT_ROWS):
            row = g[ry] if ry < len(g) else ""
            for rx in range(gw):
                ch = row[rx] if rx < len(row) else '.'
                if ch == '#':
                    color = I_DOT_COLOR if (c == 'i' and ry == 0) else LIT
                    fill_rect(fb, w, h,
                              cx + rx * cell, oy + ry * cell,
                              cx + (rx + 1) * cell, oy + (ry + 1) * cell, color)
        cx += (gw + 1) * cell


# ---- compositions ----------------------------------------------------------
def render_icon(size):
    fb = new_fb(size, size)
    r = int(size * 0.2)
    fill_rounded_rect(fb, size, size, 0, 0, size - 1, size - 1, r, TILE)
    bw, bh = size * 0.64, size * 0.50
    bx, by = (size - bw) / 2, (size - bh) / 2
    draw_equalizer(fb, size, size, bx, by, bw, bh)
    return size, size, fb


def render_banner():
    cell = 26
    ww, wh = wordmark_dims(cell)
    pad = 66
    eq_h = int(wh * 0.92)
    eq_w = int(eq_h * 1.5)
    gap = 74
    content_w = eq_w + gap + ww
    W = pad + content_w + pad
    H = wh + pad * 2
    fb = new_fb(W, H)
    r = int(H * 0.14)
    fill_rounded_rect(fb, W, H, 0, 0, W - 1, H - 1, r, TILE)
    # Equalizer, vertically centred, on the left.
    eq_y = (H - eq_h) / 2
    draw_equalizer(fb, W, H, pad, eq_y, eq_w, eq_h)
    # Wordmark, vertically centred, to the right.
    draw_wordmark(fb, W, H, pad + eq_w + gap, (H - wh) / 2, cell)
    return W, H, fb


# The DMG window, in points; build-dmg.sh sizes the Finder window and places
# the two icons (zwisp.app on the left, Applications on the right) to match.
# An icon's Finder `position` is its centre; a 128 pt icon's label is centred
# 83 pt below that (measured on macOS 15) — the label plates rely on it.
DMG_WINDOW = (660, 380)
DMG_ICON_Y = 225
DMG_LABEL_CENTER_Y = DMG_ICON_Y + 83
DMG_APP_X, DMG_APPS_X = 165, 495
# Finder always draws icon labels in black over a picture backdrop, so each
# label sits on a lit plate — a white cell, like the equalizer's.
DMG_PLATE = (150, 30)

# A chunky right-pointing pixel arrow, 1 char = 1 cell.
ARROW = [
    "........#...",
    "........##..",
    "........###.",
    "############",
    "........###.",
    "........##..",
    "........#...",
]


def render_dmg_background(scale=2):
    """The installer backdrop at @2x: the banner composition centred above
    the icon row, an arrow between where the icons will sit, and a lit plate
    under each icon for Finder's (black) label."""
    W, H = DMG_WINDOW[0] * scale, DMG_WINDOW[1] * scale
    fb = new_fb(W, H)
    fill_rect(fb, W, H, 0, 0, W, H, TILE)
    # Banner: equalizer + wordmark, centred in the top band.
    cell = 7 * scale
    ww, wh = wordmark_dims(cell)
    eq_h = int(wh * 0.92)
    eq_w = int(eq_h * 1.5)
    gap = 24 * scale
    content_w = eq_w + gap + ww
    ox = (W - content_w) / 2
    oy = 52 * scale
    draw_equalizer(fb, W, H, ox, oy + (wh - eq_h) / 2, eq_w, eq_h)
    draw_wordmark(fb, W, H, ox + eq_w + gap, oy, cell)
    # Arrow, centred between the two icons on the icon row.
    acell = 6 * scale
    aw, ah = len(ARROW[0]) * acell, len(ARROW) * acell
    ax = (DMG_APP_X + DMG_APPS_X) / 2 * scale - aw / 2
    ay = DMG_ICON_Y * scale - ah / 2
    for ry, row in enumerate(ARROW):
        for rx, ch in enumerate(row):
            if ch == '#':
                fill_rect(fb, W, H, ax + rx * acell, ay + ry * acell,
                          ax + (rx + 1) * acell, ay + (ry + 1) * acell, LIT)
    # Label plates.
    pw, ph = DMG_PLATE[0] * scale, DMG_PLATE[1] * scale
    for cx in (DMG_APP_X, DMG_APPS_X):
        x0 = cx * scale - pw / 2
        y0 = DMG_LABEL_CENTER_Y * scale - ph / 2
        fill_rounded_rect(fb, W, H, x0, y0, x0 + pw, y0 + ph, 6 * scale, LIT)
    return W, H, fb


def render_og():
    """The website's link-preview card: the banner composition on a full
    1200×630 tile (no rounding — preview crops are unforgiving)."""
    W, H = 1200, 630
    fb = new_fb(W, H)
    fill_rect(fb, W, H, 0, 0, W, H, TILE)
    cell = 22
    ww, wh = wordmark_dims(cell)
    eq_h = int(wh * 0.92)
    eq_w = int(eq_h * 1.5)
    gap = 64
    content_w = eq_w + gap + ww
    ox, oy = (W - content_w) / 2, (H - wh) / 2
    draw_equalizer(fb, W, H, ox, oy + (wh - eq_h) / 2, eq_w, eq_h)
    draw_wordmark(fb, W, H, ox + eq_w + gap, oy, cell)
    return W, H, fb


# ---- PNG -------------------------------------------------------------------
def write_png(path, w, h, fb, dpi=None):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    raw = bytearray()
    for row in fb:
        raw += b'\x00' + row  # filter type 0
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    if dpi:  # pHYs: pixels per metre, so Finder scales a @2x backdrop right
        ppm = int(round(dpi / 0.0254))
        png += chunk(b'pHYs', struct.pack(">IIB", ppm, ppm, 1))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def main():
    out_dir = sys.argv[1]
    preview = len(sys.argv) > 2 and sys.argv[2] == "preview"
    if preview:
        w, h, fb = render_icon(256)
        write_png(os.path.join(out_dir, "preview-icon.png"), w, h, fb)
        w, h, fb = render_banner()
        write_png(os.path.join(out_dir, "preview-banner.png"), w, h, fb)
        print("wrote preview-icon.png + preview-banner.png")
        return

    iconset = os.path.join(out_dir, 'AppIcon.iconset')
    os.makedirs(iconset, exist_ok=True)
    sizes = {
        'icon_16x16.png': 16, 'icon_16x16@2x.png': 32,
        'icon_32x32.png': 32, 'icon_32x32@2x.png': 64,
        'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
        'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
        'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
    }
    for name, px in sizes.items():
        w, h, fb = render_icon(px)
        write_png(os.path.join(iconset, name), w, h, fb)
    for name, px in (('logo.png', 512), ('icon-1024.png', 1024)):
        w, h, fb = render_icon(px)
        write_png(os.path.join(out_dir, name), w, h, fb)
    w, h, fb = render_banner()
    write_png(os.path.join(out_dir, 'banner.png'), w, h, fb)
    w, h, fb = render_dmg_background()
    write_png(os.path.join(out_dir, 'dmg-background.png'), w, h, fb, dpi=144)
    w, h, fb = render_og()
    write_png(os.path.join(out_dir, 'og.png'), w, h, fb)
    print("generated equalizer assets in", out_dir)


if __name__ == "__main__":
    main()
