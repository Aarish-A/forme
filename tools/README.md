# tools

Offline build tooling. The scripts themselves don't ship — the artifacts they
emit into `Forme/Resources/` do.

## make_brand_assets.py

Regenerates every Forme brand artifact from the single traced outline embedded
in the script: the in-app mark, the three app-icon PNGs, and the standalone
SVGs under `docs/brand/`. Standard library only — no venv, no `pip install` —
because this has to still run on a rebrand years from now.

### Usage

```sh
python3 tools/make_brand_assets.py           # write everything (~2s)
python3 tools/make_brand_assets.py --check   # verify on-disk files match
```

`--check` compares decoded pixels and file text rather than raw bytes, so
re-encoding with a different PNG writer isn't reported as drift. It exits
non-zero on a real mismatch.

### What it emits

| Path | Why |
|---|---|
| `Assets.xcassets/FormeMark.imageset/FormeMark.svg` | The in-app mark. Template SVG with vector data preserved, so it tints from `Theme.Colors` and stays crisp at any size. |
| `Assets.xcassets/AppIcon.appiconset/AppIcon{,-Dark,-Tinted}.png` | App icon, 1024². |
| `docs/brand/forme-mark{,-oxblood,-rose}.svg` | The mark for use outside the app — web, press, Figma. `currentColor` plus the two brand colourways. |
| `docs/brand/forme-icon-{light,dark}.svg` | Icon artwork as vector, full-bleed square. Every platform applies its own corner mask. |

### Why the icons are PNG

Apple's `.appiconset` accepts raster only. That's a platform constraint, not a
preference — so unlike the in-app mark, **the icons can't follow the colour
tokens at runtime**. Rerun this after any palette change or the icon silently
goes stale.

### Colour

The light icon is exactly `AccentFill` on `OnAccentFill`. The dark icon uses two
values that are deliberately *not* palette tokens: the field is `AccentFill`
with lightness pulled 27.8% → 19.2% and hue/saturation held, and the mark is a
warmer, greyer cream. That's safe only because an app icon is never seen beside
app chrome, so the two creams never meet — don't reach for either inside the app.

### Provenance

The outline is a 56-Bézier trace of the original artwork, in three disjoint
subpaths (one per ribbon). It was verified two ways: against the source image at
0.006% of ink area, and against Apple's own renderer — reading the mark back out
of a compiled `Assets.car` — at 0.002%.
