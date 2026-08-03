#!/usr/bin/env python3
"""Build the labelling tool, and migrate the old labels into the new schema.

The schema records observations, never judgements — see docs/PIPELINE.md. The
test for whether a field belongs: would the answer change if we moved a
threshold? If yes it is policy, not truth.

That test is also the migration rule. Everything the old labels recorded about
what is *true* of a photo carries over and the human only confirms it. The one
field that recorded a decision — `outfitValue`, a single scalar bundling torso
visibility, sharpness, occlusion and near-duplication — is dropped outright.
It cannot be corrected into something useful, because when it said `low` it
could not say which of the four it meant.

Five passes, one per gate in the pipeline, so the tool and the code answer the
same questions in the same order. Everything is pre-filled and the human is
correcting, not creating.

    python3 tools/build_label_tool.py && open fixtures/label.html
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
OLD_LABELS = FIXTURES / "labels" / "labels.json"
INBOX = FIXTURES / "inbox"
THUMBS = FIXTURES / ".thumbs"
OUTPUT = FIXTURES / "label.html"

GRID_PX = 200

# Body regions, coarse enough to label reliably from a glance and fine enough
# for the framing gate to be a pure function over them.
REGIONS = ["head", "torso", "hips", "legs", "feet"]

REGIONS_BY_SHOT = {
    "full_body": ["head", "torso", "hips", "legs", "feet"],
    "three_quarter": ["head", "torso", "hips", "legs"],
    "upper_body": ["head", "torso"],
    "face_closeup": ["head"],
    "back_turned": ["torso", "hips"],
    "partial_crop": ["torso"],
    "distant": ["head", "torso", "hips", "legs", "feet"],
}

CATEGORIES = ["top", "bottom", "one-piece", "outer", "shoes", "headwear", "accessory"]

# Nouns that decide a garment's category, longest match first so
# "long-sleeve shirt" does not match on "shirt" before "sweater" is considered.
CATEGORY_WORDS = [
    (["helmet", "goggles", "beanie", "cap", "hat"], "headwear"),
    (["sneaker", "shoe", "boot", "sandal", "slide", "loafer"], "shoes"),
    (["jacket", "coat", "blazer", "parka", "windbreaker"], "outer"),
    (["pants", "trouser", "jean", "short", "chino", "skirt"], "bottom"),
    (["dress", "suit", "jumpsuit"], "one-piece"),
    (["backpack", "bag", "sunglasses", "watch", "belt", "scarf"], "accessory"),
    (["sweater", "hoodie", "shirt", "t-shirt", "tee", "top", "long-sleeve", "knit", "half-zip"], "top"),
]


def category_for(name: str) -> str:
    lowered = name.lower()
    for words, category in CATEGORY_WORDS:
        if any(word in lowered for word in words):
            return category
    return "top"


def thumbnail(photo_id: str, bucket: str, size: int) -> str | None:
    source = INBOX / bucket / f"{photo_id}.jpg"
    if not source.exists():
        return None

    cached = THUMBS / f"{photo_id}-{size}.jpg"
    if not cached.exists():
        THUMBS.mkdir(exist_ok=True)
        subprocess.run(
            ["sips", "-Z", str(size), str(source), "--out", str(cached)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return "data:image/jpeg;base64," + base64.b64encode(cached.read_bytes()).decode()


def migrate(old: dict) -> dict:
    """Old label to new observations. Judgements are dropped, not translated."""
    issues = set(old.get("issues", []))
    shot = old["shot"]

    sharpness = "blurry" if "blurry" in issues else "soft" if "low_resolution" in issues else "sharp"
    exposure = "dark" if "dark" in issues else "ok"

    occlusion = "none"
    if "occluded" in issues:
        occlusion = "partial"
    elif "crowd" in issues:
        occlusion = "partial"

    facing = "away" if shot == "back_turned" or "back_turned" in issues else "front"

    return {
        "id": old["id"],
        "bucket": old["bucket"],
        "captured": old["captured"],
        "peopleCount": old["people"],
        # A photograph of the world, as opposed to a screenshot, a receipt, a
        # graphic, or a photo of a screen.
        "isPhotograph": shot != "screenshot_or_graphic" and "screenshot_or_graphic" not in issues,
        "identity": {"yes": "owner", "no": "other", "unsure": "unknown"}[old["aarish"]],
        "regions": REGIONS_BY_SHOT.get(shot, []),
        "sharpness": sharpness,
        "exposure": exposure,
        "occlusion": occlusion,
        "facing": facing,
        # Free text, kept only to seed the registry pass. It is never ground
        # truth: "black tee" and "dark tee" split one garment in two, and
        # consistency across 38 appearances is unverifiable by construction.
        "garments": old.get("garments", []),
    }


def registry(photos: list[dict]) -> list[dict]:
    """Proposed garments, one per distinct description, commonest first.

    Deliberately conservative — one row per string rather than clustering by
    colour and category. Merging two rows the human can see side by side is a
    glance; splitting one row into two is real work, and an automatic cluster
    would generate that work at exactly the frequencies where it hurts most.
    """
    seen: dict[str, list[str]] = {}
    for photo in photos:
        for name in photo["garments"]:
            seen.setdefault(name, []).append(photo["id"])

    rows = sorted(seen.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    return [
        {
            "id": f"G{index + 1:03d}",
            "name": name,
            "category": category_for(name),
            "photos": photo_ids,
        }
        for index, (name, photo_ids) in enumerate(rows)
    ]


def build() -> int:
    if not OLD_LABELS.exists():
        print(f"No labels at {OLD_LABELS}", file=sys.stderr)
        return 1
    if not shutil.which("sips"):
        print("sips not found — this needs macOS", file=sys.stderr)
        return 1

    photos = [migrate(old) for old in json.loads(OLD_LABELS.read_text())]

    print("Rendering thumbnails (first run only)…")
    # Thumbnails are kept in their own map rather than on the photo records. The
    # records round-trip through localStorage on every click, and a 5 MB quota
    # does not survive 490 base64 images riding along with them.
    thumbs = {}
    for photo in photos:
        uri = thumbnail(photo["id"], photo["bucket"], GRID_PX)
        if uri:
            thumbs[photo["id"]] = uri
    photos = [photo for photo in photos if photo["id"] in thumbs]

    garments = registry(photos)

    payload = json.dumps(
        {
            "photos": [{k: v for k, v in p.items() if k != "garments"} for p in photos],
            "garments": garments,
            "thumbs": thumbs,
            "regions": REGIONS,
            "categories": CATEGORIES,
        }
    )
    OUTPUT.write_text(TEMPLATE.replace("__DATA__", payload))

    owner = sum(1 for p in photos if p["identity"] == "owner")
    print(f"\n  {len(photos)} photos · {owner} pre-marked as you · {len(garments)} proposed garments")
    print(f"  {OUTPUT}  ({OUTPUT.stat().st_size / 1_000_000:.1f} MB)")
    return 0


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Forme — labelling</title>
<style>
  :root {
    --bg:#12100e; --panel:#1c1917; --line:#332e2a; --ink:#f2ede7; --muted:#a19a92;
    --you:#4f7a52; --other:#8c2f39; --unknown:#7a6a4f; --accent:#c96f4a;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg:#faf7f2; --panel:#fff; --line:#e4ded4; --ink:#1c1917; --muted:#6d655c; }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); padding-bottom:88px;
         font:15px/1.5 ui-sans-serif,-apple-system,system-ui,sans-serif; }
  .wrap { max-width:1180px; margin:0 auto; padding:0 24px; }
  header { padding:36px 0 4px; }
  h1 { font-size:24px; margin:0 0 4px; letter-spacing:-.02em; }
  .lede { color:var(--muted); max-width:64ch; margin:0; }
  nav { display:flex; gap:6px; flex-wrap:wrap; margin:22px 0 6px; }
  nav button {
    background:transparent; border:1px solid var(--line); color:var(--muted);
    border-radius:999px; padding:7px 15px; font:inherit; font-size:13px; cursor:pointer;
  }
  nav button.on { background:var(--ink); color:var(--bg); border-color:var(--ink); }
  h2 { font-size:18px; margin:22px 0 4px; letter-spacing:-.01em; }
  .ask { margin:0 0 4px; }
  .note { color:var(--muted); font-size:13px; margin:0 0 18px; max-width:66ch; }
  .grid { display:grid; gap:9px; grid-template-columns:repeat(auto-fill,minmax(132px,1fr)); }
  figure { margin:0; position:relative; cursor:pointer; border-radius:9px; overflow:hidden;
           background:var(--panel); border:2px solid transparent; }
  figure img { display:block; width:100%; aspect-ratio:3/4; object-fit:cover; }
  figure.off img { opacity:.28; }
  figure .badge {
    position:absolute; top:5px; left:5px; padding:2px 7px; border-radius:999px;
    font-size:10px; font-weight:700; color:#fff; letter-spacing:.02em;
  }
  figure.owner   { border-color:var(--you); }   figure.owner   .badge { background:var(--you); }
  figure.other   { border-color:var(--other); } figure.other   .badge { background:var(--other); }
  figure.unknown { border-color:var(--unknown); } figure.unknown .badge { background:var(--unknown); }
  figure.none    { opacity:.45; }
  figcaption { position:absolute; left:0; right:0; bottom:0; padding:13px 7px 4px; font-size:10px;
               color:#fff; background:linear-gradient(transparent,rgba(0,0,0,.85)); }
  .row { background:var(--panel); border:1px solid var(--line); border-radius:12px;
         padding:14px 16px; margin-bottom:10px; }
  .row-head { display:flex; gap:10px; align-items:center; margin-bottom:10px; flex-wrap:wrap; }
  .row-head input, .row-head select {
    background:var(--bg); color:var(--ink); border:1px solid var(--line);
    border-radius:8px; padding:7px 11px; font:inherit; font-size:14px;
  }
  .row-head input { flex:1; min-width:200px; }
  .row-head .n { color:var(--muted); font-size:13px; }
  .strip { display:flex; gap:7px; flex-wrap:wrap; }
  .strip figure { width:88px; border-width:3px; }
  .strip figure.v1 { border-color:var(--accent); }
  .strip figure.v2 { border-color:#4a7fc9; }
  .strip figure.vx { border-color:var(--other); }
  .strip .vlabel { position:absolute; top:3px; right:4px; font-size:11px; font-weight:800; color:#fff;
                   text-shadow:0 1px 3px #000; }
  footer { position:fixed; bottom:0; left:0; right:0; padding:13px 24px; background:var(--panel);
           border-top:1px solid var(--line); display:flex; gap:16px; align-items:center;
           justify-content:center; }
  .status { color:var(--muted); font-size:14px; }
  button.save { background:var(--ink); color:var(--bg); border:0; border-radius:999px;
                padding:11px 26px; font:inherit; font-weight:600; cursor:pointer; }
  kbd { background:var(--panel); border:1px solid var(--line); border-radius:5px;
        padding:1px 6px; font-size:12px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Labelling</h1>
    <p class="lede">
      Five passes, one per gate in the pipeline. Everything is pre-filled from the
      old labels — you are correcting, not starting over. Click a photo to change
      it. Progress saves automatically.
    </p>
    <nav id="nav"></nav>
  </header>
  <main id="main"></main>
</div>
<footer>
  <span class="status" id="status"></span>
  <button class="save" id="save">Download labels</button>
</footer>

<script>
const DATA = __DATA__;
const KEY = "forme-labels-v2";
const saved = JSON.parse(localStorage.getItem(KEY) || "{}");

// The photo records are the working state: pre-filled, edited in place, exported
// whole. Storing full values rather than a diff means the export is readable on
// its own and never needs the old labels to interpret it.
const THUMBS = DATA.thumbs;
const photos = DATA.photos.map(p => ({ ...p, ...(saved.photos?.[p.id] || {}) }));
const byId = Object.fromEntries(photos.map(p => [p.id, p]));
const garments = DATA.garments.map(g => ({
  ...g, ...(saved.garments?.[g.id] || {}),
  variants: (saved.garments?.[g.id]?.variants) || {},
}));

function persist() {
  localStorage.setItem(KEY, JSON.stringify({
    photos: Object.fromEntries(photos.map(p => [p.id, p])),
    garments: Object.fromEntries(garments.map(g => [g.id, g])),
  }));
  const owner = photos.filter(p => p.identity === "owner").length;
  const named = garments.filter(g => g.name).length;
  document.getElementById("status").textContent =
    `${owner} photos of you · ${garments.length} garments · ${named} named`;
}

function tile(photo, { badge, cls, caption } = {}) {
  const fig = document.createElement("figure");
  if (cls) fig.className = cls;
  fig.innerHTML = `<img loading="lazy" src="${THUMBS[photo.id]}" alt="">` +
    (badge ? `<div class="badge">${badge}</div>` : "") +
    `<figcaption>${caption ?? photo.id}</figcaption>`;
  return fig;
}

function section(title, ask, note) {
  const el = document.createElement("section");
  el.innerHTML = `<h2>${title}</h2><p class="ask">${ask}</p>` +
    (note ? `<p class="note">${note}</p>` : "");
  return el;
}

// ---- Pass 1: is this a photograph at all? --------------------------------
function passPhotograph(main) {
  const el = section("1 · Is this a photograph?",
    "Click any that are a <b>screenshot, receipt, graphic, or photo of a screen</b>.",
    "The cheapest gate in the pipeline, and the only one that runs on metadata alone. " +
    "Dimmed tiles are already marked as not a photograph.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of photos) {
    const fig = tile(photo, { cls: photo.isPhotograph ? "" : "off" });
    fig.onclick = () => {
      photo.isPhotograph = !photo.isPhotograph;
      fig.className = photo.isPhotograph ? "" : "off";
      persist();
    };
    grid.appendChild(fig);
  }
  el.appendChild(grid);
  main.appendChild(el);
}

// ---- Pass 2: whose body is this? ----------------------------------------
const IDENTITY_CYCLE = ["owner", "other", "unknown", "none"];
const IDENTITY_LABEL = { owner: "you", other: "someone else", unknown: "not sure", none: "no people" };

function passIdentity(main) {
  const el = section("2 · Who is in this photo?",
    "Click to cycle: <b>you → someone else → not sure → no people</b>.",
    "The gate everything else multiplies through. Note this is still a per-photo " +
    "answer; when a photo has two people it will become per-body once person " +
    "boxes exist, and 'not sure' is a real answer that stays a third state — " +
    "never quietly promoted to 'you'.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of photos.filter(p => p.isPhotograph)) {
    if (photo.peopleCount === 0 && !photo.identity) photo.identity = "none";
    const fig = tile(photo, {
      cls: photo.identity, badge: IDENTITY_LABEL[photo.identity],
    });
    fig.onclick = () => {
      const next = (IDENTITY_CYCLE.indexOf(photo.identity) + 1) % IDENTITY_CYCLE.length;
      photo.identity = IDENTITY_CYCLE[next];
      fig.className = photo.identity;
      fig.querySelector(".badge").textContent = IDENTITY_LABEL[photo.identity];
      persist();
    };
    grid.appendChild(fig);
  }
  el.appendChild(grid);
  main.appendChild(el);
}

// ---- Pass 3: can a garment be read off this body? ------------------------
function passFraming(main) {
  const el = section("3 · Can you see what they are wearing?",
    "Click any where you <b>cannot</b> read a garment — face too close, body cut off, turned away.",
    "Recorded as which parts of the body are visible, not as a verdict. That is " +
    "the whole point: the gate becomes a function over these, so it can be " +
    "re-tuned forever without anyone re-labelling anything.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of photos.filter(p => p.isPhotograph && p.identity === "owner")) {
    const readable = () => photo.regions.includes("torso");
    const fig = tile(photo, {
      cls: readable() ? "" : "off",
      caption: `${photo.id} · ${photo.regions.join(" ") || "nothing"}`,
    });
    fig.onclick = () => {
      photo.regions = readable() ? photo.regions.filter(r => r !== "torso" && r !== "hips")
                                 : [...new Set([...photo.regions, "torso", "hips"])];
      fig.className = readable() ? "" : "off";
      fig.querySelector("figcaption").textContent =
        `${photo.id} · ${photo.regions.join(" ") || "nothing"}`;
      persist();
    };
    grid.appendChild(fig);
  }
  el.appendChild(grid);
  main.appendChild(el);
}

// ---- Pass 4: is the image good enough? ----------------------------------
function passQuality(main) {
  const el = section("4 · Is the image good enough?",
    "Click any too <b>blurry, dark, or obscured</b> to get a clean garment out of.",
    "Kept separate from pass 3 on purpose. Bundling 'can I see it' with 'is it " +
    "sharp' into one score is exactly what made the last schema unfalsifiable — " +
    "when a photo failed, nothing could say which of the two it was.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of photos.filter(p => p.isPhotograph && p.identity === "owner")) {
    const bad = () => photo.sharpness !== "sharp" || photo.exposure !== "ok";
    const fig = tile(photo, {
      cls: bad() ? "off" : "",
      caption: `${photo.id} · ${photo.sharpness} · ${photo.exposure}`,
    });
    fig.onclick = () => {
      if (bad()) { photo.sharpness = "sharp"; photo.exposure = "ok"; }
      else { photo.sharpness = "blurry"; }
      fig.className = bad() ? "off" : "";
      fig.querySelector("figcaption").textContent =
        `${photo.id} · ${photo.sharpness} · ${photo.exposure}`;
      persist();
    };
    grid.appendChild(fig);
  }
  el.appendChild(grid);
  main.appendChild(el);
}

// ---- Pass 5: the garment registry ---------------------------------------
const VARIANTS = ["v1", "v2", "vx"];
const VARIANT_LABEL = { v1: "", v2: "2", vx: "✕" };

function passRegistry(main) {
  const el = section("5 · Your actual garments",
    "One row per garment. <b>Rename freely</b> — two rows with the same name become one item. " +
    "Click a photo to mark it a <b>different</b> garment (2) or <b>not this garment</b> (✕).",
    "This is the only label no algorithm can supply, and the one the whole " +
    "wardrobe depends on: 38 photos of your white t-shirt must become one entry, " +
    "not 38. The descriptions below are my guesses and several are certainly " +
    "two garments merged — splitting those is the work.");

  for (const garment of garments) {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `
      <div class="row-head">
        <input value="${garment.name.replace(/"/g, "&quot;")}" placeholder="name">
        <select>${DATA.categories.map(c =>
          `<option ${c === garment.category ? "selected" : ""}>${c}</option>`).join("")}</select>
        <span class="n">${garment.photos.length} photo${garment.photos.length === 1 ? "" : "s"}</span>
      </div>
      <div class="strip"></div>`;

    row.querySelector("input").oninput = e => { garment.name = e.target.value; persist(); };
    row.querySelector("select").onchange = e => { garment.category = e.target.value; persist(); };

    const strip = row.querySelector(".strip");
    for (const photoId of garment.photos) {
      const photo = byId[photoId];
      if (!photo) continue;
      const state = () => garment.variants[photoId] || "v1";
      const fig = document.createElement("figure");
      fig.className = state();
      fig.innerHTML = `<img loading="lazy" src="${THUMBS[photoId]}" alt="">
                       <div class="vlabel">${VARIANT_LABEL[state()]}</div>`;
      fig.onclick = () => {
        const next = VARIANTS[(VARIANTS.indexOf(state()) + 1) % VARIANTS.length];
        garment.variants[photoId] = next;
        fig.className = next;
        fig.querySelector(".vlabel").textContent = VARIANT_LABEL[next];
        persist();
      };
      strip.appendChild(fig);
    }
    el.appendChild(row);
  }
  main.appendChild(el);
}

// ---- Shell ---------------------------------------------------------------
const PASSES = [
  ["Photograph?", passPhotograph],
  ["Who is here?", passIdentity],
  ["Outfit visible?", passFraming],
  ["Good enough?", passQuality],
  ["Garments", passRegistry],
];

const nav = document.getElementById("nav");
const main = document.getElementById("main");
let current = Number(localStorage.getItem(KEY + "-pass") || 0);

function show(index) {
  current = index;
  localStorage.setItem(KEY + "-pass", index);
  main.innerHTML = "";
  PASSES[index][1](main);
  for (const [i, button] of [...nav.children].entries()) {
    button.className = i === index ? "on" : "";
  }
  scrollTo(0, 0);
}

PASSES.forEach(([title], index) => {
  const button = document.createElement("button");
  button.textContent = `${index + 1}. ${title}`;
  button.onclick = () => show(index);
  nav.appendChild(button);
});

document.getElementById("save").onclick = () => {
  const out = {
    schema: 2,
    photos,
    garments: garments.map(({ photos: ids, variants, ...rest }) => ({
      ...rest,
      appearances: ids.filter(id => (variants[id] || "v1") !== "vx")
        .map(id => ({ photo: id, variant: variants[id] || "v1" })),
    })),
  };
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(out, null, 1)], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url; link.download = "forme-labels.json"; link.click();
  URL.revokeObjectURL(url);
};

show(current);
persist();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    raise SystemExit(build())
