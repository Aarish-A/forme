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

## convert_sface.py

Converts OpenCV Zoo's SFace face-recognition model to
`Forme/Resources/Models/SFace.mlpackage`, the Core ML model behind
`VisionFaceIdentityService`. Re-runnable end-to-end: download → convert →
validate → emit. Nothing is written unless the artifact passes the parity bar.

### Usage

```sh
python3 -m venv venv
./venv/bin/pip install coremltools onnx2torch torch onnx onnxruntime opencv-python numpy
./venv/bin/python tools/convert_sface.py
```

Options: `--output <path>` (default `Forme/Resources/Models/SFace.mlpackage`),
`--cache-dir <dir>` (reuse a downloaded ONNX; checksum-verified either way).

Last validated with Python 3.11.9, coremltools 9.0, onnx2torch 1.5.15,
torch 2.13.0, opencv-python 5.0.0.93 on macOS.

### Conversion route

coremltools dropped direct ONNX ingestion years ago, so the route is
`onnx → onnx2torch → torch.jit.trace → ct.convert` (mlprogram,
`minimum_deployment_target=iOS16`). fp32 is converted and validated first to
prove the graph and preprocessing are correct in isolation; fp16 is then
converted, re-validated independently, and shipped if it passes.

### Model interface

| | |
|---|---|
| Input | `"image"` — 112×112 RGB color image |
| Output | `"embedding"` — float multiarray, shape (1, 128), fp16 |
| Type | mlprogram, fp16 weights and compute |
| Size | ~19 MB (fp32 would be ~38 MB) |

The embedding is **unnormalized** (matching OpenCV's
`FaceRecognizerSF.feature()`); L2-normalize in Swift before cosine/dot-product
comparison, as `FaceEmbedding` expects.

### Validated preprocessing (baked into the model)

Determined empirically against the `cv2.FaceRecognizerSF.feature()` oracle:
OpenCV feeds the network **RGB channel order, raw 0–255 pixel values, no mean
subtraction, no scaling** (`blobFromImage` with `swapRB=true`, scalefactor
1.0). Baked in as:

```python
ct.ImageType(name="image", shape=(1, 3, 112, 112),
             color_layout=ct.colorlayout.RGB, scale=1.0)  # no bias
```

So Swift passes a plain 112×112 pixel buffer of the aligned face crop —
no manual normalization. In practice `VisionFaceIdentityService` renders the
crop into a `kCVPixelFormatType_32BGRA` `CVPixelBuffer` (black-padded outside
the warped source) and hands it to `MLModel` directly; Core ML converts the
buffer to the model's declared RGB layout itself, so no channel swap is
needed in Swift. The crop must be aligned to the ArcFace 112×112
5-point template (see `docs/SCAN_PIPELINE.md` / contract 4.6); the oracle and
Core ML must see the same aligned pixels for embeddings to be comparable.

Wrong-preprocessing cosines, for the record (why this had to be empirical):
BGR 0–255 ≈ 0.877, RGB /255 ≈ −0.035, RGB (x−127.5)/128 ≈ −0.309.

### Parity results (acceptance bar: cosine ≥ 0.999 on ≥ 10 varied inputs)

12 synthetic 112×112 inputs: random noise (3 seeds), red/blue and green
gradients, dark and bright low-contrast noise, blurred noise, two synthetic
face renders, saturated color checkerboard, vignetted blur. Cosine similarity
between Core ML `predict` (macOS) and the OpenCV oracle:

| Input | fp32 | fp16 |
|---|---|---|
| 1 noise a | 1.000000 | 0.999993 |
| 2 noise b | 1.000000 | 0.999996 |
| 3 noise c | 1.000000 | 0.999996 |
| 4 red/blue gradient | 1.000000 | 0.999694 |
| 5 green gradient | 1.000000 | 0.999966 |
| 6 dark noise | 1.000000 | 0.999990 |
| 7 bright noise | 1.000000 | 0.999970 |
| 8 blurred noise | 1.000000 | 0.999996 |
| 9 face render a | 1.000000 | 0.999994 |
| 10 face render b | 1.000000 | 0.999994 |
| 11 checkerboard | 1.000000 | 0.999987 |
| 12 vignetted blur | 1.000000 | 0.999985 |

Worst case fp16: 0.999694. The shipped artifact is fp16.

### License and attribution

The SFace weights are from [OpenCV Zoo](https://github.com/opencv/opencv_zoo)
(`models/face_recognition_sface/face_recognition_sface_2021dec.onnx`),
licensed **Apache-2.0**. Model: "SFace: Sigmoid-Constrained Hypersphere Loss
for Robust Face Recognition" (Zhong et al., IEEE TIP 2021); ONNX model
contributed by Yuantao Feng et al. The converted `SFace.mlpackage` is a
derivative of those weights and remains Apache-2.0. Do not substitute
InsightFace/EdgeFace weights — their weights are non-commercial regardless of
code license.
