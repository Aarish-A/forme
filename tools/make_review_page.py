#!/usr/bin/env python3
"""Build the label-review page.

Everything the scan is measured against traces back to one judgement: which
photos are worth pulling a garment out of. I made that call 490 times; only the
owner of the wardrobe can say whether I got it right, and a wrong boundary means
every number the harness produces is optimising toward the wrong target.

So this asks for corrections, not labels. Each section shows what I decided and
asks only for the disagreements — clicking is the exception, silence is assent.
That turns a 490-photo labelling job into about four minutes of clicking.

The page is a single self-contained file written into `fixtures/`, which is
gitignored, because it embeds thumbnails of real photographs of real people. It
never goes near a browser that isn't this machine's.

    python3 tools/make_review_page.py && open fixtures/review.html
"""

from __future__ import annotations

import base64
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
LABELS = FIXTURES / "labels" / "labels.json"
INBOX = FIXTURES / "inbox"
THUMBS = FIXTURES / ".review-thumbs"
OUTPUT = FIXTURES / "review.html"

THUMB_PX = 420

# Framing that actually shows an outfit. A face-filling selfie and a figure at
# the far end of a beach are both rejected by the scan on their own merits, so
# asking about them would spend the reviewer's attention where no answer changes
# anything.
BODY_FRAMED = {"full_body", "three_quarter", "upper_body"}


def thumbnail(photo: dict) -> str | None:
    """A data: URI for the photo, generated once and cached on disk."""
    source = INBOX / photo["bucket"] / f"{photo['id']}.jpg"
    if not source.exists():
        return None

    cached = THUMBS / f"{photo['id']}.jpg"
    if not cached.exists():
        THUMBS.mkdir(exist_ok=True)
        subprocess.run(
            ["sips", "-Z", str(THUMB_PX), str(source), "--out", str(cached)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return "data:image/jpeg;base64," + base64.b64encode(cached.read_bytes()).decode()


def sections(photos: list[dict]) -> list[dict]:
    """The four questions, in the order they matter.

    Section one is the one that counts. `worth extracting` is defined as
    `aarish=yes AND outfitValue in (high, medium)`, and that set is the target
    every measurement is scored against.
    """
    by_id = {p["id"]: p for p in photos}

    def pick(predicate) -> list[dict]:
        return [p for p in photos if predicate(p)]

    keep = pick(lambda p: p["aarish"] == "yes" and p["outfitValue"] in ("high", "medium"))

    # Clearly the owner, clearly framed, and I still called them not worth it.
    # These are the judgement calls; the rest of the `low` pile is selfies and
    # distant figures that no answer here would rescue.
    drop = pick(
        lambda p: p["aarish"] == "yes"
        and p["outfitValue"] == "low"
        and p["shot"] in BODY_FRAMED
    )

    # Only the ones whose answer could move a photo into the target. The other
    # 30-odd are distant or valueless and stay out either way.
    unsure = pick(
        lambda p: p["aarish"] == "unsure"
        and (p["outfitValue"] in ("high", "medium") or p["shot"] in BODY_FRAMED)
    )

    seed = sorted(
        (
            {"id": path.stem, "bucket": "seed", "shot": "", "outfitValue": "", "garments": []}
            for path in (INBOX / "seed").glob("*.jpg")
        ),
        key=lambda p: p["id"],
    )

    return [
        {
            "key": "keep",
            "title": "I marked these worth extracting from",
            "ask": "Click any you would <b>not</b> want a garment pulled out of.",
            "note": "This set is the target every measurement is scored against. "
            "If it is wrong, everything downstream is tuned to the wrong goal.",
            "flagMeans": "not worth it",
            "photos": keep,
        },
        {
            "key": "drop",
            "title": "I marked these not worth it — but they are clearly you, and well framed",
            "ask": "Click any that <b>are</b> worth extracting from after all.",
            "note": "These are the genuine judgement calls at the boundary.",
            "flagMeans": "worth it",
            "photos": drop,
        },
        {
            "key": "unsure",
            "title": "I could not tell whether this is you",
            "ask": "Click the ones that <b>are</b> you.",
            "note": "",
            "flagMeans": "is you",
            "photos": unsure,
        },
        {
            "key": "seed",
            "title": "Identity reference photos",
            "ask": "Click any that are <b>not</b> a clear, well-lit photo of your face.",
            "note": "Face matching is calibrated entirely from these. "
            "A weak reference quietly degrades every identity decision in the app.",
            "flagMeans": "bad reference",
            "photos": seed,
        },
    ]


# Things that turn up in the labels and may or may not belong in a wardrobe.
# A product question, not a labelling one, and the answer changes what the
# extraction step is even trying to produce.
TAXONOMY = [
    ("helmet", "Ski / bike helmets", "appears in 14 photos"),
    ("goggles", "Ski goggles", "13 photos"),
    ("sunglasses", "Sunglasses", "26 photos"),
    ("bag", "Bags and backpacks", ""),
    ("watch", "Watches and jewellery", ""),
    ("swim", "Swimwear", ""),
]


def build() -> int:
    if not LABELS.exists():
        print(f"No labels at {LABELS}", file=sys.stderr)
        return 1
    if not shutil.which("sips"):
        print("sips not found — this needs macOS", file=sys.stderr)
        return 1

    photos = json.loads(LABELS.read_text())
    built = []
    total = 0

    for section in sections(photos):
        items = []
        for photo in section["photos"]:
            uri = thumbnail(photo)
            if uri is None:
                continue
            items.append(
                {
                    "id": photo["id"],
                    "src": uri,
                    "meta": " · ".join(filter(None, [photo["shot"], photo["outfitValue"]])),
                    "garments": ", ".join(photo.get("garments", [])),
                }
            )
        total += len(items)
        built.append({**section, "photos": items})
        print(f"  {section['key']:8} {len(items):4} photos")

    payload = json.dumps(
        {"sections": built, "taxonomy": [{"key": k, "label": t, "hint": h} for k, t, h in TAXONOMY]}
    )
    OUTPUT.write_text(TEMPLATE.replace("__DATA__", payload))
    size = OUTPUT.stat().st_size / 1_000_000
    print(f"\n{OUTPUT}  ({total} photos, {size:.1f} MB)")
    return 0


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Forme — label review</title>
<style>
  :root {
    --bg: #12100e; --panel: #1c1917; --line: #332e2a;
    --ink: #f2ede7; --muted: #a19a92; --flag: #8c2f39; --ok: #4f7a52;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg:#faf7f2; --panel:#fff; --line:#e4ded4; --ink:#1c1917; --muted:#6d655c; }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.5 ui-sans-serif, -apple-system, system-ui, sans-serif;
    padding-bottom: 96px;
  }
  header { padding: 40px 24px 8px; max-width: 1100px; margin: 0 auto; }
  h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -0.02em; }
  .lede { color: var(--muted); max-width: 62ch; margin: 0; }
  section { max-width: 1100px; margin: 0 auto; padding: 28px 24px 8px; }
  h2 { font-size: 17px; margin: 0 0 4px; letter-spacing: -0.01em; }
  .ask { margin: 0 0 4px; }
  .note { color: var(--muted); font-size: 13px; margin: 0 0 16px; max-width: 62ch; }
  .count { color: var(--muted); font-weight: 400; font-size: 14px; }
  .grid {
    display: grid; gap: 10px;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  }
  figure {
    margin: 0; position: relative; cursor: pointer; border-radius: 10px;
    overflow: hidden; background: var(--panel); border: 2px solid transparent;
    transition: border-color .12s, transform .12s;
  }
  figure:hover { transform: translateY(-2px); }
  figure img { display: block; width: 100%; aspect-ratio: 3/4; object-fit: cover; }
  figure.flagged { border-color: var(--flag); }
  figure.flagged img { opacity: .4; }
  .tick {
    position: absolute; inset: 0; display: none; place-items: center;
    font-size: 34px; color: var(--flag); font-weight: 700;
  }
  figure.flagged .tick { display: grid; }
  figcaption {
    position: absolute; left: 0; right: 0; bottom: 0; padding: 14px 8px 5px;
    font-size: 10px; color: #fff; line-height: 1.35;
    background: linear-gradient(transparent, rgba(0,0,0,.85));
  }
  .taxonomy { display: grid; gap: 8px; max-width: 620px; }
  .tax-row {
    display: flex; align-items: center; gap: 14px; padding: 12px 16px;
    background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
  }
  .tax-row .label { flex: 1; }
  .tax-row .hint { color: var(--muted); font-size: 12px; }
  .toggle {
    border: 1px solid var(--line); background: transparent; color: var(--muted);
    border-radius: 999px; padding: 5px 16px; cursor: pointer; font: inherit;
    font-size: 13px; min-width: 74px;
  }
  .toggle.yes { background: var(--ok); border-color: var(--ok); color: #fff; }
  .toggle.no  { background: var(--flag); border-color: var(--flag); color: #fff; }
  footer {
    position: fixed; bottom: 0; left: 0; right: 0; padding: 14px 24px;
    background: var(--panel); border-top: 1px solid var(--line);
    display: flex; align-items: center; gap: 18px; justify-content: center;
  }
  .status { color: var(--muted); font-size: 14px; }
  button.save {
    background: var(--ink); color: var(--bg); border: 0; border-radius: 999px;
    padding: 11px 26px; font: inherit; font-weight: 600; cursor: pointer;
  }
  button.save:disabled { opacity: .45; cursor: default; }
</style>
</head>
<body>

<header>
  <h1>Label review</h1>
  <p class="lede">
    I labelled 490 photos and need to know where I got it wrong. Click only the
    ones you disagree with — everything you leave alone counts as agreement.
    Roughly four minutes. Answers save as you go.
  </p>
</header>

<main id="main"></main>

<footer>
  <span class="status" id="status"></span>
  <button class="save" id="save">Download answers</button>
</footer>

<script>
const DATA = __DATA__;
const KEY = "forme-review-v1";
const answers = JSON.parse(localStorage.getItem(KEY) || '{"flags":{},"taxonomy":{}}');

function persist() {
  localStorage.setItem(KEY, JSON.stringify(answers));
  const n = Object.values(answers.flags).filter(Boolean).length;
  const t = Object.keys(answers.taxonomy).length;
  document.getElementById("status").textContent =
    `${n} correction${n === 1 ? "" : "s"} · ${t}/${DATA.taxonomy.length} taxonomy answered`;
}

const main = document.getElementById("main");

for (const section of DATA.sections) {
  if (!section.photos.length) continue;
  const el = document.createElement("section");
  el.innerHTML = `
    <h2>${section.title} <span class="count">${section.photos.length}</span></h2>
    <p class="ask">${section.ask}</p>
    ${section.note ? `<p class="note">${section.note}</p>` : ""}
    <div class="grid"></div>`;
  const grid = el.querySelector(".grid");

  for (const photo of section.photos) {
    const key = `${section.key}:${photo.id}`;
    const fig = document.createElement("figure");
    fig.className = answers.flags[key] ? "flagged" : "";
    fig.innerHTML = `
      <img loading="lazy" src="${photo.src}" alt="">
      <div class="tick">✕</div>
      <figcaption>${photo.id}${photo.meta ? " · " + photo.meta : ""}${
        photo.garments ? "<br>" + photo.garments : ""}</figcaption>`;
    fig.onclick = () => {
      answers.flags[key] = !answers.flags[key];
      fig.classList.toggle("flagged", answers.flags[key]);
      persist();
    };
    grid.appendChild(fig);
  }
  main.appendChild(el);
}

const tax = document.createElement("section");
tax.innerHTML = `
  <h2>Does this belong in a wardrobe?</h2>
  <p class="ask">These turn up in the labels. Your call decides whether the scan
     should ever try to pull one out.</p>
  <div class="taxonomy"></div>`;
const taxBox = tax.querySelector(".taxonomy");

for (const item of DATA.taxonomy) {
  const row = document.createElement("div");
  row.className = "tax-row";
  row.innerHTML = `
    <span class="label">${item.label}${item.hint ? ` <span class="hint">— ${item.hint}</span>` : ""}</span>
    <button class="toggle" data-v="yes">Yes</button>
    <button class="toggle" data-v="no">No</button>`;
  for (const button of row.querySelectorAll(".toggle")) {
    const value = button.dataset.v;
    const paint = () => {
      button.className = "toggle" + (answers.taxonomy[item.key] === value ? " " + value : "");
    };
    paint();
    button.onclick = () => {
      answers.taxonomy[item.key] = value;
      for (const sibling of row.querySelectorAll(".toggle")) {
        sibling.className = "toggle" +
          (answers.taxonomy[item.key] === sibling.dataset.v ? " " + sibling.dataset.v : "");
      }
      persist();
    };
  }
  taxBox.appendChild(row);
}
main.appendChild(tax);

document.getElementById("save").onclick = () => {
  const out = { flags: {}, taxonomy: answers.taxonomy };
  for (const [key, on] of Object.entries(answers.flags)) if (on) out.flags[key] = true;
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(out, null, 2)], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "forme-review.json";
  link.click();
  URL.revokeObjectURL(url);
};

persist();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    raise SystemExit(build())
