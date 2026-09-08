#!/usr/bin/env python3
"""Generate every Forme brand artifact from one traced outline.

The mark was traced once from the original artwork; the outline below is that
trace. Everything downstream -- the in-app SVG, the three app-icon PNGs, and the
standalone SVGs for non-app use -- is emitted from it here, so the mark can
never drift between places.

Depends on nothing outside the standard library. That is deliberate: this has to
still run on a rebrand years from now, and `pip install` is exactly the step
that stops being reproducible.

Usage
    python3 tools/make_brand_assets.py           # write everything
    python3 tools/make_brand_assets.py --check   # verify on-disk files match

`--check` compares pixels and text rather than file bytes, so re-encoding with a
different PNG writer is not reported as drift. It exits non-zero on a real
mismatch, which makes it usable as a CI guard.

## Why the icons are PNG and not SVG

Apple's `.appiconset` only accepts raster. That is a platform constraint, not a
preference -- so the icons are baked, and unlike the in-app mark they cannot
follow the colour tokens at runtime. Rerun this after any palette change.
"""

import argparse
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --------------------------------------------------------------- the outline

# Traced from the original artwork: 56 cubic Beziers in three disjoint subpaths,
# one per ribbon. Verified against the source at 0.006% of ink area, and against
# Apple's own renderer (reading it back out of a compiled Assets.car) at 0.002%.
VIEWBOX = "0 0 67.924 100"
MARK_W, MARK_H = 67.924, 100.0
PATH_D = (
    "M31.5 0C31.09 0.29 30.83 0.74 30.5 1.12C29.91 1.81 29.29 2.47 28.64 3.1C26.54 5.14 24.31 6.99 "
    "21.95 8.73C17.89 11.7 13.55 14.26 9.47 17.21C6.41 19.41 3.37 22.01 1.61 25.42C-1.11 30.66 -0.3"
    "7 37.05 3.74 41.36C4.55 42.22 5.6 43.43 6.73 43.85C6.86 43.42 6.49 43.23 6.22 42.92C5.76 42.39"
    " 5.33 41.82 4.96 41.22C3.83 39.34 3.37 36.91 4.44 34.9C5.17 33.54 6.39 32.6 7.69 31.82C10.28 3"
    "0.27 13.27 29.49 16.18 28.8C21.06 27.65 26.15 27.2 31.15 27.14C37.59 27.06 44.04 27.63 50.45 2"
    "6.75C55.73 26.04 61.35 24.39 65.17 20.47C66.15 19.46 66.99 18.3 67.56 17.01C67.76 16.57 68.02 "
    "16.08 67.89 15.6C67.19 15.96 66.63 16.6 65.93 16.99C64.81 17.62 63.48 17.97 62.2 18.15C59.53 1"
    "8.52 56.72 17.99 54.16 17.24C48.29 15.52 42.99 11.9 38.56 7.76C36.8 6.11 35.14 4.34 33.6 2.49C"
    "33.15 1.95 32.72 1.38 32.3 0.82C32.04 0.49 31.91 0.13 31.5 0ZM61.69 30.91C61.34 31.28 61.13 31"
    ".73 60.8 32.12C60.01 33.06 59.11 33.82 58.05 34.44C55.79 35.75 53.06 36.13 50.5 36.36C45.49 36"
    ".81 40.45 36.19 35.43 36.08C27.8 35.9 20.03 37.92 13.98 42.74C10.64 45.39 7.89 48.61 6 52.44C5"
    ".6 53.25 5.22 54.07 4.9 54.92C4.73 55.38 4.48 55.84 4.56 56.34C4.93 56.12 5.14 55.83 5.43 55.5"
    "2C5.98 54.95 6.61 54.42 7.27 53.97C9.18 52.65 11.46 51.97 13.71 51.53C18.03 50.7 22.61 51.04 2"
    "6.96 51.35C30.96 51.64 35.01 51.8 39.01 51.56C41.82 51.4 44.64 51.06 47.31 50.15C53.47 48.06 5"
    "8.26 43.56 60.61 37.48C61.23 35.88 61.66 34.24 61.86 32.53C61.91 32.05 62.18 31.15 61.69 30.91"
    "ZM10.72 100C11.06 100.02 11.15 99.83 11.39 99.6C11.89 99.11 12.4 98.63 12.91 98.14C14.85 96.25"
    " 16.69 94.23 18.35 92.08C19.94 90.02 21.4 87.82 22.38 85.39C22.86 84.17 23.12 82.88 23.31 81.5"
    "9C24.65 72.18 17.27 65.01 12.66 57.72C12.07 56.79 11.58 55.78 11.16 54.77C10.96 54.3 10.85 53."
    "81 10.6 53.37C10.19 53.24 9.87 53.43 9.48 53.6C8.75 53.91 8.04 54.32 7.39 54.79C4.28 57.04 3.0"
    "3 60.46 2.81 64.18C2.3 73.06 6.98 80.84 9.55 89.02C10.24 91.22 10.79 93.49 10.9 95.8C10.93 96."
    "61 10.89 97.41 10.8 98.21C10.73 98.79 10.59 99.42 10.72 100Z"
)

# ------------------------------------------------------------------- palette

# Mirrors Assets.xcassets/Colors. Kept as literals rather than parsed from the
# colorsets so this script has one job and no coupling to that file layout --
# but they must agree, and `--check` in ContrastTests territory will not catch
# it if they do not. Update both together.
OXBLOOD = "6B2338"       # AccentFill / Accent.light
CREAM = "FDFCF9"         # OnAccentFill
ROSE = "D3A3AE"          # Accent.dark

# Icon-only, deliberately not palette tokens. The dark field is OXBLOOD with
# lightness pulled 27.8% -> 19.2% and hue/saturation held, so it is the same
# oxblood one step down. The dark mark is a warmer, greyer cream that is *not* a
# derivation of CREAM -- fine here because an app icon is only ever seen on the
# home screen, never beside app chrome, so the two creams never meet. Do not
# reach for either value inside the app.
DEEP_OXBLOOD = "4A1826"
DIM_CREAM = "EDE7DE"

ICON_SIZE = 1024
# Fraction of the canvas height the mark occupies. Apple's icon grid leaves
# generous margin, and the mark is tall and narrow, so height is the binding
# dimension.
ICON_MARK_FRACTION = 0.60
SUPERSAMPLE = 4


# ------------------------------------------------------------- path plumbing

def parse_subpaths(d):
    """The outline as a list of subpaths, each a list of cubic segments.

    Only M/C/Z, which is all the trace emits.
    """
    subpaths = []
    for chunk in d.split("M")[1:]:
        nums = []
        for token in chunk.replace("C", " ").replace("Z", " ").replace(",", " ").split():
            nums.append(float(token))
        start = (nums[0], nums[1])
        cur = start
        segs = []
        i = 2
        while i + 5 < len(nums) + 1 and i + 6 <= len(nums):
            p1 = (nums[i], nums[i + 1])
            p2 = (nums[i + 2], nums[i + 3])
            p3 = (nums[i + 4], nums[i + 5])
            segs.append((cur, p1, p2, p3))
            cur = p3
            i += 6
        if cur != start:
            segs.append((cur, cur, start, start))
        subpaths.append(segs)
    return subpaths


def flatten(segs, steps=32):
    pts = []
    for p0, p1, p2, p3 in segs:
        for s in range(steps):
            t = s / steps
            mt = 1 - t
            pts.append((
                mt**3 * p0[0] + 3*mt*mt*t * p1[0] + 3*mt*t*t * p2[0] + t**3 * p3[0],
                mt**3 * p0[1] + 3*mt*mt*t * p1[1] + 3*mt*t*t * p2[1] + t**3 * p3[1],
            ))
    return pts


def rasterise(loops, size, ss=SUPERSAMPLE):
    """Non-zero winding scanline fill, box-filtered down from ss x resolution."""
    big = size * ss
    acc = [[0] * size for _ in range(size)]

    edges = []
    for poly in loops:
        n = len(poly)
        for i in range(n):
            x0, y0 = poly[i]
            x1, y1 = poly[(i + 1) % n]
            if y0 != y1:
                edges.append((x0 * ss, y0 * ss, x1 * ss, y1 * ss))

    buckets = [[] for _ in range(big)]
    for e in edges:
        lo = max(0, int(min(e[1], e[3])))
        hi = min(big - 1, int(max(e[1], e[3])) + 1)
        for sy in range(lo, hi + 1):
            buckets[sy].append(e)

    for sy in range(big):
        yc = sy + 0.5
        xs = []
        for x0, y0, x1, y1 in buckets[sy]:
            if (y0 <= yc < y1) or (y1 <= yc < y0):
                t = (yc - y0) / (y1 - y0)
                xs.append((x0 + t * (x1 - x0), 1 if y1 > y0 else -1))
        if not xs:
            continue
        xs.sort()
        wind = 0
        row = acc[sy // ss]
        for j in range(len(xs) - 1):
            wind += xs[j][1]
            if wind == 0:
                continue
            a = max(0, int(xs[j][0] + 0.5))
            b = min(big, int(xs[j + 1][0] + 0.5))
            for sx in range(a, b):
                row[sx // ss] += 1

    span = ss * ss
    return [[min(1.0, c / span) for c in row] for row in acc]


def icon_coverage():
    """The mark's alpha coverage, placed on the icon canvas."""
    subpaths = parse_subpaths(PATH_D)
    scale = ICON_SIZE * ICON_MARK_FRACTION / MARK_H
    ox = (ICON_SIZE - MARK_W * scale) / 2.0
    oy = (ICON_SIZE - MARK_H * scale) / 2.0
    placed = [
        [tuple((p[0] * scale + ox, p[1] * scale + oy) for p in seg) for seg in sub]
        for sub in subpaths
    ]
    return rasterise([flatten(sub) for sub in placed], ICON_SIZE)


# ------------------------------------------------------------- PNG (stdlib)

def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def write_png(path, width, height, rows, alpha=False):
    """8-bit RGB/RGBA, no interlacing. `rows` is one bytes-like object per row."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        raw.extend(row)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def compose(cov, fg, bg=None):
    """Rows for `write_png`. With no `bg`, emits the mark on transparency."""
    f = rgb(fg)
    b = rgb(bg) if bg else None
    rows = []
    for y in range(ICON_SIZE):
        row = bytearray()
        cr = cov[y]
        for x in range(ICON_SIZE):
            a = cr[x]
            if b is None:
                row += bytes((f[0], f[1], f[2], int(round(a * 255))))
            else:
                row += bytes(tuple(int(round(b[i] + (f[i] - b[i]) * a)) for i in range(3)))
        rows.append(row)
    return rows


# ------------------------------------------------------------------- outputs

def mark_svg(fill=None):
    """The mark on its own. No fill attribute means the asset-catalog template
    takes the foreground colour; an explicit fill is for use outside the app."""
    attr = f' fill="{fill}"' if fill else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{MARK_W:g}" height="{MARK_H:g}"'
        f' viewBox="{VIEWBOX}">\n  <path{attr} d="{PATH_D}"/>\n</svg>\n'
    )


def icon_svg(field, mark):
    """Icon artwork as vector, for web and press. Square and full-bleed: every
    platform that uses this applies its own corner mask."""
    s = ICON_SIZE
    scale = s * ICON_MARK_FRACTION / MARK_H
    ox = (s - MARK_W * scale) / 2.0
    oy = (s - MARK_H * scale) / 2.0
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}"'
        f' viewBox="0 0 {s} {s}">\n'
        f'  <rect width="{s}" height="{s}" fill="#{field}"/>\n'
        f'  <g transform="translate({ox:.3f} {oy:.3f}) scale({scale:.6f})">\n'
        f'    <path fill="#{mark}" d="{PATH_D}"/>\n'
        f'  </g>\n</svg>\n'
    )


def targets():
    """Every artifact, as (path, kind, payload)."""
    assets = ROOT / "Forme/Resources/Assets.xcassets"
    brand = ROOT / "docs/brand"
    return [
        # In-app: one template SVG, tinted at the call site by Theme.Colors.
        (assets / "FormeMark.imageset/FormeMark.svg", "text", mark_svg()),
        # Standalone vectors for anything outside the app.
        (brand / "forme-mark.svg", "text", mark_svg("currentColor")),
        (brand / "forme-mark-oxblood.svg", "text", mark_svg(f"#{OXBLOOD}")),
        (brand / "forme-mark-rose.svg", "text", mark_svg(f"#{ROSE}")),
        (brand / "forme-icon-light.svg", "text", icon_svg(OXBLOOD, CREAM)),
        (brand / "forme-icon-dark.svg", "text", icon_svg(DEEP_OXBLOOD, DIM_CREAM)),
        # App icon. Raster because .appiconset accepts nothing else.
        (assets / "AppIcon.appiconset/AppIcon.png", "png", (CREAM, OXBLOOD)),
        (assets / "AppIcon.appiconset/AppIcon-Dark.png", "png", (DIM_CREAM, DEEP_OXBLOOD)),
        # Tinted: greyscale on transparency. iOS supplies tint and background,
        # so this one must carry neither.
        (assets / "AppIcon.appiconset/AppIcon-Tinted.png", "png", ("FFFFFF", None)),
    ]


def read_png_pixels(path):
    """Decode enough of our own PNGs to compare pixels. Filter type 0 only."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    pos, idat, w = 8, bytearray(), None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour not in (2, 6):
                raise ValueError(f"{path}: unsupported PNG ({depth}-bit, type {colour})")
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length

    channels = 4 if colour == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = w * channels
    rows, prev = [], bytes(stride)
    at = 0
    for _ in range(h):
        ftype = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        if ftype == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ftype != 0:
            raise ValueError(f"{path}: unknown filter {ftype}")
        rows.append(bytes(line))
        prev = line
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify on-disk artifacts match; exit non-zero if not")
    args = ap.parse_args()

    cov = None
    drift = []
    for path, kind, payload in targets():
        if kind == "text":
            want = payload
            if args.check:
                have = path.read_text() if path.exists() else None
                if have != want:
                    drift.append(path)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(want)
            print(f"wrote {path.relative_to(ROOT)}")
        else:
            if cov is None:
                cov = icon_coverage()
            fg, bg = payload
            rows = compose(cov, fg, bg)
            if args.check:
                try:
                    if read_png_pixels(path) != rows:
                        drift.append(path)
                except (OSError, ValueError):
                    drift.append(path)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            write_png(path, ICON_SIZE, ICON_SIZE, rows, alpha=bg is None)
            print(f"wrote {path.relative_to(ROOT)}")

    if args.check:
        if drift:
            print("brand artifacts are stale; rerun tools/make_brand_assets.py:")
            for p in drift:
                print(f"  {p.relative_to(ROOT)}")
            return 1
        print(f"all {len(targets())} brand artifacts match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
