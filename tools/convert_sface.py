#!/usr/bin/env python3
"""Convert OpenCV Zoo's SFace face-recognition model to Core ML.

End-to-end and re-runnable: download -> convert -> validate -> emit.

Pipeline
    face_recognition_sface_2021dec.onnx  (OpenCV Zoo, Apache-2.0)
      -> onnx2torch  (coremltools has no direct ONNX path anymore)
      -> torch.jit.trace
      -> coremltools ct.convert with preprocessing baked in via ct.ImageType
      -> SFace.mlpackage  (input "image", 112x112 color; output "embedding", 128-d)

Preprocessing (validated empirically in this script against the
cv2.FaceRecognizerSF.feature() oracle):
    RGB channel order, raw pixel values 0-255, no mean subtraction, no scaling.
    OpenCV's FaceRecognizerSF internally calls blobFromImage with swapRB=true
    and scalefactor 1.0, so the network consumes RGB 0-255 floats. That means
    ct.ImageType(color_layout=RGB, scale=1.0, bias=None) and Swift can hand the
    model a plain RGB pixel buffer.

Acceptance bar: cosine similarity >= 0.999 between Core ML predictions (on
this Mac) and the OpenCV oracle across >= 10 varied synthetic 112x112 inputs.
The fp16 artifact is preferred and must independently pass the same bar.

Usage
    python3 -m venv venv && ./venv/bin/pip install \
        coremltools onnx2torch torch onnx onnxruntime opencv-python numpy
    ./venv/bin/python tools/convert_sface.py \
        --output Forme/Resources/Models/SFace.mlpackage

Exit code is non-zero if download, conversion, or parity validation fails;
nothing is written to --output unless the shipped precision passed parity.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

MODEL_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/main/"
    "models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
)
MODEL_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
PARITY_BAR = 0.999
EMBEDDING_DIM = 128
INPUT_SIZE = 112


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def download_onnx(cache_dir: Path) -> Path:
    """Fetch the ONNX weights (or reuse a cached, checksum-verified copy)."""
    path = cache_dir / "face_recognition_sface_2021dec.onnx"
    if not path.exists():
        print(f"downloading {MODEL_URL}")
        tmp = path.with_suffix(".onnx.partial")
        try:
            urllib.request.urlretrieve(MODEL_URL, tmp)
        except OSError as err:
            fail(f"download failed: {err}\nURL: {MODEL_URL}")
        tmp.rename(path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != MODEL_SHA256:
        path.unlink()
        fail(
            "ONNX checksum mismatch (upstream file changed?).\n"
            f"  expected {MODEL_SHA256}\n  got      {digest}\n"
            "Delete the cache and re-run; if it persists, re-verify the "
            "upstream model and update MODEL_SHA256."
        )
    print(f"onnx ready: {path} ({path.stat().st_size / 1e6:.1f} MB)")
    return path


def convert(onnx_path: Path, precision: str):
    """ONNX -> torch -> traced -> Core ML mlprogram with baked preprocessing."""
    import coremltools as ct
    import torch
    from onnx2torch import convert as onnx_to_torch

    torch_model = onnx_to_torch(str(onnx_path)).eval()
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE)
    traced = torch.jit.trace(torch_model, example)

    # Validated preprocessing: RGB, raw 0-255 (scale 1.0, no bias). See module
    # docstring; the parity check below is the proof.
    model = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                color_layout=ct.colorlayout.RGB,
                scale=1.0,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=(
            ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
        ),
        convert_to="mlprogram",
    )
    model.short_description = (
        "SFace face-recognition embedding (OpenCV Zoo, Apache-2.0). "
        "Input: 112x112 RGB face crop aligned to the ArcFace template. "
        "Output: 128-d embedding (unnormalized; L2-normalize before cosine)."
    )
    model.license = "Apache-2.0"
    return model


def test_images() -> list:
    """>= 10 varied synthetic 112x112 RGB uint8 images.

    Deliberately diverse: strongly colored images catch RGB/BGR swaps, smooth
    and dark/bright images catch scale/bias errors, noise and face-like
    renders exercise the full activation range.
    """
    import cv2
    import numpy as np

    size = INPUT_SIZE
    rng = np.random.default_rng(2026)
    images = []

    # 1-3: uniform random noise, three seeds.
    for _ in range(3):
        images.append(rng.integers(0, 256, (size, size, 3), dtype=np.uint8))

    # 4: horizontal red->blue gradient (channel-asymmetric).
    ramp = np.linspace(0, 255, size, dtype=np.uint8)
    img = np.zeros((size, size, 3), np.uint8)
    img[:, :, 0] = ramp[None, :]
    img[:, :, 2] = ramp[::-1][None, :]
    images.append(img)

    # 5: vertical green gradient over mid gray.
    img = np.full((size, size, 3), 128, np.uint8)
    img[:, :, 1] = ramp[:, None]
    images.append(img)

    # 6: dark low-contrast noise. 7: bright low-contrast noise.
    images.append(rng.integers(0, 64, (size, size, 3), dtype=np.uint8))
    images.append(rng.integers(192, 256, (size, size, 3), dtype=np.uint8))

    # 8: blurred noise (natural-image-like spectrum).
    smooth = cv2.GaussianBlur(
        rng.integers(0, 256, (size, size, 3), dtype=np.uint8), (0, 0), 4
    )
    images.append(smooth)

    # 9-10: crude synthetic "faces" - skin-tone ellipse, eyes, mouth - at two
    # positions, roughly matching the aligned-crop geometry the app produces.
    for dx in (0, 8):
        img = np.full((size, size, 3), 40, np.uint8)
        cv2.ellipse(img, (56 + dx, 60), (34, 44), 0, 0, 360, (224, 172, 138), -1)
        cv2.circle(img, (42 + dx, 52), 5, (30, 30, 30), -1)
        cv2.circle(img, (70 + dx, 52), 5, (30, 30, 30), -1)
        cv2.ellipse(img, (56 + dx, 88), (14, 6), 0, 0, 180, (120, 50, 50), 2)
        images.append(img)

    # 11: checkerboard with saturated color blocks.
    img = np.zeros((size, size, 3), np.uint8)
    block = 16
    colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
    for y in range(0, size, block):
        for x in range(0, size, block):
            img[y : y + block, x : x + block] = colors[((y + x) // block) % 4]
    images.append(img)

    # 12: real photograph-like sample from OpenCV's built-in test pattern.
    gray = cv2.getGaussianKernel(size, 20)
    vignette = (gray @ gray.T) / (gray @ gray.T).max()
    img = (smooth.astype(np.float32) * vignette[:, :, None]).astype(np.uint8)
    images.append(img)

    assert len(images) >= 10
    return images


def validate(model, onnx_path: Path, label: str) -> list[float]:
    """Cosine similarity of Core ML predict vs the cv2 oracle per test image."""
    import cv2
    import numpy as np
    from PIL import Image

    oracle = cv2.FaceRecognizerSF.create(str(onnx_path), "")
    sims: list[float] = []
    for rgb in test_images():
        # The oracle is plain OpenCV: it expects a BGR Mat of the same pixels.
        bgr = np.ascontiguousarray(rgb[:, :, ::-1])
        ref = oracle.feature(bgr).ravel()
        out = model.predict({"image": Image.fromarray(rgb)})["embedding"].ravel()
        if out.shape[0] != EMBEDDING_DIM:
            fail(f"unexpected embedding size {out.shape[0]} (want {EMBEDDING_DIM})")
        sims.append(
            float(np.dot(ref, out) / (np.linalg.norm(ref) * np.linalg.norm(out)))
        )
    worst = min(sims)
    print(f"parity [{label}]: worst {worst:.6f} over {len(sims)} inputs")
    for i, s in enumerate(sims, 1):
        print(f"  input {i:2d}: cosine {s:.6f}")
    return sims


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "Forme/Resources/Models/SFace.mlpackage",
        help="destination .mlpackage path (default: Forme/Resources/Models/SFace.mlpackage)",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=None,
        help="where to cache the downloaded ONNX (default: a temp dir kept per run)",
    )
    args = parser.parse_args()

    cache_dir = args.cache_dir or Path(tempfile.gettempdir()) / "sface-convert-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = download_onnx(cache_dir)

    # fp32 first: proves conversion + preprocessing are right in isolation, so
    # an fp16 failure could only be a quantization problem.
    print("converting fp32 ...")
    fp32 = convert(onnx_path, "fp32")
    fp32_sims = validate(fp32, onnx_path, "fp32")
    if min(fp32_sims) < PARITY_BAR:
        fail(
            f"fp32 parity {min(fp32_sims):.6f} < {PARITY_BAR}: conversion or "
            "preprocessing is wrong - do NOT ship. Re-check the ImageType "
            "settings against the oracle (see module docstring)."
        )

    print("converting fp16 ...")
    fp16 = convert(onnx_path, "fp16")
    fp16_sims = validate(fp16, onnx_path, "fp16")

    if min(fp16_sims) >= PARITY_BAR:
        chosen, label = fp16, "fp16"
    else:
        print(
            f"fp16 parity {min(fp16_sims):.6f} < {PARITY_BAR}; "
            "falling back to fp32 artifact"
        )
        chosen, label = fp32, "fp32"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        shutil.rmtree(args.output)
    chosen.save(str(args.output))
    size_mb = sum(f.stat().st_size for f in args.output.rglob("*") if f.is_file()) / 1e6
    print(f"saved {label} artifact: {args.output} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
