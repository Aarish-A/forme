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

Three passes, in the order the pipeline runs them: can anyone's outfit be read
here, is that person you, and which of these are the same physical garment.
Those are the only questions a machine cannot answer, and everything is
pre-filled so the human is correcting rather than creating.

The order matters more than it looks. Asking "is this you" about a queue of
thirty-pixel strangers is a question with no useful answer either way, so
visibility runs first and identity only sees what survived it. A face is never
allowed to decide whether a person is present — only who they are.

Two gates are deliberately not asked about. Whether a file is a photograph is
`PHAsset` metadata plus Vision's utility flag, and whether it is sharp enough is
a measured scalar. Spending human attention on either would be waste, and worse,
a hand label for "sharp enough" would bake a threshold into the ground truth.

    python3 tools/build_label_tool.py && open fixtures/label.html
"""

from __future__ import annotations

import base64
import collections
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

    regions = REGIONS_BY_SHOT.get(shot, [])
    # Can a garment be read off anyone here? Checked in the pipeline's own
    # order, so `distant` loses before its region list is consulted — a figure
    # at the far end of a beach has a complete body and no readable outfit.
    if old["people"] == 0 or shot in ("no_person", "flatlay"):
        visibility = "none"
    elif shot in ("distant", "face_closeup", "back_turned"):
        visibility = "unreadable"
    elif "torso" in regions:
        visibility = "readable"
    else:
        visibility = "unreadable"

    return {
        "id": old["id"],
        "bucket": old["bucket"],
        "captured": old["captured"],
        "peopleCount": old["people"],
        # A photograph of the world, as opposed to a screenshot, a receipt, a
        # graphic, or a photo of a screen.
        "isPhotograph": shot != "screenshot_or_graphic" and "screenshot_or_graphic" not in issues,
        "identity": {"yes": "owner", "no": "other", "unsure": "unknown"}[old["aarish"]],
        "visibility": visibility,
        "regions": regions,
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

    counts = collections.Counter(p["visibility"] for p in photos if p["isPhotograph"])
    owner = sum(1 for p in photos if p["visibility"] == "readable" and p["identity"] == "owner")
    print(f"\n  {len(photos)} photos · {len(garments)} proposed garments")
    print("  " + " · ".join(f"{v} {k}" for k, v in counts.most_common()))
    print(f"  identity pass will ask about {counts['readable']} photos, {owner} pre-marked as you")
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
  figure.readable   { border-color:var(--you); }   figure.readable   .badge { background:var(--you); }
  figure.unreadable { border-color:var(--unknown); opacity:.7; }
  figure.unreadable .badge { background:var(--unknown); }
  figure.depicted   { border-color:var(--accent); } figure.depicted .badge { background:var(--accent); }
  figure.none       { border-color:var(--line); opacity:.4; }
  figure.none .badge { background:#555; }
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
      Three passes, in the order the pipeline runs them: can anyone's outfit be
      read here, is that person you, and which garments are the same physical
      item. Screenshots and image quality are measured rather than labelled, so
      they are not here. Everything is pre-filled — you are correcting, not
      starting over. Progress saves automatically.
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
  const readable = photos.filter(p => p.isPhotograph && p.visibility === "readable").length;
  const owner = photos.filter(p => p.visibility === "readable" && p.identity === "owner").length;
  document.getElementById("status").textContent =
    `${readable} readable · ${owner} of you · ${garments.length} garments`;
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

// ---- Pass 1: is there anyone here whose outfit we could read? -----------
//
// This runs first because the pipeline runs it first, and because asking
// "is this you" about a queue of 30-pixel strangers is a question with no
// useful answer in either direction.
//
// `depicted` is its own state and not a flavour of `none`. A face on a book
// cover, a poster, or a TV is exactly what a face detector fires on, and a
// depicted face can clear an identity threshold — at which point a book
// jacket's clothes enter someone's wardrobe. Guarding against that means
// requiring a person rectangle with the face inside it, and proving the guard
// works needs photos where the right answer is "a face, but nobody there".
const VISIBILITY_CYCLE = ["readable", "unreadable", "depicted", "none"];
const VISIBILITY_LABEL = {
  readable: "outfit visible",
  unreadable: "can't read it",
  depicted: "pictured, not real",
  none: "nobody",
};

function passVisibility(main) {
  const el = section("1 · Can you read an outfit off anyone here?",
    "Click to cycle: <b>outfit visible → can't read it → pictured, not real → nobody</b>.",
    "<b>Can't read it</b> covers too far away, turned away, or too occluded — " +
    "someone is there, but no garment could come out of it. " +
    "<b>Pictured, not real</b> is a face or body that is a photograph, poster, " +
    "book cover or screen: no person in the room at all. " +
    "Human-labelled on purpose — body pose is the thing being tested, so " +
    "letting pose answer this would score it against itself.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of photos.filter(p => p.isPhotograph)) {
    const fig = tile(photo, {
      cls: photo.visibility, badge: VISIBILITY_LABEL[photo.visibility],
    });
    fig.onclick = () => {
      const next = (VISIBILITY_CYCLE.indexOf(photo.visibility) + 1) % VISIBILITY_CYCLE.length;
      photo.visibility = VISIBILITY_CYCLE[next];
      fig.className = photo.visibility;
      fig.querySelector(".badge").textContent = VISIBILITY_LABEL[photo.visibility];
      persist();
    };
    grid.appendChild(fig);
  }
  el.appendChild(grid);
  main.appendChild(el);
}

// ---- Pass 2: whose body is this? ----------------------------------------
const IDENTITY_CYCLE = ["owner", "other", "unknown"];
const IDENTITY_LABEL = { owner: "you", other: "someone else", unknown: "not sure" };

function passIdentity(main) {
  const readable = photos.filter(p => p.isPhotograph && p.visibility === "readable");
  const el = section("2 · Is that you?",
    "Click to cycle: <b>you → someone else → not sure</b>.",
    `Only the ${readable.length} photos you marked readable — a face is never ` +
    "asked to decide whether a person is present, only who they are. " +
    "'Not sure' stays a third state and is never quietly promoted to 'you': " +
    "reading absence of evidence as ownership is what put a stranger's " +
    "photoshoot one tap from this wardrobe.");
  const grid = document.createElement("div");
  grid.className = "grid";
  for (const photo of readable) {
    if (photo.identity === "none") photo.identity = "unknown";
    const fig = tile(photo, { cls: photo.identity, badge: IDENTITY_LABEL[photo.identity] });
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

// ---- Pass 5: the garment registry ---------------------------------------
const VARIANTS = ["v1", "v2", "vx"];
const VARIANT_LABEL = { v1: "", v2: "2", vx: "✕" };

function passRegistry(main) {
  const el = section("3 · Your actual garments",
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
// Two gates are deliberately absent. "Is this a photograph" comes from
// PHAsset metadata and Vision's utility flag; "is it sharp enough" is a
// measured scalar. Neither is a question a human should be asked, and asking
// one anyway is how a label ends up encoding a threshold.
const PASSES = [
  ["Anyone readable?", passVisibility],
  ["Is that you?", passIdentity],
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
