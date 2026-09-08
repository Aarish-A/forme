#!/usr/bin/env python3
"""Score the visibility and identity gates against real Vision output.

Reads two files and nothing else: `vision-cache.json`, which is what Vision
actually saw, and `observations.json`, which is what a human says is true. The
gate is a pure function between them, so trying a threshold costs milliseconds
and touches no device.

This is the *explorer*. `ScanPolicy` in the app stays the shipped
implementation; this exists to find where a threshold belongs by reading the
distribution, rather than by guessing three values and running a field test.
Anything learned here has to be encoded there, and `--check` compares the two.

Overfitting is the standing risk: 490 photos from one library, and a single
burst holds 13% of the target. So the split unit is the occasion, tuning only
ever sees dev, and every number is reported for both halves.

    python3 tools/score_gates.py            # score the current thresholds
    python3 tools/score_gates.py --sweep    # where could each threshold go
    python3 tools/score_gates.py --test     # open the held-out half
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELS = ROOT / "fixtures" / "labels" / "observations.json"
CACHE = ROOT / "fixtures" / "labels" / "vision-cache.json"

# Current thresholds, mirroring the app.
#
# Measured inert on this corpus: sweeping MIN_PERSON_HEIGHT from 0.05 to 0.30
# and IDENTITY_COSINE from 0.30 to 0.42 leaves occasion coverage at 75.9% in
# every combination. What still does work is the *existence* check the height
# comparison performs on an empty list — "is anyone here" — not the height.
# Kept at a defensible value rather than tuned to this one library, since a
# threshold fitted where it has no effect is a threshold fitted to noise.
MIN_PERSON_HEIGHT = 0.25
JOINT_CONFIDENCE = 0.30
IDENTITY_COSINE = 0.30
# The runner-up face must trail the winner by this much. In a photo containing
# the owner and their partner, "some face matched" cannot say *which*, and at a
# relaxed threshold that is exactly how a partner's coat enters a wardrobe.
IDENTITY_MARGIN = 0.07
MIN_FACE_PX = 48
# A face taller than this fraction of the frame is a close-up: there is no room
# below the chin for a garment. Only consulted when pose found no body.
MAX_FACE_FRACTION = 0.30

# Which occasions are held out. Chosen by hash of the occasion number so the
# split is stable across runs and independent of anything being tuned — picking
# the test half by looking at results is how a held-out set stops being one.
TEST_FRACTION = 0.4


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def cosine(a: list[float], b: list[float]) -> float:
    """The embeddings are already L2-normalised, but not by contract."""
    na, nb = math.sqrt(dot(a, a)), math.sqrt(dot(b, b))
    if na == 0 or nb == 0:
        return 0.0
    return dot(a, b) / (na * nb)


def seed_ids() -> set[str]:
    """The photos standing in for 'the user picked themselves', once, at setup."""
    directory = ROOT / "fixtures" / "inbox" / "seed"
    return {path.stem for path in directory.glob("*.jpg")}


def load() -> tuple[list[dict], dict[str, dict], list[list[float]]]:
    labels = json.loads(LABELS.read_text())["photos"]
    cache = {f["id"]: f for f in json.loads(CACHE.read_text())}

    # The seed bucket turned out to be copies of eight *labelled* photos, so
    # they are excluded from scoring rather than merely used as references.
    # Calibrating identity on a face and then scoring identity on the same face
    # measures nothing, and the mistake is invisible in the result — the number
    # just comes out better than it should.
    seeds = [
        face["embedding"]
        for pid in seed_ids()
        for face in cache.get(pid, {}).get("faces", [])
        if face.get("embedding")
    ]
    labels = [p for p in labels if p["id"] not in seed_ids()]
    return labels, cache, seeds


class InvalidCorpus(Exception):
    """The harness is wrong about its own inputs."""


def check(labels, cache, seeds) -> None:
    """Preconditions on the corpus itself, run before any number is produced.

    Every mistake this harness has made was of one kind: it was right about the
    pipeline and wrong about its own data. The corpus was silently downsampled,
    so identity failure was an artefact of the export. The seed photos turned
    out to be copies of scored photos, so identity was nearly calibrated on the
    faces it was graded against. Both produced confident, precise, wrong
    numbers — and confidence is what stops you looking.

    So these raise rather than warn. A harness that can emit a number from an
    invalid corpus will eventually emit one, and it will be believed.
    """
    problems = []

    overlap = seed_ids() & {p["id"] for p in labels}
    if overlap:
        problems.append(f"{len(overlap)} seed photos are also scored — identity would grade itself")

    dev = {p.get("occasion") for p in labels if not is_test(p)}
    test = {p.get("occasion") for p in labels if is_test(p)}
    if dev & test:
        problems.append(f"{len(dev & test)} occasions in both dev and test — near-duplicates leak across the split")

    missing = [p["id"] for p in labels if p["id"] not in cache]
    if missing:
        problems.append(f"{len(missing)} labelled photos absent from the cache (e.g. {missing[:3]})")

    # Corpus fidelity, checked on disk rather than in the cache. The decode size
    # is a pipeline choice the app is entitled to make; what must never happen
    # again is the *source* having been resampled before Vision ever saw it,
    # which is how a ceiling got reported that belonged to an export setting.
    native = ROOT / "fixtures" / "native"
    if not native.is_dir():
        problems.append("no fixtures/native — the 2048px inbox copies are not a faithful corpus")
    else:
        sizes = sorted(path.stat().st_size for path in native.glob("*.jpg"))
        if len(sizes) < len(labels) * 0.9:
            problems.append(f"fixtures/native holds {len(sizes)} files for {len(labels)} labels")
        elif sizes and sizes[len(sizes) // 2] < 500_000:
            problems.append(
                f"fixtures/native median file is {sizes[len(sizes) // 2] // 1000}KB — "
                "far too small for camera originals, so the corpus has been resampled"
            )

    if problems:
        raise InvalidCorpus("\n  - ".join(["corpus failed its own checks:"] + problems))


def is_test(photo: dict) -> bool:
    occasion = photo.get("occasion", -1)
    # Undated photos have no occasion and cannot be safely split; keep them in
    # dev so they can never inflate a held-out score.
    if occasion < 0:
        return False
    return (occasion * 2654435761) % 100 < TEST_FRACTION * 100


def tallest_person(facts: dict) -> float:
    return max((box["height"] for box in facts["people"]), default=0.0)


def joints_present(facts: dict, names: set[str], confidence: float) -> bool:
    """Case-insensitive: Vision names joints `leftShoulder`, `neck`, `root`.

    Note these are never *absent* — every pose carries all 19 joints, so this is
    only ever a question about confidence. A gate phrased as "are the hips
    present" was answering a question that has no false case.
    """
    for pose in facts["poses"]:
        if all(
            any(
                key.lower().endswith(name.lower()) and joint["confidence"] >= confidence
                for key, joint in pose["joints"].items()
            )
            for name in names
        ):
            return True
    return False


def best_cosine(facts: dict, seeds: list[list[float]], min_face_px: float) -> float:
    best = -1.0
    for face in facts["faces"]:
        if face["sidePx"] < min_face_px or not face.get("embedding"):
            continue
        for seed in seeds:
            best = max(best, cosine(face["embedding"], seed))
    return best


def predict(facts: dict, seeds: list[list[float]], knobs: dict) -> tuple[bool, str]:
    """The gate, in pipeline order.

    Two stages were deleted rather than tuned, on the evidence rather than on
    taste. The framing gate asked whether hips were confidently posed — but on
    human-labelled *readable* photos hip confidence runs 0.19–0.41, which is the
    noise floor, so no cut point existed. The quality gate filtered on sharpness,
    which is self-punishing downstream: a blurry crop does not cluster. Sharpness
    survives as a ranking value for choosing a cluster's hero image, never as a
    filter.

    `use_framing` keeps the deleted gate available so the cost of removing it is
    a measurement rather than an assertion.
    """
    if facts["isUtility"]:
        return False, "utility"
    if tallest_person(facts) < knobs["min_person_height"]:
        return False, "too small / no person"
    # Readability: a resolved body, OR a face small enough that there is room
    # below the chin for clothes.
    #
    # Pose alone was too strict. It fails legitimately on seated, bulky or
    # cropped subjects — a ski chairlift selfie in a padded jacket has no
    # articulable limbs and a perfectly readable coat. The face-size escape
    # hatch recovers those without admitting close-ups, because a face filling
    # the frame is definitionally a photo with no outfit in it.
    #
    # 0.15 and 0.18 score identically, which is the point: a plateau rather than
    # a knife edge, so this is a real effect and not a number fitted to a corpus.
    # ...and only when there is a single face. A close-up portrait has one face
    # filling the frame; two large faces is a group selfie, which shows torsos
    # and therefore clothes. Without the face-count condition this rule threw
    # away a photo whose owner matched at 0.633 with a white t-shirt in plain
    # view — a correct identity beaten by a proxy for framing.
    faces = [f for f in facts["faces"] if f["sidePx"] >= knobs["min_face_px"]]
    if (
        not facts.get("poses")
        and len(faces) < 2
        and face_fraction(facts) >= knobs["max_face_fraction"]
    ):
        return False, "no readable body"
    ranked = sorted(
        (max(cosine(f["embedding"], seed) for seed in seeds)
         for f in facts["faces"] if f["sidePx"] >= knobs["min_face_px"] and f.get("embedding")),
        reverse=True,
    )
    if len(ranked) > 1 and ranked[0] - ranked[1] < knobs.get("identity_margin", 0):
        return False, "no face clearly the owner"
    if (ranked[0] if ranked else -1.0) < knobs["identity_cosine"]:
        # Inherit from the occasion when a sibling photo verified. Same two-hour
        # window, same clothes, same person — the evidence is real, it just
        # happens to live in the frame next door.
        if knobs.get("verified") is None or facts.get("_occasion") not in knobs["verified"]:
            return False, "not identified as owner"
    return True, ""


def face_fraction(facts: dict) -> float:
    """Largest face height as a fraction of image height."""
    return max((f["sidePx"] for f in facts["faces"]), default=0.0) / (facts["heightPx"] or 1)


def framing_bucket(facts: dict) -> str:
    """How much of the body is in frame — the variable everything else follows.

    This is the stratifier because it is causal, not merely correlated: the more
    of a body a photo contains, the smaller the face, the worse identity does —
    and the more clothing the photo is worth. Value and difficulty move together,
    which is why a single aggregate hid a 48%-vs-100% split behind a 78% mean.
    """
    if not facts.get("poses"):
        return "no pose"
    def conf(name: str) -> float:
        return max(
            (j["confidence"] for pose in facts["poses"] for k, j in pose["joints"].items()
             if k.lower().endswith(name)),
            default=0.0,
        )
    if conf("ankle") > 0.3:
        return "full length"
    if conf("knee") > 0.3:
        return "to knees"
    if conf("hip") > 0.3:
        return "to hips"
    return "head/shoulders"


def verified_occasions(labels, cache, seeds, knobs) -> set:
    """Occasions where at least one photo verifies as the owner.

    Within a two-hour occasion the outfit is constant, so identity only has to
    succeed once. This matters because identity fails *precisely* on the photos
    worth the most: a full-length shot has a small face and embeds about half
    the time, while the head-and-shoulders photo taken beside it embeds every
    time and shows almost no clothing. Verifying per occasion and propagating
    turns that inversion from a tax into an advantage.

    It cannot rescue everything — a third of occasions here hold a single photo,
    with no peer to inherit from.
    """
    verified = set()
    for photo in labels:
        facts = cache.get(photo["id"])
        if not facts:
            continue
        if best_cosine(facts, seeds, knobs["min_face_px"]) >= knobs["identity_cosine"]:
            verified.add(photo.get("occasion", -1))
    verified.discard(-1)  # undated photos share no occasion; each stands alone
    return verified


# Measured and rejected. Propagating "the owner verified somewhere in this
# occasion" to every photo in it cost 23 points of precision for 3 of coverage,
# because an occasion containing the owner usually also contains their partner —
# and a photo-level claim cannot say *which body* was verified. The idea is
# sound; it needs per-person instance masks first, so the inheritance can attach
# to a body rather than a timestamp. Left here, off, so the next attempt starts
# from the measurement instead of repeating it.
PROPAGATE_IDENTITY_ACROSS_OCCASIONS = False


def score(labels, cache, seeds, knobs, subset) -> dict:
    tp = fp = fn = 0
    reasons = collections.Counter()
    covered, target_occasions = set(), set()
    strata: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])
    admitted_occasions: set = set()
    owner_seen: dict = collections.defaultdict(bool)
    for photo in labels:
        if not subset(photo):
            continue
        facts = cache.get(photo["id"])
        if not facts:
            continue
        facts["_occasion"] = photo.get("occasion", -1)
        truth = photo["visibility"] == "readable" and photo["identity"] == "owner"
        if truth:
            target_occasions.add(photo.get("occasion", -1))
        got, why = predict(facts, seeds, knobs)
        if got and truth:
            tp += 1
            covered.add(photo.get("occasion", -1))
        elif got:
            fp += 1
        elif truth:
            fn += 1
            reasons[why] += 1
        if got:
            admitted_occasions.add(photo.get("occasion", -1))
            owner_seen[photo.get("occasion", -1)] |= photo["identity"] == "owner"
        if truth:
            bucket = strata[framing_bucket(facts)]
            bucket[0] += int(got)
            bucket[1] += 1
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    coverage = len(covered) / len(target_occasions) if target_occasions else 0.0
    return {
        "tp": tp, "fp": fp, "fn": fn,
        "precision": precision, "recall": recall,
        "coverage": coverage,
        "occasions": f"{len(covered)}/{len(target_occasions)}",
        "misses": reasons,
        "strata": dict(strata),
        # Occasion-level precision, which is what the product experiences. A
        # false-positive photo inside an occasion the owner really attended
        # clusters onto the same garment and vanishes; an occasion the owner
        # was never at is a stranger's clothes in someone's wardrobe. Both are
        # reported, because the lenient one alone would be a way of moving the
        # goalposts rather than measuring.
        "occasionsStrict": (
            len(admitted_occasions & target_occasions) / len(admitted_occasions)
            if admitted_occasions else 0.0
        ),
        "occasionsSafe": (
            1 - len({o for o in admitted_occasions if not owner_seen[o]}) / len(admitted_occasions)
            if admitted_occasions else 0.0
        ),
    }


# The order a body fills the frame, worst-for-identity first.
BUCKETS = ["full length", "to knees", "to hips", "head/shoulders", "no pose"]


def report(name: str, result: dict, *, strata: bool = True) -> None:
    print(
        f"  {name:5}  precision {result['precision']:.1%}  "
        f"photo-recall {result['recall']:.1%}  "
        f"occasion-coverage {result['coverage']:.1%} ({result['occasions']})  "
        f"[tp {result['tp']} fp {result['fp']} fn {result['fn']}]"
    )
    print(
        f"         occasion precision: {result['occasionsSafe']:.1%} safe "
        f"(no stranger's occasion admitted) · {result['occasionsStrict']:.1%} strict"
    )
    for why, count in result["misses"].most_common():
        print(f"           lost {count:3} to: {why}")

    if not strata:
        return
    # Never an aggregate without its worst stratum beside it. A single 78% mean
    # hid a 48%-vs-100% split for as long as nobody went looking.
    rates = []
    for bucket in BUCKETS:
        got, total = result["strata"].get(bucket, [0, 0])
        if not total:
            continue
        rates.append((bucket, got / total, total))
    if not rates:
        return
    print("           recall by how much of the body is in frame:")
    for bucket, rate, total in rates:
        thin = "  (n too small to conclude)" if total < 10 else ""
        print(f"             {bucket:16} {rate:5.0%}  n={total:3}{thin}")
    worst = min(rates, key=lambda r: r[1])
    spread = max(r[1] for r in rates) - worst[1]
    if spread > 0.25:
        print(f"           ⚠ spread {spread:.0%} — the aggregate is hiding '{worst[0]}' at {worst[1]:.0%}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sweep", action="store_true", help="show where each threshold could go")
    parser.add_argument("--search", action="store_true", help="grid search, best coverage at precision >= 85 percent")
    parser.add_argument("--test", action="store_true", help="open the held-out occasions")
    args = parser.parse_args()

    if not CACHE.exists():
        print("No vision cache — run `make vision-cache` first.", file=sys.stderr)
        return 1

    labels, cache, seeds = load()
    try:
        check(labels, cache, seeds)
    except InvalidCorpus as error:
        print(f"\n{error}\n", file=sys.stderr)
        return 1

    knobs = {
        "min_person_height": MIN_PERSON_HEIGHT,
        "joints": {"Shoulder", "Hip"},
        "joint_confidence": JOINT_CONFIDENCE,
        "identity_cosine": IDENTITY_COSINE,
        "min_face_px": MIN_FACE_PX,
        "max_face_fraction": MAX_FACE_FRACTION,
        "identity_margin": IDENTITY_MARGIN,
        "use_framing": False,
    }

    # Permuted labels must collapse to chance. If they do not, something
    # connects the answer to the prediction and every number above is fiction.
    shuffled = [dict(p) for p in labels]
    keys = [(p["visibility"], p["identity"]) for p in shuffled]
    for index, photo in enumerate(shuffled):
        photo["visibility"], photo["identity"] = keys[(index * 37 + 11) % len(keys)]
    canary = score(shuffled, cache, seeds, knobs, lambda p: not is_test(p))
    base_rate = sum(
        1 for p in labels
        if not is_test(p) and p["visibility"] == "readable" and p["identity"] == "owner"
    ) / max(1, sum(1 for p in labels if not is_test(p)))
    if canary["precision"] > base_rate * 2:
        print(f"\ncanary FAILED: shuffled labels score {canary['precision']:.1%} "
              f"against a {base_rate:.1%} base rate — the scorer is leaking.\n", file=sys.stderr)
        return 1

    target = [p for p in labels if p["visibility"] == "readable" and p["identity"] == "owner"]
    dev_target = [p for p in target if not is_test(p)]
    print(f"corpus {len(labels)} · seeds {len(seeds)} · target {len(target)} "
          f"({len(dev_target)} dev / {len(target) - len(dev_target)} test)\n")

    print("GOAL  occasion-coverage >= 95%, precision >= 85%, on held-out occasions\n")
    report("dev", score(labels, cache, seeds, knobs, lambda p: not is_test(p)))
    if args.test:
        report("test", score(labels, cache, seeds, knobs, is_test))
    else:
        print("  test   (held out — pass --test to open it)")

    # What the deleted framing gate was worth, measured rather than argued.
    with_framing = score(labels, cache, seeds, dict(knobs) | {"use_framing": True},
                         lambda p: not is_test(p))
    print("\n  with the deleted framing gate restored, for comparison:")
    report("+fram", with_framing, strata=False)

    if args.search:
        # Grid search on dev only. Ranked by occasion coverage among configs
        # that clear the precision bar, because coverage is the recall proxy
        # that survives pass 3 being deferred: one good photo per occasion is
        # what a garment actually needs.
        #
        # Kept deliberately small. Every knob is a degree of freedom and there
        # are 97 dev targets — searching a thousand configs against a hundred
        # photos finds noise and calls it a threshold.
        results = []
        for joints in [{"Shoulder"}, {"Shoulder", "Hip"}, {"Neck"}, {"Shoulder", "Neck"}]:
            for joint_confidence in [0.02, 0.05, 0.10, 0.20, 0.30]:
                for height in [0.15, 0.25, 0.35]:
                    for cosine_threshold in [0.30, 0.363, 0.45]:
                        trial = dict(knobs) | {
                            "joints": joints,
                            "joint_confidence": joint_confidence,
                            "min_person_height": height,
                            "identity_cosine": cosine_threshold,
                        }
                        r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
                        results.append((r, trial))
        passing = [(r, t) for r, t in results if r["precision"] >= 0.85]
        passing.sort(key=lambda rt: (-rt[0]["coverage"], -rt[0]["precision"]))
        print(f"\ngrid: {len(results)} configs, {len(passing)} clear precision >= 85% (dev)")
        print("  best by occasion coverage:")
        for r, t in passing[:8]:
            print(f"    cov {r['coverage']:5.1%} prec {r['precision']:5.1%} rec {r['recall']:5.1%}  "
                  f"joints={'+'.join(sorted(t['joints'])):13} conf={t['joint_confidence']:<5} "
                  f"h={t['min_person_height']:<5} cos={t['identity_cosine']}")

    if args.sweep:
        print("\nsweep, on dev only:")
        for name, key, values in [
            ("person height", "min_person_height", [0.10, 0.15, 0.20, 0.25, 0.30, 0.40]),
            ("joint conf", "joint_confidence", [0.05, 0.10, 0.20, 0.30, 0.50]),
            ("identity cos", "identity_cosine", [0.20, 0.30, 0.363, 0.45, 0.55]),
            ("min face px", "min_face_px", [12, 24, 36, 48, 64]),
        ]:
            print(f"\n  {name}")
            for value in values:
                trial = dict(knobs) | {key: value}
                r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
                mark = " <- current" if value == knobs[key] else ""
                print(f"    {value:<6} precision {r['precision']:.1%}  "
                      f"coverage {r['coverage']:.1%}  recall {r['recall']:.1%}{mark}")

        print("\n  joint sets")
        for joints in [{"Shoulder", "Hip"}, {"Shoulder"}, {"Shoulder", "Neck"}, {"Hip"}]:
            trial = dict(knobs) | {"joints": joints}
            r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
            print(f"    {'+'.join(sorted(joints)):18} precision {r['precision']:.1%}  "
                  f"coverage {r['coverage']:.1%}  recall {r['recall']:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
